"""Deterministic renderers for deployment runtime files."""

import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any, Dict, Mapping

try:
    from .validate import validation_result
except ImportError:  # Support direct test execution from the configurator directory.
    from validate import validation_result


GROUP_VAR_FILES = ("all.yml", "redis.yml", "rabbitmq.yml", "mongodb.yml", "mysql.yml")

MANAGED_RESOURCE_SPECS = {
    "redis": {
        "version": "8.2.8",
        "package": "redis-server",
        "services": ("redis-server", "redis-sentinel"),
        "files": ("/etc/redis/redis.conf", "/etc/redis/sentinel.conf", "/etc/systemd/system/redis-sentinel.service"),
        "data_path": "/var/lib/redis",
    },
    "rabbitmq": {
        "version": "4.2.9",
        "package": "rabbitmq-server",
        "services": ("rabbitmq-server",),
        "files": ("/etc/rabbitmq/rabbitmq.conf",),
        "data_path": "/var/lib/rabbitmq",
    },
    "mongodb": {
        "version": "8.2.12",
        "package": "mongodb-org-server",
        "services": ("mongod",),
        "files": ("/etc/mongod.conf", "/etc/mongodb-keyfile"),
        "data_path": "/data/mongodb",
    },
    "mysql": {
        "version": "8.4.11",
        "package": "mysql-community-server",
        "services": ("mysql", "keepalived"),
        "files": ("/etc/mysql/my.cnf", "/etc/keepalived/keepalived.conf", "/etc/keepalived/mysql-health.cnf"),
        "data_path": "/data/mysql",
    },
}


class RenderError(ValueError):
    """Raised when validated configuration cannot be rendered safely."""


def bash_quote(value: str) -> str:
    """Quote one value for Bash 3.2 without relying on Bash printf %q."""
    if not value:
        return "''"
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _replace_top_level(text: str, key: str, value: Any) -> str:
    lines = text.splitlines()
    start = next((index for index, line in enumerate(lines) if re.match(r"^{0}:".format(re.escape(key)), line)), None)
    if start is None:
        raise RenderError("group_vars template is missing key: {0}".format(key))
    end = start + 1
    while end < len(lines) and (not lines[end] or lines[end][0].isspace()):
        end += 1
    encoded = json.dumps(value, ensure_ascii=False, indent=2)
    replacement = ["{0}: {1}".format(key, encoded)]
    return "\n".join(lines[:start] + replacement + lines[end:]) + "\n"


def _node_by_role(component: Mapping[str, Any], role: str):
    return [node for node in component["nodes"] if node["role"] == role]


def _rabbitmq_prefix(hostname: str) -> str:
    return re.sub(r"[-_]\d+$", "", hostname)


