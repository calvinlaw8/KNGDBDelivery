"""Authoritative v1 configuration schema and strict JSON parser."""

import json
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple


SCHEMA_VERSION = 1
COMPONENT_NAMES = ("redis", "rabbitmq", "mongodb", "mysql")
MAX_JSON_DEPTH = 32
MAX_JSON_ITEMS = 1000

NODE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["ip", "hostname", "role"],
    "properties": {
        "ip": {"type": "string"},
        "hostname": {"type": "string"},
        "role": {"type": "string"},
    },
}


def _component_schema(roles: Sequence[str], service_properties: Mapping[str, Any]) -> Dict[str, Any]:
    node_schema = dict(NODE_SCHEMA)
    node_schema["properties"] = dict(NODE_SCHEMA["properties"])
    node_schema["properties"]["role"] = {"type": "string", "enum": list(roles)}
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["nodes", "service"],
        "properties": {
            "nodes": {
                "type": "array",
                "minItems": 3,
                "maxItems": 3,
                "items": node_schema,
            },
            "service": {
                "type": "object",
                "additionalProperties": False,
                "required": list(service_properties),
                "properties": dict(service_properties),
            },
        },
    }


CONFIG_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "urn:ecopilot:database-ha:config:v1",
    "title": "eCopilot database HA deployment configuration v1",
    "type": "object",
    "additionalProperties": False,
    "required": ["schema_version", "deployment", "management", "ssh", "components", "secrets"],
    "properties": {
        "schema_version": {"type": "integer", "const": SCHEMA_VERSION},
        "deployment": {
            "type": "object",
            "additionalProperties": False,
            "required": ["components"],
            "properties": {
                "components": {
                    "type": "array",
                    "minItems": 1,
                    "uniqueItems": True,
                    "items": {"type": "string", "enum": list(COMPONENT_NAMES)},
                },
                "rabbitmq_rebuild_cluster": {"type": "boolean"},
            },
        },
        "management": {
            "type": "object",
            "additionalProperties": False,
            "required": ["ip", "hostname"],
            "properties": {
                "ip": {"type": "string"},
                "hostname": {"type": "string"},
            },
        },
        "ssh": {
            "type": "object",
            "additionalProperties": False,
            "required": ["management_user", "database_user"],
            "properties": {
                "management_user": {"type": "string"},
                "database_user": {"type": "string"},
            },
        },
        "components": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "redis": _component_schema(
                    ("master", "replica"),
                    {
                        "port": {"type": "integer"},
                        "sentinel_port": {"type": "integer"},
                        "sentinel_master_name": {"type": "string"},
                    },
                ),
                "rabbitmq": _component_schema(
                    ("seed", "member"),
                    {"management_port": {"type": "integer"}, "admin_user": {"type": "string"}},
                ),
                "mongodb": _component_schema(
                    ("primary", "secondary"),
                    {"port": {"type": "integer"}, "replica_set": {"type": "string"}, "admin_user": {"type": "string"}},
                ),
                "mysql": _component_schema(
                    ("primary", "replica"),
                    {
                        "port": {"type": "integer"},
                        "replication_user": {"type": "string"},
                        "vip_verify_user": {"type": "string"},
                        "vip": {"type": "string"},
                        "vip_prefix": {"type": "integer"},
                        "keepalived_interface": {"type": "string"},
                        "keepalived_router_id": {"type": "integer"},
                    },
                ),
            },
        },
        "secrets": {
            "type": "object",
            "x-sensitive": True,
            "additionalProperties": False,
            "required": ["management_ssh_password", "database_ssh_password"],
            "properties": {
                "management_ssh_password": {"type": "string", "x-sensitive": True},
                "database_ssh_password": {"type": "string", "x-sensitive": True},
                "redis_password": {"type": "string", "x-sensitive": True},
                "rabbitmq_cookie": {"type": "string", "x-sensitive": True},
                "rabbitmq_admin_password": {"type": "string", "x-sensitive": True},
                "mongodb_admin_password": {"type": "string", "x-sensitive": True},
                "mysql_root_password": {"type": "string", "x-sensitive": True},
                "mysql_replication_password": {"type": "string", "x-sensitive": True},
                "mysql_vip_verify_password": {"type": "string", "x-sensitive": True},
                "keepalived_auth_password": {"type": "string", "x-sensitive": True},
            },
        },
    },
}


