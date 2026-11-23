"""Shared semantic validation for deployment configuration."""

import ipaddress
import json
import re
from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Mapping, Sequence, Tuple

try:
    from .schema import COMPONENT_NAMES, ConfigSchemaError, validate_config
except ImportError:
        from schema import COMPONENT_NAMES, ConfigSchemaError, validate_config


HOSTNAME_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,251}[A-Za-z0-9])?$")
LINUX_USERNAME_PATTERN = re.compile(r"^[a-z_][a-z0-9_-]*\$?$")
COMPONENT_SECRET_PATTERN = re.compile(r"^[A-Za-z0-9._:@+=,-]+$")
KEEPALIVED_AUTH_PATTERN = re.compile(r"^[A-Za-z0-9._:@+=,-]{1,8}$")
ROLE_COUNTS = {
    "redis": {"master": 1, "replica": 2},
    "rabbitmq": {"seed": 1, "member": 2},
    "mongodb": {"primary": 1, "secondary": 2},
    "mysql": {"primary": 1, "replica": 2},
}
COMPONENT_SECRETS = {
    "redis": ("redis_password",),
    "rabbitmq": ("rabbitmq_cookie", "rabbitmq_admin_password"),
    "mongodb": ("mongodb_admin_password",),
    "mysql": (
        "mysql_root_password",
        "mysql_replication_password",
        "mysql_vip_verify_password",
        "keepalived_auth_password",
    ),
}


@dataclass(frozen=True)
class ValidationIssue:
    code: str
    path: str
    message: str
    severity: str = "error"

    def as_dict(self) -> Dict[str, str]:
        return asdict(self)


def _issue(code: str, path: str, message: str, severity: str = "error") -> ValidationIssue:
    return ValidationIssue(code=code, path=path, message=message, severity=severity)


def _valid_ipv4(value: str) -> bool:
    try:
        return isinstance(ipaddress.ip_address(value), ipaddress.IPv4Address)
    except ValueError:
        return False


def _valid_hostname(value: str) -> bool:
    if len(value) > 253 or not HOSTNAME_PATTERN.fullmatch(value):
        return False
    return all(label and len(label) <= 63 and not label.startswith("-") and not label.endswith("-") for label in value.split("."))


def _record_unique(index: Dict[str, str], value: str, path: str, code: str, label: str) -> List[ValidationIssue]:
    normalized = value.lower() if code == "duplicate_hostname" else value
    if normalized not in index:
        index[normalized] = path
        return []
    return [_issue(code, path, "{0} duplicates {1}".format(label, index[normalized]))]


def _validate_port(value: int, path: str) -> List[ValidationIssue]:
    if value < 1 or value > 65535:
        return [_issue("invalid_port", path, "port must be between 1 and 65535")]
    return []


def _validate_nonempty(value: str, path: str) -> List[ValidationIssue]:
    if not value:
        return [_issue("empty_required", path, "value must not be empty")]
    return []