def render_group_vars(config: Mapping[str, Any], template_dir: Path) -> Dict[str, str]:
    """Render all group_vars files from immutable templates and validated config."""
    result = {name: (template_dir / name).read_text(encoding="utf-8") for name in GROUP_VAR_FILES}
    selected = config["deployment"]["components"]
    components = config["components"]
    secrets = config["secrets"]

    if "redis" in selected:
        redis = components["redis"]
        master = _node_by_role(redis, "master")[0]
        replicas = _node_by_role(redis, "replica")
        values = {
            "redis_password": secrets["redis_password"],
            "redis_master_ip": master["ip"],
            "redis_replicas": [node["ip"] for node in replicas],
            "redis_port": redis["service"]["port"],
            "sentinel_port": redis["service"]["sentinel_port"],
            "sentinel_master_name": redis["service"]["sentinel_master_name"],
        }
        for key, value in values.items():
            result["redis.yml"] = _replace_top_level(result["redis.yml"], key, value)

    if "rabbitmq" in selected:
        rabbitmq = components["rabbitmq"]
        seed = _node_by_role(rabbitmq, "seed")[0]
        values = {
            "rabbitmq_seed_node_ip": seed["ip"],
            "rabbitmq_seed_hostname": seed["hostname"],
            "rabbitmq_node_prefix": _rabbitmq_prefix(seed["hostname"]),
            "rabbitmq_cluster_hostnames": [node["hostname"] for node in rabbitmq["nodes"]],
            "rabbitmq_rebuild_cluster": config["deployment"].get("rabbitmq_rebuild_cluster", False),
            "erlang_cookie": secrets["rabbitmq_cookie"],
            "rabbitmq_admin_user": rabbitmq["service"]["admin_user"],
            "rabbitmq_admin_password": secrets["rabbitmq_admin_password"],
            "rabbitmq_management_port": rabbitmq["service"]["management_port"],
        }
        for key, value in values.items():
            result["rabbitmq.yml"] = _replace_top_level(result["rabbitmq.yml"], key, value)

    if "mongodb" in selected:
        mongodb = components["mongodb"]
        primary = _node_by_role(mongodb, "primary")[0]
        replicas = _node_by_role(mongodb, "secondary")
        all_values = {
            "mongodb_primary_ip": primary["ip"],
            "mongodb_replica_ips": [node["ip"] for node in replicas],
        }
        component_values = {
            "mongodb_port": mongodb["service"]["port"],
            "mongodb_replicaset": mongodb["service"]["replica_set"],
            "mongodb_admin_user": mongodb["service"]["admin_user"],
            "mongodb_admin_password": secrets["mongodb_admin_password"],
        }
        for key, value in all_values.items():
            result["all.yml"] = _replace_top_level(result["all.yml"], key, value)
        for key, value in component_values.items():
            result["mongodb.yml"] = _replace_top_level(result["mongodb.yml"], key, value)

    if "mysql" in selected:
        mysql = components["mysql"]
        primary = _node_by_role(mysql, "primary")[0]
        ordered_nodes = _node_by_role(mysql, "primary") + _node_by_role(mysql, "replica")
        rendered_nodes = []
        for index, node in enumerate(ordered_nodes):
            rendered_nodes.append(
                {
                    "ip": node["ip"],
                    "hostname": node["hostname"],
                    "server_id": index + 1,
                    "role": node["role"],
                    "keepalived_priority": 100 - index * 10,
                }
            )
        service = mysql["service"]
        result["all.yml"] = _replace_top_level(result["all.yml"], "mysql_primary_ip", primary["ip"])
        values = {
            "mysql_port": service["port"],
            "mysql_nodes": rendered_nodes,
            "mysql_root_password": secrets["mysql_root_password"],
            "mysql_repl_user": service["replication_user"],
            "mysql_repl_password": secrets["mysql_replication_password"],
            "mysql_vip_verify_user": service["vip_verify_user"],
            "mysql_vip_verify_host": primary["ip"],
            "mysql_vip_verify_password": secrets["mysql_vip_verify_password"],
            "mysql_vip": service["vip"],
            "mysql_vip_prefix": service["vip_prefix"],
            "keepalived_interface": service["keepalived_interface"],
            "keepalived_router_id": service["keepalived_router_id"],
            "keepalived_auth_pass": secrets["keepalived_auth_password"],
        }
        for key, value in values.items():
            result["mysql.yml"] = _replace_top_level(result["mysql.yml"], key, value)

    return result


def render_runtime_config(config: Mapping[str, Any], project_root: Path, runtime_playbook_dir: Path) -> str:
    selected = config["deployment"]["components"]
    components = config["components"]
    values = {
        "PROJECT_ROOT": str(project_root),
        "DEPLOY_COMPONENTS": ",".join(selected),
        "PKG_ROOT": str(project_root / "Automation_Script/Deploy/pkg"),
        "LOCAL_DB_PKG_DIR": str(project_root / "离线安装包"),
        "ANSIBLE_NODE_IP": config["management"]["ip"],
        "ANSIBLE_NODE_USER": config["ssh"]["management_user"],
        "ANSIBLE_NODE_PASS": config["secrets"]["management_ssh_password"],
        "ANSIBLE_NODE_HOSTNAME": config["management"]["hostname"],
        "LOCAL_PLAYBOOK_DIR": str(runtime_playbook_dir),
        "REMOTE_PLAYBOOK_DIR": "/home/{0}/playbooks".format(config["ssh"]["management_user"]),
        "LOCAL_PAYLOAD_VALIDATOR": str(project_root / "Automation_Script/Deploy/validate_deb_payloads.sh"),
        "REMOTE_PAYLOAD_VALIDATOR": "/home/{0}/validate_deb_payloads.sh".format(config["ssh"]["management_user"]),
        "REMOTE_PKG_DIR": "/home/{0}/pkg".format(config["ssh"]["management_user"]),
        "DB_USER": config["ssh"]["database_user"],
        "DB_PASS": config["secrets"]["database_ssh_password"],
    }
    lines = ["# 本机生成的运行时配置，禁止提交 Git。"]
    lines.extend("{0}={1}".format(key, bash_quote(value)) for key, value in values.items())
    for component in ("redis", "rabbitmq", "mongodb", "mysql"):
        prefix = component.upper()
        lines.extend(("{0}_IPS=()".format(prefix), "{0}_HOSTNAMES=()".format(prefix)))
        if component in selected:
            for index, node in enumerate(components[component]["nodes"]):
                lines.append("{0}_IPS[{1}]={2}".format(prefix, index, bash_quote(node["ip"])))
                lines.append("{0}_HOSTNAMES[{1}]={2}".format(prefix, index, bash_quote(node["hostname"])))
    selected_prefixes = [component.upper() for component in selected]
    db_ips = " ".join('"${' + prefix + '_IPS[@]}"' for prefix in selected_prefixes)
    db_hostnames = " ".join('"${' + prefix + '_HOSTNAMES[@]}"' for prefix in selected_prefixes)
    lines.extend(("DB_IPS=({0})".format(db_ips), "DB_HOSTNAMES=({0})".format(db_hostnames)))
    return "\n".join(lines) + "\n"


