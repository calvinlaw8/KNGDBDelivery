"""Fail-closed recognition and migration of previous configuration formats."""

import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any, Callable, Dict, Mapping

try:
    from .schema import SCHEMA_VERSION, ConfigSchemaError, load_config
except ImportError:  # Support direct test execution from the configurator directory.
    from schema import SCHEMA_VERSION, ConfigSchemaError, load_config


class MigrationError(ValueError):
    """Raised when a configuration cannot be migrated without interpretation."""


SCALAR_NAMES = {
    "PROJECT_ROOT",
    "DEPLOY_COMPONENTS",
    "PKG_ROOT",
    "LOCAL_DB_PKG_DIR",
    "ANSIBLE_NODE_IP",
    "ANSIBLE_NODE_USER",
    "ANSIBLE_NODE_PASS",
    "ANSIBLE_NODE_HOSTNAME",
    "LOCAL_PLAYBOOK_DIR",
    "REMOTE_PLAYBOOK_DIR",
    "LOCAL_PAYLOAD_VALIDATOR",
    "REMOTE_PAYLOAD_VALIDATOR",
    "REMOTE_PKG_DIR",
    "DB_USER",
    "DB_PASS",
}
ARRAY_NAMES = {
    "REDIS_IPS",
    "REDIS_HOSTNAMES",
    "RABBITMQ_IPS",
    "RABBITMQ_HOSTNAMES",
    "MONGODB_IPS",
    "MONGODB_HOSTNAMES",
    "MYSQL_IPS",
    "MYSQL_HOSTNAMES",
}
AGGREGATE_LINES = {
    'DB_IPS=("${REDIS_IPS[@]}" "${RABBITMQ_IPS[@]}" "${MONGODB_IPS[@]}" "${MYSQL_IPS[@]}")',
    'DB_HOSTNAMES=("${REDIS_HOSTNAMES[@]}" "${RABBITMQ_HOSTNAMES[@]}" "${MONGODB_HOSTNAMES[@]}" "${MYSQL_HOSTNAMES[@]}")',
}
QUOTED_VALUE = r"'(?:[^']|'\"'\"')*'"
SCALAR_PATTERN = re.compile(r"^([A-Z][A-Z0-9_]*)=(" + QUOTED_VALUE + r")$")
EMPTY_ARRAY_PATTERN = re.compile(r"^([A-Z][A-Z0-9_]*)=\(\)$")
ARRAY_ITEM_PATTERN = re.compile(r"^([A-Z][A-Z0-9_]*)\[([0-9]+)\]=(" + QUOTED_VALUE + r")$")


def _decode_quoted(value: str) -> str:
    return value[1:-1].replace("'\"'\"'", "'")


def parse_legacy_env_bytes(source: bytes) -> Dict[str, Any]:
    try:
        text = source.decode("utf-8")
    except UnicodeDecodeError as error:
        raise MigrationError("legacy config is not valid UTF-8") from error
    scalars: Dict[str, str] = {}
    arrays: Dict[str, Dict[int, str]] = {}
    aggregates = set()
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        if line in AGGREGATE_LINES:
            if line in aggregates:
                raise MigrationError("duplicate aggregate assignment at line {0}".format(line_number))
            aggregates.add(line)
            continue
        scalar = SCALAR_PATTERN.fullmatch(line)
        if scalar:
            name, value = scalar.groups()
            if name not in SCALAR_NAMES:
                raise MigrationError("unknown scalar at line {0}".format(line_number))
            if name in scalars:
                raise MigrationError("duplicate scalar at line {0}".format(line_number))
            scalars[name] = _decode_quoted(value)
            continue
        empty_array = EMPTY_ARRAY_PATTERN.fullmatch(line)
        if empty_array:
            name = empty_array.group(1)
            if name not in ARRAY_NAMES or name in arrays:
                raise MigrationError("unknown or duplicate array at line {0}".format(line_number))
            arrays[name] = {}
            continue
        array_item = ARRAY_ITEM_PATTERN.fullmatch(line)
        if array_item:
            name, index_text, value = array_item.groups()
            index = int(index_text)
            if name not in ARRAY_NAMES or name not in arrays or index in arrays[name]:
                raise MigrationError("invalid array assignment at line {0}".format(line_number))
            arrays[name][index] = _decode_quoted(value)
            continue
        raise MigrationError("unsupported legacy syntax at line {0}".format(line_number))
    missing_scalars = sorted(SCALAR_NAMES - set(scalars))
    missing_arrays = sorted(ARRAY_NAMES - set(arrays))
    if missing_scalars or missing_arrays or aggregates != AGGREGATE_LINES:
        raise MigrationError("legacy config is incomplete")
    normalized_arrays = {}
    for name, values in arrays.items():
        if sorted(values) != list(range(len(values))):
            raise MigrationError("legacy array {0} has non-contiguous indexes".format(name))
        normalized_arrays[name] = [values[index] for index in range(len(values))]
    return {"scalars": scalars, "arrays": normalized_arrays}


def inspect_legacy_env(path: Path) -> Dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise MigrationError("legacy config must be a regular file")
    source = path.read_bytes()
    parsed = parse_legacy_env_bytes(source)
    scalars = parsed["scalars"]
    arrays = parsed["arrays"]
    components = [name for name in scalars["DEPLOY_COMPONENTS"].split(",") if name]
    return {
        "format": "legacy-env-v0",
        "source_sha256": hashlib.sha256(source).hexdigest(),
        "migration_status": "reentry_required",
        "reason": "legacy config does not contain the complete versioned data model",
        "preview": {
            "components": components,
            "management": {"ip": scalars["ANSIBLE_NODE_IP"], "hostname": scalars["ANSIBLE_NODE_HOSTNAME"]},
            "node_counts": {name.lower().replace("_ips", ""): len(values) for name, values in arrays.items() if name.endswith("_IPS")},
        },
    }


def archive_legacy_env(path: Path, runtime_dir: Path) -> Path:
    preview = inspect_legacy_env(path)
    source = path.read_bytes()
    if hashlib.sha256(source).hexdigest() != preview["source_sha256"]:
        raise MigrationError("legacy config changed during inspection")
    backup_dir = runtime_dir / "legacy-backups"
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(str(backup_dir), 0o700)
    destination = backup_dir / (preview["source_sha256"] + ".config.env")
    if destination.exists():
        if destination.read_bytes() != source:
            raise MigrationError("legacy backup digest collision")
        return destination
    temporary = backup_dir / ("." + preview["source_sha256"] + ".tmp")
    descriptor = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(source)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(str(temporary), 0o400)
        os.replace(str(temporary), str(destination))
        _fsync_directory(backup_dir)
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise
    return destination


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


Migration = Callable[[Mapping[str, Any]], Dict[str, Any]]
MIGRATIONS: Dict[int, Migration] = {}


def migrate_json_config(config: Mapping[str, Any]) -> Dict[str, Any]:
    if isinstance(config.get("schema_version"), bool) or not isinstance(config.get("schema_version"), int):
        raise MigrationError("schema_version must be an integer")
    version = config["schema_version"]
    migrated = dict(config)
    while version < SCHEMA_VERSION:
        migration = MIGRATIONS.get(version)
        if migration is None:
            raise MigrationError("no migration is registered from schema version {0}".format(version))
        migrated = migration(migrated)
        version = migrated.get("schema_version")
    if version != SCHEMA_VERSION:
        raise MigrationError("unsupported schema version {0}".format(version))
    try:
        return load_config(json.dumps(migrated, ensure_ascii=False))
    except ConfigSchemaError as error:
        raise MigrationError("migrated configuration is invalid: {0}".format(error.message)) from error