class ConfigSchemaError(ValueError):
    """A stable structural configuration error."""

    def __init__(self, code: str, path: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.path = path
        self.message = message

    def as_dict(self) -> Dict[str, str]:
        return {"code": self.code, "path": self.path, "message": self.message}


def _reject_duplicate_keys(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ConfigSchemaError("duplicate_key", "/", "duplicate JSON key: {0}".format(key))
        result[key] = value
    return result


def _join_path(path: str, part: Any) -> str:
    escaped = str(part).replace("~", "~0").replace("/", "~1")
    return "/{0}".format(escaped) if path == "/" else "{0}/{1}".format(path, escaped)


def _type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    return False


def _validate(value: Any, rule: Mapping[str, Any], path: str) -> None:
    expected = rule.get("type")
    if expected and not _type_matches(value, expected):
        raise ConfigSchemaError("wrong_type", path, "expected {0}".format(expected))
    if "const" in rule and value != rule["const"]:
        raise ConfigSchemaError("unsupported_version", path, "expected {0}".format(rule["const"]))
    if "enum" in rule and value not in rule["enum"]:
        raise ConfigSchemaError("invalid_enum", path, "value is not allowed")

    if expected == "object":
        properties = rule.get("properties", {})
        for required_name in rule.get("required", []):
            if required_name not in value:
                raise ConfigSchemaError("missing_required", _join_path(path, required_name), "required field is missing")
        if rule.get("additionalProperties") is False:
            for name in value:
                if name not in properties:
                    raise ConfigSchemaError("unknown_field", _join_path(path, name), "unknown field")
        for name, child in value.items():
            if name in properties:
                _validate(child, properties[name], _join_path(path, name))

    if expected == "array":
        if len(value) < rule.get("minItems", 0):
            raise ConfigSchemaError("too_few_items", path, "array has too few items")
        if "maxItems" in rule and len(value) > rule["maxItems"]:
            raise ConfigSchemaError("too_many_items", path, "array has too many items")
        if rule.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
            raise ConfigSchemaError("duplicate_item", path, "array items must be unique")
        for index, item in enumerate(value):
            _validate(item, rule["items"], _join_path(path, index))


def _check_complexity(value: Any, depth: int = 0, count: int = 0) -> int:
    if depth > MAX_JSON_DEPTH:
        raise ConfigSchemaError("nesting_limit", "/", "JSON nesting depth exceeds limit")
    if isinstance(value, dict):
        count += len(value)
        for item in value.values():
            count = _check_complexity(item, depth + 1, count)
    elif isinstance(value, list):
        count += len(value)
        for item in value:
            count = _check_complexity(item, depth + 1, count)
    if count > MAX_JSON_ITEMS:
        raise ConfigSchemaError("item_limit", "/", "JSON item count exceeds limit")
    return count


def validate_config(config: Any) -> None:
    """Validate v1 structure without performing network or cross-field checks."""
    _validate(config, CONFIG_SCHEMA, "/")


def load_config(source: Any) -> Dict[str, Any]:
    """Load strict JSON from text, bytes, or a path and validate its structure."""
    if isinstance(source, Path):
        text = source.read_text(encoding="utf-8")
    elif isinstance(source, bytes):
        text = source.decode("utf-8")
    elif isinstance(source, str):
        text = source
    else:
        raise TypeError("source must be JSON text, bytes, or pathlib.Path")
    try:
        config = json.loads(text, object_pairs_hook=_reject_duplicate_keys)
    except ConfigSchemaError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise ConfigSchemaError("invalid_json", "/", str(error)) from error
    _check_complexity(config)
    validate_config(config)
    return config


def write_json_schema(destination: Path) -> None:
    """Write the generated, read-only documentation schema."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(CONFIG_SCHEMA, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")