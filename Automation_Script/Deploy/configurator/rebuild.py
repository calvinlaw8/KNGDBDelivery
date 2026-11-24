"""Build an independent, non-executing rebuild plan for one component."""

from datetime import datetime
from typing import Any, Dict, Mapping


VALID_COMPONENTS = ("redis", "rabbitmq", "mongodb", "mysql")


def _valid_backup_declaration(declaration: Mapping[str, Any]) -> bool:
    if not isinstance(declaration, Mapping):
        return False
    required = ("change_id", "backup_time", "snapshot_id", "restoration_verified")
    if any(not declaration.get(name) for name in required[:3]):
        return False
    if declaration.get("restoration_verified") is not True:
        return False
    try:
        datetime.fromisoformat(str(declaration["backup_time"]).replace("Z", "+00:00"))
    except ValueError:
        return False
    return True


def build_rebuild_plan(
    manifest: Mapping[str, Any],
    reconciliation: Mapping[str, Any],
    component: str,
    backup_declaration: Mapping[str, Any],
) -> Dict[str, Any]:
    if component not in VALID_COMPONENTS:
        raise ValueError("rebuild blocked: unknown component")
    if reconciliation.get("blocked"):
        raise ValueError("rebuild blocked: reconciliation contains unknown or external-conflict resources")
    if not _valid_backup_declaration(backup_declaration):
        raise ValueError("rebuild blocked: backup/snapshot declaration is incomplete or unverified")

    declared = {item["name"]: item for item in manifest["components"]}
    reconciled = {item["name"]: item for item in reconciliation["components"]}
    declared_component = declared.get(component)
    reconciled_component = reconciled.get(component)
    if declared_component is None or reconciled_component is None:
        raise ValueError("rebuild blocked: component is missing from declaration or reconciliation")

    resources = reconciled_component["resources"]
    if any(resource["ownership"] not in ("managed", "managed_missing") for resource in resources):
        raise ValueError("rebuild blocked: component has unapproved resource ownership")

    data_directories = [
        {"id": resource["id"], "node": resource["node"], "path": resource["path"], "action": "quarantine_only"}
        for resource in declared_component["resources"]
        if resource["kind"] == "data_directory"
    ]
    if not data_directories:
        raise ValueError("rebuild blocked: component has no declared data directory")

    return {
        "schema_version": 1,
        "configuration_sha256": manifest["configuration_sha256"],
        "mode": "dry_run_only",
        "execute": False,
        "component": component,
        "confirmation_phrase": "REBUILD-{0}-DATA".format(component.upper()),
        "backup": {
            "change_id": backup_declaration["change_id"],
            "backup_time": backup_declaration["backup_time"],
            "snapshot_id": backup_declaration["snapshot_id"],
            "restoration_verified": True,
        },
        "data_directories": data_directories,
        "steps": ["stop_and_disable_managed_services", "quarantine_declared_data_directories", "redeploy_single_component", "verify", "purge_quarantine_requires_separate_confirmation"],
    }
