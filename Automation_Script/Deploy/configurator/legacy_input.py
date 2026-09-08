"""Translate the Bash wizard's in-memory values into configuration v1."""

from typing import Any, Dict, List


class LegacyInputError(ValueError):
    """Raised when the wizard input stream is incomplete or inconsistent."""


COMPONENT_ORDER = ("redis", "rabbitmq", "mongodb", "mysql")


def _take(values: List[str], label: str) -> str:
    if not values:
        raise LegacyInputError("missing wizard field: {0}".format(label))
    return values.pop(0)


def _integer(value: str, label: str) -> int:
    try:
        return int(value)
    except ValueError:
        raise LegacyInputError("wizard field must be an integer: {0}".format(label))


def _nodes(values: List[str], roles: List[str]) -> List[Dict[str, str]]:
    addresses = [_take(values, "node ip") for _ in range(3)]
    hostnames = [_take(values, "node hostname") for _ in range(3)]
    return [
        {"ip": addresses[index], "hostname": hostnames[index], "role": roles[index]}
        for index in range(3)
    ]


def config_from_nul_bytes(payload: bytes) -> Dict[str, Any]:
    try:
        values = payload.decode("utf-8").split("\0")
    except UnicodeDecodeError as error:
        raise LegacyInputError("wizard input must be UTF-8") from error
    if values and values[-1] == "":
        values.pop()
    selected = _take(values, "selected components").split(",")
    if not selected or any(name not in COMPONENT_ORDER for name in selected) or len(set(selected)) != len(selected):
        raise LegacyInputError("selected components are invalid")
    management_ip = _take(values, "management ip")
    management_hostname = _take(values, "management hostname")
    management_user = _take(values, "management user")
    management_password = _take(values, "management password")
    database_user = _take(values, "database user")
    database_password = _take(values, "database password")
    config = {
        "schema_version": 1,
        "deployment": {"components": selected},
        "management": {"ip": management_ip, "hostname": management_hostname},
        "ssh": {"management_user": management_user, "database_user": database_user},
        "components": {},
        "secrets": {
            "management_ssh_password": management_password,
            "database_ssh_password": database_password,
        },
    }
    for component in COMPONENT_ORDER:
        if component not in selected:
            continue
        if component == "redis":
            config["components"][component] = {
                "nodes": _nodes(values, ["master", "replica", "replica"]),
                "service": {"port": 6379, "sentinel_port": 26379, "sentinel_master_name": "mymaster"},
            }
            config["secrets"]["redis_password"] = _take(values, "redis password")
        elif component == "rabbitmq":
            config["components"][component] = {
                "nodes": _nodes(values, ["seed", "member", "member"]),
                "service": {"management_port": 15672, "admin_user": "admin"},
            }
            config["secrets"]["rabbitmq_cookie"] = _take(values, "rabbitmq cookie")
            config["secrets"]["rabbitmq_admin_password"] = _take(values, "rabbitmq admin password")
        elif component == "mongodb":
            config["components"][component] = {
                "nodes": _nodes(values, ["primary", "secondary", "secondary"]),
                "service": {"port": 27017, "replica_set": "rs0", "admin_user": "admin"},
            }
            config["secrets"]["mongodb_admin_password"] = _take(values, "mongodb admin password")
        else:
            config["components"][component] = {
                "nodes": _nodes(values, ["primary", "replica", "replica"]),
                "service": {
                    "port": 3306,
                    "replication_user": "repl",
                    "vip_verify_user": "ecopilot_vip_verify",
                    "vip": _take(values, "mysql vip"),
                    "vip_prefix": _integer(_take(values, "mysql vip prefix"), "mysql vip prefix"),
                    "keepalived_interface": "auto",
                    "keepalived_router_id": 61,
                },
            }
            config["secrets"]["mysql_root_password"] = _take(values, "mysql root password")
            config["secrets"]["mysql_replication_password"] = _take(values, "mysql replication password")
            config["secrets"]["mysql_vip_verify_password"] = _take(values, "mysql vip verify password")
            config["secrets"]["keepalived_auth_password"] = _take(values, "keepalived auth password")
    if values:
        raise LegacyInputError("unexpected trailing wizard fields")
    return config