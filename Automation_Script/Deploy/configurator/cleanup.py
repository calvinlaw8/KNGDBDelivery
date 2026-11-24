"""Build an independent, non-executing cleanup plan for managed resources."""

from typing import Any, Dict, Iterable, Mapping


def build_cleanup_plan(
    manifest: Mapping[str, Any],
    reconciliation: Mapping[str, Any],
    components: Iterable[str],
) -> Dict[str, Any]:
    selected = set(components)
    if reconciliation.get("blocked"):
        raise ValueError("cleanup blocked: reconciliation contains unknown or external-conflict resources")

    declared = {item["name"]: item for item in manifest["components"]}
    reconciled = {item["name"]: item for item in reconciliation["components"]}
    unknown = sorted(selected - set(declared))
    if unknown:
        raise ValueError("unknown cleanup component(s): {0}".format(",".join(unknown)))

    component_plans = []
    for name in sorted(selected):
        declared_component = declared[name]
        reconciled_component = reconciled.get(name)
        if reconciled_component is None:
            raise ValueError("cleanup blocked: reconciliation missing component {0}".format(name))

        resources = reconciled_component["resources"]
        if any(resource["ownership"] not in ("managed", "planned_new", "managed_missing") for resource in resources):
            raise ValueError("cleanup blocked: component {0} has unapproved resource ownership".format(name))

        services = []
        files = []
        data = []
        packages = []
        for resource in declared_component["resources"]:
            action = "preserve"
            if resource["kind"] == "service":
                action = "stop_disable"
                services.append({"id": resource["id"], "node": resource["node"], "name": resource["name"], "action": action})
            elif resource["kind"] == "file":
                files.append({"id": resource["id"], "node": resource["node"], "path": resource["path"], "action": action})
            elif resource["kind"] == "data_directory":
                data.append({"id": resource["id"], "node": resource["node"], "path": resource["path"], "action": action})
            elif resource["kind"] == "package":
                packages.append({"id": resource["id"], "node": resource["node"], "name": resource["name"], "action": action})

        component_plans.append({
            "name": name,
            "services": services,
            "preserved": {"files": files, "data_directories": data, "packages": packages},
        })

    return {
        "schema_version": 1,
        "configuration_sha256": manifest["configuration_sha256"],
        "mode": "dry_run_only",
        "execute": False,
        "components": component_plans,
    }
