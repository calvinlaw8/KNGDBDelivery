"""Explicit, bounded remote preflight checks with secret-safe process handling."""

import shutil
import socket
import subprocess
import time
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence


SSH_TIMEOUT_SECONDS = 10
TCP_TIMEOUT_SECONDS = 5
TOTAL_TIMEOUT_SECONDS = 90
PLATFORM_COMMAND = "printf 'os='; . /etc/os-release 2>/dev/null; printf '%s\\narch=' \"${PRETTY_NAME:-unknown}\"; uname -m; printf 'disk_kb='; df -Pk / | awk 'NR==2 {print $4}'"
SUDO_COMMAND = "sudo -k && sudo -n true"


def _result(node_id: str, check: str, status: str, code: str, advice: str) -> Dict[str, str]:
    return {"node_id": node_id, "check": check, "status": status, "code": code, "advice": advice}


def _nodes(config: Mapping[str, Any]) -> List[Dict[str, str]]:
    result = [{"id": "management", "ip": config["management"]["ip"], "user": config["ssh"]["management_user"], "password": config["secrets"]["management_ssh_password"]}]
    for component in config["deployment"]["components"]:
        for index, node in enumerate(config["components"][component]["nodes"], 1):
            result.append({"id": "{0}-{1}".format(component, index), "ip": node["ip"], "user": config["ssh"]["database_user"], "password": config["secrets"]["database_ssh_password"]})
    return result


def _ports(config: Mapping[str, Any]) -> Dict[str, List[int]]:
    result: Dict[str, List[int]] = {}
    for name in config["deployment"]["components"]:
        service = config["components"][name]["service"]
        if name == "redis":
            result[name] = [service["port"], service["sentinel_port"]]
        elif name == "rabbitmq":
            result[name] = [5672, service["management_port"]]
        else:
            result[name] = [service["port"]]
    return result


def _run_ssh(node: Mapping[str, str], command: str, runner: Callable[..., Any]) -> Any:
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SSHPASS": node["password"]}
    arguments = ["sshpass", "-e", "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout={0}".format(SSH_TIMEOUT_SECONDS), "{0}@{1}".format(node["user"], node["ip"]), command]
    return runner(arguments, environment, SSH_TIMEOUT_SECONDS + 2)


def _default_runner(arguments: Sequence[str], environment: Mapping[str, str], timeout: int) -> subprocess.CompletedProcess:
    return subprocess.run(list(arguments), check=False, capture_output=True, text=True, timeout=timeout, env=dict(environment))


def _default_tcp_connect(ip: str, port: int, timeout: int) -> None:
    with socket.create_connection((ip, port), timeout=timeout):
        return None


def _port_command(ports: Sequence[int]) -> str:
    patterns = "|".join(":{0}([[:space:]]|$)".format(port) for port in ports)
    return "ss -ltn | grep -Eq '{0}'".format(patterns)


def run_preflight(config: Mapping[str, Any], runner: Optional[Callable[..., Any]] = None, tcp_connect: Optional[Callable[..., None]] = None) -> List[Dict[str, str]]:
    """Run explicitly requested checks; all returned data is non-sensitive."""
    command_runner = runner or _default_runner
    connect = tcp_connect or _default_tcp_connect
    results: List[Dict[str, str]] = []
    deadline = time.monotonic() + TOTAL_TIMEOUT_SECONDS
    missing = [tool for tool in ("ssh", "sshpass") if not shutil.which(tool)]
    results.append(_result("local", "dependencies", "pass" if not missing else "fail", "dependencies_ok" if not missing else "dependencies_missing", "" if not missing else "Install: {0}".format(", ".join(missing))))
    if missing:
        return results
    for node in _nodes(config):
        node_id = node["id"]
        if time.monotonic() >= deadline:
            results.append(_result(node_id, "preflight", "warning", "total_timeout", "Preflight time limit reached; retry this configured node."))
            continue
        try:
            connect(node["ip"], 22, TCP_TIMEOUT_SECONDS)
            results.append(_result(node_id, "tcp_22", "pass", "tcp_connected", ""))
        except OSError:
            results.append(_result(node_id, "tcp_22", "fail", "tcp_unreachable", "Check the configured host, network path, and SSH port."))
            continue
        try:
            login = _run_ssh(node, "true", command_runner)
        except (OSError, subprocess.TimeoutExpired):
            results.append(_result(node_id, "ssh", "fail", "ssh_execution_failed", "Check SSH client access and credentials."))
            continue
        if login.returncode != 0:
            results.append(_result(node_id, "ssh", "fail", "ssh_login_failed", "Check the configured SSH account and credentials."))
            continue
        results.append(_result(node_id, "ssh", "pass", "ssh_login_ok", ""))
        sudo = _run_ssh(node, SUDO_COMMAND, command_runner)
        results.append(_result(node_id, "sudo", "pass" if sudo.returncode == 0 else "fail", "sudo_ok" if sudo.returncode == 0 else "sudo_password_required", "" if sudo.returncode == 0 else "Configure passwordless sudo, then retry."))
        platform = _run_ssh(node, PLATFORM_COMMAND, command_runner)
        results.append(_result(node_id, "platform", "pass" if platform.returncode == 0 else "warning", "platform_ok" if platform.returncode == 0 else "platform_unavailable", "" if platform.returncode == 0 else "Confirm Ubuntu amd64 and available disk space."))
        if node_id != "management":
            component = node_id.rsplit("-", 1)[0]
            occupied = _run_ssh(node, _port_command(_ports(config)[component]), command_runner)
            if occupied.returncode == 0:
                results.append(_result(node_id, "ports", "fail", "ports_occupied", "Stop or reconfigure the service using required ports."))
            elif occupied.returncode == 1:
                results.append(_result(node_id, "ports", "pass", "ports_available", ""))
            else:
                results.append(_result(node_id, "ports", "warning", "ports_check_failed", "Confirm required ports manually before deployment."))
    return results