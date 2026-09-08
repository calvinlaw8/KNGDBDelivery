"""Atomic runtime generation publishing and fixed-path resolution."""

import os
from pathlib import Path
import re
import secrets
import shutil
from datetime import datetime, timezone
from typing import Optional


GENERATION_PATTERN = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$")


class GenerationError(ValueError):
    """Raised when a runtime generation cannot be safely resolved or published."""


def new_generation_id(timestamp: str) -> str:
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", timestamp):
        raise GenerationError("invalid generation timestamp")
    return "{0}-{1}".format(timestamp, secrets.token_hex(8))


def new_utc_generation_id() -> str:
    return new_generation_id(datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def prepare_staging_layout(staging: Path) -> None:
    config_dir = staging / "config"
    secrets_dir = staging / "secrets"
    config_dir.mkdir(mode=0o700)
    secrets_dir.mkdir(mode=0o700)
    for name in (
        "configuration.sha256",
        "deployment-plan.json",
        "deployment-summary.txt",
        "managed-resources.json",
    ):
        os.replace(str(staging / name), str(config_dir / name))
    if (staging / "install-summary.txt").is_file():
        os.replace(str(staging / "install-summary.txt"), str(config_dir / "install-summary.txt"))
    os.replace(str(staging / "config.env"), str(secrets_dir / "config.env"))
    os.replace(str(staging / "playbooks"), str(secrets_dir / "playbooks"))
    if (staging / "credentials.txt").is_file():
        os.replace(str(staging / "credentials.txt"), str(secrets_dir / "credentials.txt"))
    for root, directories, files in os.walk(str(staging)):
        root_path = Path(root)
        os.chmod(str(root_path), 0o700)
        for name in directories:
            os.chmod(str(root_path / name), 0o700)
        for name in files:
            path = root_path / name
            os.chmod(str(path), 0o600)
            descriptor = os.open(str(path), os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        _fsync_directory(root_path)


def read_current(runtime_dir: Path) -> Optional[str]:
    current = runtime_dir / "current"
    if not current.exists():
        return None
    generation_id = current.read_text(encoding="ascii").strip()
    if not GENERATION_PATTERN.fullmatch(generation_id):
        raise GenerationError("current contains an invalid generation id")
    generation = runtime_dir / "generations" / generation_id
    if not generation.is_dir():
        raise GenerationError("current references a missing generation")
    return generation_id


def resolve_current(runtime_dir: Path) -> Optional[Path]:
    generation_id = read_current(runtime_dir)
    return runtime_dir / "generations" / generation_id if generation_id else None


def publish_staging(runtime_dir: Path, staging: Path, generation_id: str) -> Path:
    if not GENERATION_PATTERN.fullmatch(generation_id):
        raise GenerationError("invalid generation id")
    if not staging.is_dir():
        raise GenerationError("staging directory does not exist")
    destination = runtime_dir / "generations" / generation_id
    if destination.exists():
        raise GenerationError("generation already exists")
    prepare_staging_layout(staging)
    runtime_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(str(runtime_dir), 0o700)
    generations = runtime_dir / "generations"
    generations.mkdir(mode=0o700, exist_ok=True)
    os.chmod(str(generations), 0o700)
    for shared_name in ("logs", "state"):
        shared = runtime_dir / shared_name
        shared.mkdir(mode=0o700, exist_ok=True)
        os.chmod(str(shared), 0o700)
    os.replace(str(staging), str(destination))
    _fsync_directory(generations)
    pointer_tmp = runtime_dir / ".current.{0}.tmp".format(generation_id)
    descriptor = os.open(str(pointer_tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as stream:
        stream.write(generation_id + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(str(pointer_tmp), str(runtime_dir / "current"))
    os.chmod(str(runtime_dir / "current"), 0o600)
    _fsync_directory(runtime_dir)
    return destination


def remove_unreferenced_generation(runtime_dir: Path, generation_id: str) -> None:
    if not GENERATION_PATTERN.fullmatch(generation_id):
        raise GenerationError("invalid generation id")
    if read_current(runtime_dir) == generation_id:
        raise GenerationError("refusing to remove the current generation")
    for reference_root in (runtime_dir / "locks", runtime_dir / "state"):
        if reference_root.is_dir():
            for path in reference_root.iterdir():
                if path.is_file() and generation_id in path.read_text(encoding="utf-8", errors="replace"):
                    raise GenerationError("generation is referenced by {0}".format(path.name))
    destination = runtime_dir / "generations" / generation_id
    if destination.exists():
        shutil.rmtree(str(destination))