def validate_semantics(config: Mapping[str, Any]) -> List[ValidationIssue]:
    """Return all deterministic field and cross-field issues without network access."""
    validate_config(config)
    issues = []
    selected = config["deployment"]["components"]
    components = config["components"]
    secrets = config["secrets"]

    ip_index = {}
    hostname_index = {}
    management_ip = config["management"]["ip"]
    management_hostname = config["management"]["hostname"]
    if not _valid_ipv4(management_ip):
        issues.append(_issue("invalid_ipv4", "/management/ip", "invalid IPv4 address"))
    else:
        issues.extend(_record_unique(ip_index, management_ip, "/management/ip", "duplicate_ip", "IP address"))
    if not _valid_hostname(management_hostname):
        issues.append(_issue("invalid_hostname", "/management/hostname", "invalid hostname"))
    else:
        issues.extend(_record_unique(hostname_index, management_hostname, "/management/hostname", "duplicate_hostname", "hostname"))

    for field in ("management_user", "database_user"):
        path = "/ssh/{0}".format(field)
        if not LINUX_USERNAME_PATTERN.fullmatch(config["ssh"][field]):
            issues.append(_issue("invalid_linux_username", path, "invalid Linux username"))
    for field in ("management_ssh_password", "database_ssh_password"):
        issues.extend(_validate_nonempty(secrets[field], "/secrets/{0}".format(field)))

    for component in COMPONENT_NAMES:
        component_path = "/components/{0}".format(component)
        if component in selected:
            for secret_name in COMPONENT_SECRETS[component]:
                secret_path = "/secrets/{0}".format(secret_name)
                if secret_name not in secrets:
                    issues.append(_issue("missing_component_secret", secret_path, "selected component secret is missing"))
                else:
                    issues.extend(_validate_nonempty(secrets[secret_name], secret_path))
                    if (
                        secrets[secret_name]
                        and secret_name != "keepalived_auth_password"
                        and not COMPONENT_SECRET_PATTERN.fullmatch(secrets[secret_name])
                    ):
                        issues.append(_issue("invalid_component_secret", secret_path, "service secret contains unsupported characters"))
        if component in selected and component not in components:
            issues.append(_issue("missing_selected_component", component_path, "selected component configuration is missing"))
            continue
        if component not in selected and component in components:
            issues.append(_issue("unselected_component", component_path, "component configuration is present but not selected", "warning"))
        if component not in components:
            continue

        role_counts = {role: 0 for role in ROLE_COUNTS[component]}
        for index, node in enumerate(components[component]["nodes"]):
            node_path = "{0}/nodes/{1}".format(component_path, index)
            ip_value = node["ip"]
            hostname_value = node["hostname"]
            if not _valid_ipv4(ip_value):
                issues.append(_issue("invalid_ipv4", node_path + "/ip", "invalid IPv4 address"))
            else:
                issues.extend(_record_unique(ip_index, ip_value, node_path + "/ip", "duplicate_ip", "IP address"))
            if not _valid_hostname(hostname_value):
                issues.append(_issue("invalid_hostname", node_path + "/hostname", "invalid hostname"))
            else:
                issues.extend(_record_unique(hostname_index, hostname_value, node_path + "/hostname", "duplicate_hostname", "hostname"))
            role_counts[node["role"]] += 1

        for role, expected_count in ROLE_COUNTS[component].items():
            if role_counts[role] != expected_count:
                issues.append(
                    _issue(
                        "invalid_role_count",
                        component_path + "/nodes",
                        "role {0} requires {1} node(s), found {2}".format(role, expected_count, role_counts[role]),
                    )
                )

        service = components[component]["service"]
        for field, value in service.items():
            path = "{0}/service/{1}".format(component_path, field)
            if field.endswith("port"):
                issues.extend(_validate_port(value, path))
            elif isinstance(value, str):
                issues.extend(_validate_nonempty(value, path))
        if component == "mysql":
            vip = service["vip"]
            vip_path = component_path + "/service/vip"
            if not _valid_ipv4(vip):
                issues.append(_issue("invalid_ipv4", vip_path, "invalid IPv4 address"))
            elif vip in ip_index:
                issues.append(_issue("vip_conflict", vip_path, "VIP conflicts with {0}".format(ip_index[vip])))
            if service["vip_prefix"] < 1 or service["vip_prefix"] > 32:
                issues.append(_issue("invalid_prefix", component_path + "/service/vip_prefix", "IPv4 prefix must be between 1 and 32"))
            elif _valid_ipv4(vip):
                vip_network = ipaddress.ip_network("{0}/{1}".format(vip, service["vip_prefix"]), strict=False)
                if any(_valid_ipv4(node["ip"]) and ipaddress.ip_address(node["ip"]) not in vip_network for node in components[component]["nodes"]):
                    issues.append(
                        _issue(
                            "vip_subnet_unconfirmed",
                            vip_path,
                            "VIP and MySQL nodes are not all inside the configured prefix; verify routing and VRRP layer-2 reachability",
                            "warning",
                        )
                    )
            if service["keepalived_router_id"] < 1 or service["keepalived_router_id"] > 255:
                issues.append(_issue("invalid_router_id", component_path + "/service/keepalived_router_id", "VRRP router ID must be between 1 and 255"))

    keepalived_auth = secrets.get("keepalived_auth_password")
    if "mysql" in selected and keepalived_auth and not KEEPALIVED_AUTH_PATTERN.fullmatch(keepalived_auth):
        issues.append(
            _issue(
                "invalid_keepalived_auth",
                "/secrets/keepalived_auth_password",
                "Keepalived auth must be 1-8 compatible ASCII characters",
            )
        )

    return sorted(issues, key=lambda item: (item.path, item.code, item.severity, item.message))


def validation_result(config: Mapping[str, Any]) -> Dict[str, Any]:
    try:
        issues = validate_semantics(config)
    except ConfigSchemaError as error:
        issues = [ValidationIssue(**error.as_dict())]
    return {
        "valid": not any(issue.severity == "error" for issue in issues),
        "issues": [issue.as_dict() for issue in issues],
    }


def format_text(issues: Sequence[ValidationIssue]) -> str:
    if not issues:
        return "VALID"
    return "\n".join("{0} {1} {2}: {3}".format(item.severity.upper(), item.code, item.path, item.message) for item in issues)