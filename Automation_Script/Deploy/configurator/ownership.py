"""Pure reconciliation for declared deployment resources and non-sensitive remote facts."""

from typing import Any, Dict, Iterable, List, Mapping


def reconcile_resource(resource: Mapping[str, Any], fact: Mapping[str, Any]) -> Dict[str, Any]:
    """Classify a declared resource without making a lifecycle decision."""
    kind = resource["kind"]
    status = fact.get("status", "unknown")
    if status == "unknown":
        ownership = "unknown"
    elif kind == "package":
        ownership = "managed" if status == "installed" and fact.get("version") == resource.get("version") else "external_conflict"
    elif kind == "service":
        ownership = "managed" if status in ("enabled", "enabled_active", "active") else "external_conflict"
    elif kind == "file":
        ownership = "managed" if status == "file" else ("external_conflict" if status == "nonfile" else "unmanaged_or_absent")
    elif kind == "data_directory":
        ownership = "managed_missing" if status == "absent" else ("external_conflict" if status == "nonempty" else "unknown")
    else:
        ownership = "unknown"
    return {
        "id": resource["id"],
        "kind": kind,
        "node": resource["node"],
        "ownership": ownership,
        "fact_status": status,
    }


def reconcile_manifest(manifest: Mapping[str, Any], facts: Mapping[str, Iterable[Mapping[str, Any]]]) -> Dict[str, Any]:
    """Merge remote facts into a non-sensitive reconciliation report."""
    components = []
    blocked = False
    for component in manifest["components"]:
        resources = []
        component_blocked = False
        for resource in component["resources"]:
            node_facts = {fact["id"]: fact for fact in facts.get(resource["node"], ()) if "id" in fact}
            fact = node_facts.get(resource["id"], {"status": "unknown"})
            reconciled = reconcile_resource(resource, fact)
            resources.append(reconciled)
            if reconciled["ownership"] in ("unknown", "external_conflict"):
                blocked = True
                component_blocked = True
        components.append({"name": component["name"], "ownership": "mixed" if component_blocked else "planned_new", "resources": resources})
    conflicts = [
        item["id"]
        for component in components
        for item in component["resources"]
        if item["ownership"] in ("unknown", "external_conflict")
    ]
    return {
        "schema_version": 1,
        "configuration_sha256": manifest["configuration_sha256"],
        "blocked": blocked,
        "conflicts": sorted(conflicts),
        "components": components,
    }