def render_summary(config: Mapping[str, Any]) -> str:
    lines = [
        "eCopilot 数据库高可用部署摘要",
        "Ansible 管理节点：{0} ({1})".format(config["management"]["ip"], config["management"]["hostname"]),
        "选中组件：{0}".format(" ".join(config["deployment"]["components"])),
    ]
    for component in config["deployment"]["components"]:
        addresses = " ".join(node["ip"] for node in config["components"][component]["nodes"])
        lines.append("{0}：{1}".format(component, addresses))
    lines.append("凭据：已配置（值不显示）")
    return "\n".join(lines) + "\n"


def configuration_digest(config: Mapping[str, Any]) -> str:
    canonical = json.dumps(config, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def render_deployment_plan(config: Mapping[str, Any]) -> str:
    plan = {
        "schema_version": 1,
        "configuration_sha256": configuration_digest(config),
        "management": {"ip": config["management"]["ip"], "hostname": config["management"]["hostname"]},
        "components": [
            {
                "name": name,
                "nodes": [
                    {"ip": node["ip"], "hostname": node["hostname"], "role": node["role"]}
                    for node in config["components"][name]["nodes"]
                ],
            }
            for name in config["deployment"]["components"]
        ],
    }
    return json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def render_managed_resources(config: Mapping[str, Any]) -> str:
    """Render a declaration of planned ownership; live ownership requires remote facts."""
    components = []
    for name in config["deployment"]["components"]:
        spec = MANAGED_RESOURCE_SPECS[name]
        resources = []
        for node in config["components"][name]["nodes"]:
            node_id = "{0}:{1}".format(name, node["hostname"])
            resources.append(
                {
                    "id": "{0}:package:{1}".format(node_id, spec["package"]),
                    "kind": "package",
                    "name": spec["package"],
                    "version": spec["version"],
                    "node": node["hostname"],
                    "recovery_prerequisite": "Verify installed package ownership from remote facts before changing it.",
                }
            )
            for service in spec["services"]:
                resources.append(
                    {
                        "id": "{0}:service:{1}".format(node_id, service),
                        "kind": "service",
                        "name": service,
                        "node": node["hostname"],
                        "desired_state": "enabled_active",
                        "recovery_prerequisite": "Verify service ownership and dependent workload state before stopping it.",
                    }
                )
            for path in spec["files"]:
                resources.append(
                    {
                        "id": "{0}:file:{1}".format(node_id, path),
                        "kind": "file",
                        "path": path,
                        "node": node["hostname"],
                        "recovery_prerequisite": "Compare the deployed file digest with remote facts before replacement or removal.",
                    }
                )
            resources.append(
                {
                    "id": "{0}:data_directory:{1}".format(node_id, spec["data_path"]),
                    "kind": "data_directory",
                    "path": spec["data_path"],
                    "node": node["hostname"],
                    "recovery_prerequisite": "Confirm backup or snapshot availability and directory ownership before data changes.",
                }
            )
        components.append(
            {
                "name": name,
                "ownership": "planned_new",
                "nodes": [{"ip": node["ip"], "hostname": node["hostname"], "role": node["role"]} for node in config["components"][name]["nodes"]],
                "resources": resources,
            }
        )
    manifest = {
        "schema_version": 1,
        "configuration_sha256": configuration_digest(config),
        "ownership_note": "This is a planned declaration. Remote facts are required before any lifecycle action.",
        "components": components,
    }
    return json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def render_files(config: Mapping[str, Any], project_root: Path, runtime_playbook_dir: Path, template_dir: Path) -> Dict[str, str]:
    result = validation_result(config)
    errors = [issue for issue in result["issues"] if issue["severity"] == "error"]
    if errors:
        raise RenderError("configuration contains {0} validation error(s)".format(len(errors)))
    files = {
        "config.env": render_runtime_config(config, project_root, runtime_playbook_dir),
        "configuration.sha256": configuration_digest(config) + "\n",
        "deployment-plan.json": render_deployment_plan(config),
        "deployment-summary.txt": render_summary(config),
        "managed-resources.json": render_managed_resources(config),
    }
    files.update({"playbooks/group_vars/{0}".format(name): text for name, text in render_group_vars(config, template_dir).items()})
    return files


def write_staging_directory(destination: Path, files: Mapping[str, str]) -> None:
    """Write a complete render to a new directory; publishing is handled by F-005."""
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(str(destination), 0o700)
    for relative_name in sorted(files):
        path = destination / relative_name
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(str(path.parent), 0o700)
        descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(files[relative_name])