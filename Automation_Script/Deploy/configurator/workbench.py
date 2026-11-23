"""Loopback-only offline configuration workbench."""

import hmac
import hashlib
import json
import os
import re
import shutil
import secrets
import signal
import socket
import subprocess
import threading
import time
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional, Tuple
from urllib.parse import urlsplit

try:
    from .schema import ConfigSchemaError, load_config
    from .redact import redact_sensitive, redacted_summary
    from .schema import CONFIG_SCHEMA
    from .secrets_policy import generate_secret
    from .validate import validation_result
    from .generations import GenerationError, new_utc_generation_id, publish_staging, resolve_current
    from .migrate import MigrationError, parse_legacy_env_bytes
    from .preflight import run_preflight
    from .render import RenderError, render_files, write_staging_directory
except ImportError:
    from schema import ConfigSchemaError, load_config
    from redact import redact_sensitive, redacted_summary
    from schema import CONFIG_SCHEMA
    from secrets_policy import generate_secret
    from validate import validation_result
    from generations import GenerationError, new_utc_generation_id, publish_staging, resolve_current
    from migrate import MigrationError, parse_legacy_env_bytes
    from preflight import run_preflight
    from render import RenderError, render_files, write_staging_directory


MAX_REQUEST_BYTES = 256 * 1024
SESSION_SECONDS = 30 * 60
CONFIRMATION_SECONDS = 5 * 60
STATIC_DIR = Path(__file__).resolve().parent / "workbench_static"
DEPLOY_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = DEPLOY_DIR.parent.parent
CURRENT_COMPONENT_ROLES = {
    "redis": ("master", "replica", "replica"),
    "rabbitmq": ("seed", "member", "member"),
    "mongodb": ("primary", "secondary", "secondary"),
    "mysql": ("primary", "replica", "replica"),
}
CURRENT_SERVICE_DEFAULTS = {
    "redis": {"port": 6379, "sentinel_port": 26379},
    "rabbitmq": {"management_port": 15672},
    "mongodb": {"port": 27017},
    "mysql": {"port": 3306},
}
CURRENT_SECRET_FIELDS = (
    "management_ssh_password",
    "database_ssh_password",
    "redis_password",
    "rabbitmq_cookie",
    "rabbitmq_admin_password",
    "mongodb_admin_password",
    "mysql_root_password",
    "mysql_replication_password",
    "mysql_vip_verify_password",
    "keepalived_auth_password",
)
CURRENT_SECRET_ENV_KEYS = {
    "management_ssh_password": "ANSIBLE_NODE_PASS",
    "database_ssh_password": "DB_PASS",
    "redis_password": "REDIS_PASSWORD",
    "rabbitmq_cookie": "RABBITMQ_COOKIE",
    "rabbitmq_admin_password": "RABBITMQ_ADMIN_PASSWORD",
    "mongodb_admin_password": "MONGODB_ADMIN_PASSWORD",
    "mysql_root_password": "MYSQL_ROOT_PASSWORD",
    "mysql_replication_password": "MYSQL_REPLICATION_PASSWORD",
    "mysql_vip_verify_password": "MYSQL_VIP_VERIFY_PASSWORD",
    "keepalived_auth_password": "KEEPALIVED_AUTH_PASSWORD",
}
CURRENT_GROUP_SECRET_KEYS = {
    "redis": {"redis_password": "redis_password"},
    "rabbitmq": {"erlang_cookie": "rabbitmq_cookie", "rabbitmq_admin_password": "rabbitmq_admin_password"},
    "mongodb": {"mongodb_admin_password": "mongodb_admin_password"},
    "mysql": {"mysql_root_password": "mysql_root_password", "mysql_repl_password": "mysql_replication_password", "mysql_vip_verify_password": "mysql_vip_verify_password", "keepalived_auth_pass": "keepalived_auth_password"},
}
CURRENT_GROUP_SERVICE_KEYS = {
    "redis": {"redis_port": "port", "sentinel_port": "sentinel_port", "sentinel_master_name": "sentinel_master_name"},
    "rabbitmq": {"rabbitmq_admin_user": "admin_user", "rabbitmq_management_port": "management_port"},
    "mongodb": {"mongodb_admin_user": "admin_user", "mongodb_port": "port", "mongodb_replicaset": "replica_set"},
    "mysql": {"mysql_repl_user": "replication_user", "mysql_vip_verify_user": "vip_verify_user", "mysql_vip": "vip", "mysql_vip_prefix": "vip_prefix", "keepalived_interface": "keepalived_interface", "keepalived_router_id": "keepalived_router_id"},
}


def _sealed_group_vars(generation: Path, component: str) -> Dict[str, Any]:
    """Read only known top-level scalar keys from sealed generated group vars."""
    path = generation / "secrets/playbooks/group_vars" / (component + ".yml")
    values: Dict[str, Any] = {}
    key_pattern = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)[ ]*:[ ]*(.*)$")
    for line in path.read_text(encoding="utf-8").splitlines():
        match = key_pattern.match(line)
        if not match:
            continue
        key, raw = match.groups()
        if key not in set(CURRENT_GROUP_SECRET_KEYS[component]) | set(CURRENT_GROUP_SERVICE_KEYS[component]):
            continue
        raw = raw.strip()
        if not raw or raw.startswith("[") or raw.startswith("{") or raw.startswith("!"):
            continue
        if raw.startswith(('"', "'")) and raw[-1:] == raw[0]:
            raw = raw[1:-1]
        if raw in ("true", "false"):
            values[key] = raw == "true"
        else:
            try:
                values[key] = int(raw)
            except ValueError:
                values[key] = raw
    return values


def current_generation_preflight_input(runtime_dir: Path) -> Tuple[str, Dict[str, Any], Dict[str, Any]]:
    """Read fixed generated keys required by preflight without executing or exposing config.env."""
    generation = resolve_current(runtime_dir)
    if generation is None:
        raise ValueError("no current generation is available")
    try:
        parsed = parse_legacy_env_bytes((generation / "secrets/config.env").read_bytes())
        scalars = parsed["scalars"]
        arrays = parsed["arrays"]
        selected = scalars["DEPLOY_COMPONENTS"].split(",")
        if not selected or any(name not in CURRENT_COMPONENT_ROLES for name in selected):
            raise ValueError("current generation has invalid components")
        components = {}
        for name in selected:
            prefix = name.upper()
            ips = arrays[prefix + "_IPS"]
            hostnames = arrays[prefix + "_HOSTNAMES"]
            if len(ips) != 3 or len(hostnames) != 3:
                raise ValueError("current generation has incomplete node topology")
            components[name] = {
                "nodes": [{"ip": ips[index], "hostname": hostnames[index], "role": CURRENT_COMPONENT_ROLES[name][index]} for index in range(3)],
                "service": CURRENT_SERVICE_DEFAULTS[name],
            }
        plan = json.loads((generation / "config/deployment-plan.json").read_text(encoding="utf-8"))
        secrets_config = {}
        for field in CURRENT_SECRET_FIELDS:
            env_key = CURRENT_SECRET_ENV_KEYS[field]
            if env_key in scalars:
                secrets_config[field] = scalars[env_key]
        group_values = {name: _sealed_group_vars(generation, name) for name in selected}
        for name, mapping in CURRENT_GROUP_SECRET_KEYS.items():
            if name not in group_values:
                continue
            for source_key, config_key in mapping.items():
                if source_key in group_values[name] and config_key in secrets_config:
                    continue
                if source_key in group_values[name]:
                    if config_key in secrets_config:
                        continue
                    secrets_config[config_key] = group_values[name][source_key]
        for name in selected:
            service = components[name]["service"]
            for source_key, config_key in CURRENT_GROUP_SERVICE_KEYS[name].items():
                if source_key in group_values[name]:
                    service[config_key] = group_values[name][source_key]
        config = {
            "schema_version": 1,
            "deployment": {"components": selected},
            "management": {"ip": scalars["ANSIBLE_NODE_IP"], "hostname": scalars["ANSIBLE_NODE_HOSTNAME"]},
            "ssh": {"management_user": scalars["ANSIBLE_NODE_USER"], "database_user": scalars["DB_USER"]},
            "components": components,
            "secrets": secrets_config,
        }
    except (KeyError, MigrationError, UnicodeError, json.JSONDecodeError, OSError) as error:
        raise ValueError("current generation has an unsupported runtime format") from error
    return generation.name, config, plan


def refresh_current_generation_playbooks(runtime_dir: Path) -> str:
    """Publish a new generation with the fixed source playbooks and unchanged sealed config bytes."""
    current = resolve_current(runtime_dir)
    if current is None:
        raise ValueError("no current generation is available")
    generation_id = new_utc_generation_id()
    staging = runtime_dir / ".staging-{0}".format(generation_id)
    try:
        staging.mkdir(mode=0o700)
        for source in (current / "config").iterdir():
            shutil.copy2(str(source), str(staging / source.name))
        for source in (current / "secrets").iterdir():
            if source.name == "playbooks":
                continue
            shutil.copy2(str(source), str(staging / source.name))
        shutil.copytree(str(current / "secrets/playbooks"), str(staging / "playbooks"))
        for directory in ("preflights", "site"):
            target = staging / "playbooks" / directory
            shutil.rmtree(str(target))
            shutil.copytree(str(DEPLOY_DIR / "playbooks" / directory), str(target))
        publish_staging(runtime_dir, staging, generation_id)
    except (GenerationError, FileExistsError, OSError):
        shutil.rmtree(str(staging), ignore_errors=True)
        raise
    return generation_id


class WorkbenchState:
    def __init__(self, pairing_code: str, runtime_dir: Path) -> None:
        self.pairing_code = pairing_code
        self.runtime_dir = runtime_dir
        self.sessions: Dict[str, float] = {}
        self.draft: Optional[Dict[str, Any]] = None
        self.preflight: Optional[Dict[str, Any]] = None
        self.pending_deployment: Optional[Dict[str, str]] = None
        self.deployment: Optional[Dict[str, Any]] = None
        self.deployment_process: Any = None
        self.failed_deployments = self._load_failed_deployments()
        self.deployment_lock = threading.Lock()
        self.fingerprint_key = secrets.token_bytes(32)
        self.lock = threading.Lock()

    def _failure_state_path(self) -> Path:
        return self.runtime_dir / "state/deployment-failures.json"

    def _load_failed_deployments(self) -> Dict[str, Dict[str, Any]]:
        path = self._failure_state_path()
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return {}
        if not isinstance(value, dict):
            return {}
        return {
            generation_id: record
            for generation_id, record in value.items()
            if isinstance(generation_id, str) and isinstance(record, dict) and record.get("status") == "failed"
        }

    def persist_failed_deployment(self, deployment: Dict[str, Any], generation_fingerprint: str) -> None:
        generation_id = deployment["generation_id"]
        record = {
            "generation_id": generation_id,
            "generation_fingerprint": generation_fingerprint,
            "status": "failed",
            "exit_code": deployment.get("exit_code"),
            "failed_at": int(time.time()),
        }
        with self.lock:
            self.failed_deployments[generation_id] = record
            path = self._failure_state_path()
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            temporary = path.with_name(path.name + ".tmp")
            with temporary.open("w", encoding="utf-8", newline="\n") as stream:
                json.dump(self.failed_deployments, stream, sort_keys=True, separators=(",", ":"))
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(str(temporary), 0o600)
            os.replace(str(temporary), str(path))

    def pair(self, candidate: str) -> Optional[str]:
        with self.lock:
            if not hmac.compare_digest(candidate, self.pairing_code):
                return None
            token = secrets.token_urlsafe(32)
            self.sessions[token] = time.monotonic() + SESSION_SECONDS
            self.pairing_code = ""
            return token

    def authenticated(self, token: str) -> bool:
        with self.lock:
            expires = self.sessions.get(token, 0)
            if expires <= time.monotonic():
                self.sessions.pop(token, None)
                return False
            return True

    def clear(self) -> None:
        with self.lock:
            self.pairing_code = ""
            self.sessions.clear()
            self.draft = None
            self.preflight = None
            self.pending_deployment = None
            self.deployment = None
            self.deployment_process = None


class WorkbenchServer(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, state: WorkbenchState, runtime_dir: Path, project_root: Path, deploy_runner: Any = None, preflight_runner: Any = None) -> None:
        super().__init__(("127.0.0.1", 0), WorkbenchHandler)
        self.state = state
        self.runtime_dir = runtime_dir
        self.project_root = project_root
        self.deploy_runner = deploy_runner or self._start_deployment
        self.preflight_runner = preflight_runner or run_preflight
        self.deployment_thread: Optional[threading.Thread] = None

    def _start_deployment(self, config_file: Path, playbook_dir: Path, components: str) -> subprocess.Popen:
        tool_directories = []
        for tool in ("ssh", "sshpass", "scp", "rsync"):
            resolved = shutil.which(tool)
            if resolved:
                directory = str(Path(resolved).parent)
                if directory not in tool_directories:
                    tool_directories.append(directory)
        executable_path = ":".join(tool_directories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        log_dir = self.runtime_dir / "logs"
        log_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        launch_log = log_dir / "workbench-deploy-{0}.log".format(config_file.parent.parent.name)
        launch_stream = launch_log.open("ab", buffering=0)
        launch_log.chmod(0o600)
        try:
            return subprocess.Popen(
                ["/bin/bash", str(DEPLOY_DIR / "init_ansible.sh"), "deploy", "--components", components, "--yes"],
                cwd=str(DEPLOY_DIR),
                env={
                    "PATH": executable_path,
                    "DELIVERY_CONFIG_FILE": str(config_file),
                    "DELIVERY_PLAYBOOK_DIR": str(playbook_dir),
                    "DELIVERY_LOG_DIR": str(self.runtime_dir / "logs"),
                    "DELIVERY_STATE_DIR": str(self.runtime_dir / "state"),
                },
                stdin=subprocess.DEVNULL, stdout=launch_stream, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        finally:
            launch_stream.close()

    def watch_deployment(self, process: Any, request_id: str) -> None:
        failed_deployment = None
        try:
            exit_code = process.wait()
        except OSError:
            exit_code = None
        try:
            with self.state.lock:
                deployment = self.state.deployment
                if deployment and hmac.compare_digest(deployment["request_id"], request_id):
                    if deployment.get("status") == "remote_state_unknown":
                        deployment["status"] = "remote_state_unknown"
                    elif deployment.get("status") == "stop_requested":
                        deployment["status"] = "cancelled" if exit_code is not None else "remote_state_unknown"
                    else:
                        deployment["status"] = "succeeded" if exit_code == 0 else "failed"
                    deployment["exit_code"] = exit_code
                    self.state.deployment_process = None
                    if deployment.get("status") == "failed":
                        failed_deployment = dict(deployment)
            if failed_deployment:
                generation = self.runtime_dir / "generations" / failed_deployment["generation_id"]
                self.state.persist_failed_deployment(failed_deployment, _generation_fingerprint(generation))
        finally:
            if self.state.deployment_lock.locked():
                self.state.deployment_lock.release()

    def deployment_is_active(self) -> bool:
        thread = self.deployment_thread
        return self.state.deployment_lock.locked() and thread is not None and thread.is_alive()

    def server_close(self) -> None:
        self.state.clear()
        super().server_close()


class WorkbenchHandler(BaseHTTPRequestHandler):
    server: WorkbenchServer

    def log_message(self, format_string: str, *args: Any) -> None:
        return

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        super().end_headers()

    def _request_is_local(self) -> bool:
        host = self.headers.get("Host", "")
        hostname = host.rsplit(":", 1)[0].strip("[]").lower()
        if hostname not in ("127.0.0.1", "localhost"):
            return False
        origin = self.headers.get("Origin")
        if not origin:
            return True
        parsed = urlsplit(origin)
        return parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost") and parsed.port == self.server.server_port

    def _json(self, status: int, value: Any, cookie: Optional[str] = None) -> None:
        body = json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if cookie:
            self.send_header("Set-Cookie", "ecopilot_session={0}; HttpOnly; SameSite=Strict; Path=/; Max-Age={1}".format(cookie, SESSION_SECONDS))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            return

    def _body(self) -> Optional[Dict[str, Any]]:
        if self.headers.get_content_type() != "application/json":
            self._json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"error": "JSON Content-Type required"})
            return None
        length = int(self.headers.get("Content-Length", "0"))
        if length < 1 or length > MAX_REQUEST_BYTES:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "request body size is invalid"})
            return None
        try:
            value = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(HTTPStatus.BAD_REQUEST, {"error": "invalid JSON"})
            return None
        if not isinstance(value, dict):
            self._json(HTTPStatus.BAD_REQUEST, {"error": "JSON object required"})
            return None
        return value

    def _session(self) -> bool:
        cookies = self.headers.get("Cookie", "").split(";")
        token = next((part.strip().split("=", 1)[1] for part in cookies if part.strip().startswith("ecopilot_session=")), "")
        if self.server.state.authenticated(token):
            return True
        self._json(HTTPStatus.UNAUTHORIZED, {"error": "pairing required"})
        return False

    def _static(self, name: str, content_type: str) -> None:
        body = (STATIC_DIR / name).read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _config_fingerprint(self, config: Dict[str, Any]) -> str:
        encoded = json.dumps(config, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return hmac.new(self.server.state.fingerprint_key, encoded, "sha256").hexdigest()

    def do_GET(self) -> None:
        if not self._request_is_local():
            self._json(HTTPStatus.FORBIDDEN, {"error": "loopback Host and Origin required"})
        elif self.path == "/health":
            self._json(HTTPStatus.OK, {"status": "ready"})
        elif self.path in ("/", "/index.html"):
            self._static("index.html", "text/html; charset=utf-8")
        elif self.path == "/app.css":
            self._static("app.css", "text/css; charset=utf-8")
        elif self.path == "/topology.js":
            self._static("topology.js", "text/javascript; charset=utf-8")
        elif self.path == "/app.js":
            self._static("app.js", "text/javascript; charset=utf-8")
        elif self.path == "/api/config" and self._session():
            with self.server.state.lock:
                self._json(HTTPStatus.OK, {"config": self.server.state.draft})
        elif self.path == "/api/deploy/status" and self._session():
            with self.server.state.lock:
                self._json(HTTPStatus.OK, {"deployment": self.server.state.deployment})
        else:
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self) -> None:
        if not self._request_is_local():
            self._json(HTTPStatus.FORBIDDEN, {"error": "loopback Host and Origin required"})
            return
        body = self._body()
        if body is None:
            return
        if self.path == "/api/pair":
            token = self.server.state.pair(str(body.get("code", "")))
            if not token:
                self._json(HTTPStatus.UNAUTHORIZED, {"error": "invalid pairing code"})
            else:
                self._json(HTTPStatus.OK, {"paired": True}, token)
        elif self.path == "/api/validate" and self._session():
            try:
                config = load_config(json.dumps(body.get("config"), ensure_ascii=False))
            except ConfigSchemaError as error:
                result = {"valid": False, "issues": [{**error.as_dict(), "severity": "error"}]}
            else:
                result = validation_result(config)
            result["revision"] = body.get("revision")
            self._json(HTTPStatus.OK, result)
        elif self.path == "/api/secrets/generate" and self._session():
            name = body.get("name")
            if not isinstance(name, str):
                self._json(HTTPStatus.BAD_REQUEST, {"error": "secret name is required"})
                return
            try:
                value = generate_secret(name)
            except ValueError:
                self._json(HTTPStatus.BAD_REQUEST, {"error": "unknown secret field"})
                return
            self._json(HTTPStatus.OK, {"name": name, "value": value})
        elif self.path == "/api/import" and self._session():
            source = body.get("config")
            if not isinstance(source, str):
                self._json(HTTPStatus.BAD_REQUEST, {"error": "JSON text is required"})
                return
            try:
                config = load_config(source)
            except ConfigSchemaError as error:
                self._json(HTTPStatus.BAD_REQUEST, {"valid": False, "issues": [{**error.as_dict(), "severity": "error"}]})
                return
            result = validation_result(config)
            self._json(HTTPStatus.OK, {"valid": result["valid"], "issues": result["issues"], "summary": redacted_summary(config)})
        elif self.path == "/api/current/preflight" and self._session():
            if body.get("fingerprint_risk_acknowledged") is not True:
                self._json(HTTPStatus.BAD_REQUEST, {"error": "host fingerprint risk acknowledgement is required"})
                return
            try:
                generation_id, config, plan = current_generation_preflight_input(self.server.runtime_dir)
                checks = self.server.preflight_runner(config)
            except (OSError, ValueError):
                self._json(HTTPStatus.CONFLICT, {"error": "current generation preflight could not start"})
                return
            passed = not any(item.get("status") == "fail" for item in checks)
            with self.server.state.lock:
                self.server.state.preflight = {"generation_id": generation_id, "passed": passed}
                self.server.state.pending_deployment = None
            self._json(HTTPStatus.OK, {"generation_id": generation_id, "passed": passed, "plan": plan, "results": checks})
        elif self.path == "/api/current/restore" and self._session():
            try:
                generation_id, config, _ = current_generation_preflight_input(self.server.runtime_dir)
                result = validation_result(config)
            except (OSError, ValueError):
                self._json(HTTPStatus.CONFLICT, {"error": "current generation could not be restored"})
                return
            if not result["valid"]:
                self._json(HTTPStatus.CONFLICT, {"error": "current generation cannot form a valid draft"})
                return
            with self.server.state.lock:
                self.server.state.draft = config
                self.server.state.preflight = None
                self.server.state.pending_deployment = None
            self._json(HTTPStatus.OK, {"generation_id": generation_id, "config": config, "issues": []})
        elif self.path == "/api/current/deploy/prepare" and self._session():
            try:
                generation_id, _, plan = current_generation_preflight_input(self.server.runtime_dir)
            except ValueError:
                self._json(HTTPStatus.CONFLICT, {"error": "current generation is unavailable"})
                return
            with self.server.state.lock:
                preflight = self.server.state.preflight
                if not preflight or not preflight["passed"] or preflight.get("generation_id") != generation_id:
                    self._json(HTTPStatus.CONFLICT, {"error": "a successful current-generation preflight is required before deployment"})
                    return
                confirmation_token = secrets.token_urlsafe(32)
                self.server.state.pending_deployment = {"generation_id": generation_id, "token": confirmation_token, "expires": time.monotonic() + CONFIRMATION_SECONDS}
            self._json(HTTPStatus.OK, {"generation_id": generation_id, "plan": plan, "confirmation_token": confirmation_token})
        elif self.path == "/api/current/refresh-playbooks" and self._session():
            with self.server.state.lock:
                preflight = self.server.state.preflight
                deployment = self.server.state.deployment
            try:
                current_id, _, _ = current_generation_preflight_input(self.server.runtime_dir)
                if not preflight or not preflight["passed"] or preflight.get("generation_id") != current_id:
                    self._json(HTTPStatus.CONFLICT, {"error": "a successful current-generation preflight is required before refreshing playbooks"})
                    return
                if deployment and deployment.get("status") == "running" and self.server.deployment_is_active():
                    self._json(HTTPStatus.CONFLICT, {"error": "a deployment is already running"})
                    return
                if deployment and deployment.get("status") == "running":
                    with self.server.state.lock:
                        if self.server.state.deployment is deployment:
                            self.server.state.deployment = None
                generation_id = refresh_current_generation_playbooks(self.server.runtime_dir)
                _, _, plan = current_generation_preflight_input(self.server.runtime_dir)
            except (OSError, ValueError, GenerationError):
                self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "playbook refresh could not publish a new generation"})
                return
            with self.server.state.lock:
                self.server.state.preflight = None
                self.server.state.pending_deployment = None
            self._json(HTTPStatus.OK, {"generation_id": generation_id, "plan": plan})
        elif self.path == "/api/export" and self._session():
            try:
                config = load_config(json.dumps(body.get("config"), ensure_ascii=False))
            except ConfigSchemaError as error:
                self._json(HTTPStatus.BAD_REQUEST, {"valid": False, "issues": [{**error.as_dict(), "severity": "error"}]})
                return
            result = validation_result(config)
            if not result["valid"]:
                self._json(HTTPStatus.BAD_REQUEST, result)
                return
            self._json(HTTPStatus.OK, {"config": redact_sensitive(config, CONFIG_SCHEMA)})
        elif self.path == "/api/preflight" and self._session():
            if body.get("fingerprint_risk_acknowledged") is not True:
                self._json(HTTPStatus.BAD_REQUEST, {"error": "host fingerprint risk acknowledgement is required"})
                return
            try:
                config = load_config(json.dumps(body.get("config"), ensure_ascii=False))
                result = validation_result(config)
            except ConfigSchemaError as error:
                self._json(HTTPStatus.BAD_REQUEST, {"valid": False, "issues": [{**error.as_dict(), "severity": "error"}]})
                return
            if not result["valid"]:
                self._json(HTTPStatus.BAD_REQUEST, result)
                return
            try:
                checks = self.server.preflight_runner(config)
            except (OSError, ValueError):
                self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "preflight failed to start"})
                return
            passed = not any(item.get("status") == "fail" for item in checks)
            with self.server.state.lock:
                self.server.state.preflight = {
                    "fingerprint": self._config_fingerprint(config),
                    "passed": passed,
                }
            self._json(HTTPStatus.OK, {"passed": passed, "results": checks})
        elif self.path == "/api/generate" and self._session():
            try:
                config = load_config(json.dumps(body.get("config"), ensure_ascii=False))
                result = validation_result(config)
                if not result["valid"]:
                    self._json(HTTPStatus.BAD_REQUEST, result)
                    return
                with self.server.state.lock:
                    preflight = self.server.state.preflight
                if not preflight or not preflight["passed"] or not hmac.compare_digest(preflight["fingerprint"], self._config_fingerprint(config)):
                    self._json(HTTPStatus.CONFLICT, {"error": "a successful preflight is required before generation"})
                    return
                generation_id = new_utc_generation_id()
                staging = self.server.runtime_dir / ".staging-{0}".format(generation_id)
                runtime_playbook_dir = self.server.runtime_dir / "generations" / generation_id / "secrets/playbooks"
                files = render_files(config, self.server.project_root, runtime_playbook_dir, DEPLOY_DIR / "playbooks/group_vars")
                write_staging_directory(staging, files)
                shutil.copytree(str(DEPLOY_DIR / "playbooks/preflights"), str(staging / "playbooks/preflights"))
                shutil.copytree(str(DEPLOY_DIR / "playbooks/site"), str(staging / "playbooks/site"))
                publish_staging(self.server.runtime_dir, staging, generation_id)
            except ConfigSchemaError as error:
                self._json(HTTPStatus.BAD_REQUEST, {"valid": False, "issues": [{**error.as_dict(), "severity": "error"}]})
                return
            except (ConfigSchemaError, GenerationError, RenderError, FileExistsError, OSError) as error:
                if "staging" in locals():
                    shutil.rmtree(str(staging), ignore_errors=True)
                self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "generation failed: {0}".format(error)})
                return
            secret_bytes = json.dumps(config["secrets"], sort_keys=True, separators=(",", ":")).encode("utf-8")
            fingerprint = hmac.new(self.server.state.fingerprint_key, secret_bytes, "sha256").hexdigest()
            confirmation_token = secrets.token_urlsafe(32)
            with self.server.state.lock:
                self.server.state.pending_deployment = {"generation_id": generation_id, "fingerprint": fingerprint, "token": confirmation_token, "expires": time.monotonic() + CONFIRMATION_SECONDS}
            self._json(HTTPStatus.OK, {"generation_id": generation_id, "plan": json.loads(files["deployment-plan.json"]), "confirmation_token": confirmation_token, "fingerprint": fingerprint})
        elif self.path == "/api/deploy" and self._session():
            generation_id = body.get("generation_id")
            confirmation_token = body.get("confirmation_token")
            request_id = body.get("request_id")
            if not isinstance(generation_id, str) or not isinstance(confirmation_token, str) or not isinstance(request_id, str) or len(request_id) > 128:
                self._json(HTTPStatus.BAD_REQUEST, {"error": "generation confirmation is required"})
                return
            with self.server.state.lock:
                deployment = self.server.state.deployment
                failed_record = self.server.state.failed_deployments.get(generation_id)
                if failed_record:
                    self._json(HTTPStatus.CONFLICT, {"error": "the same failed generation is blocked; generate a new generation after fixing code or environment"})
                    return
                if deployment and deployment.get("status") == "failed" and deployment.get("generation_id") == generation_id:
                    self._json(HTTPStatus.CONFLICT, {"error": "the same failed generation is blocked; generate a new generation after fixing code or environment"})
                    return
                if deployment and hmac.compare_digest(deployment["request_id"], request_id):
                    self._json(HTTPStatus.ACCEPTED, deployment)
                    return
                if deployment and deployment.get("status") == "running":
                    self._json(HTTPStatus.CONFLICT, {"error": "a deployment is already running"})
                    return
                pending = self.server.state.pending_deployment
                if not pending or pending["expires"] <= time.monotonic() or pending["generation_id"] != generation_id or not hmac.compare_digest(pending["token"], confirmation_token):
                    self._json(HTTPStatus.CONFLICT, {"error": "deployment confirmation is invalid or expired"})
                    return
                self.server.state.pending_deployment = None
            if not self.server.state.deployment_lock.acquire(False):
                self._json(HTTPStatus.CONFLICT, {"error": "a deployment is already starting"})
                return
            generation = self.server.runtime_dir / "generations" / generation_id
            config_file = generation / "secrets/config.env"
            playbook_dir = generation / "secrets/playbooks"
            plan_file = generation / "config/deployment-plan.json"
            if not config_file.is_file() or not playbook_dir.is_dir() or not plan_file.is_file():
                self.server.state.deployment_lock.release()
                self._json(HTTPStatus.CONFLICT, {"error": "generated configuration is unavailable"})
                return
            components = ",".join(item["name"] for item in json.loads(plan_file.read_text(encoding="utf-8"))["components"])
            try:
                process = self.server.deploy_runner(config_file, playbook_dir, components)
            except OSError:
                self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "deployment could not start"})
                self.server.state.deployment_lock.release()
                return
            deployment = {"generation_id": generation_id, "request_id": request_id, "status": "running" if hasattr(process, "wait") else "started"}
            with self.server.state.lock:
                self.server.state.deployment = deployment
                self.server.state.deployment_process = process if hasattr(process, "wait") else None
            if hasattr(process, "wait"):
                self.server.deployment_thread = threading.Thread(target=self.server.watch_deployment, args=(process, request_id), daemon=True)
                self.server.deployment_thread.start()
            else:
                self.server.state.deployment_lock.release()
            self._json(HTTPStatus.ACCEPTED, deployment)
        elif self.path == "/api/deploy/cancel" and self._session():
            request_id = body.get("request_id")
            if not isinstance(request_id, str) or len(request_id) > 128:
                self._json(HTTPStatus.BAD_REQUEST, {"error": "deployment request id is required"})
                return
            with self.server.state.lock:
                deployment = self.server.state.deployment
                process = self.server.state.deployment_process
                if not deployment or deployment.get("request_id") != request_id:
                    self._json(HTTPStatus.NOT_FOUND, {"error": "deployment request was not found"})
                    return
                if deployment.get("status") != "running" or process is None:
                    self._json(HTTPStatus.CONFLICT, {"error": "deployment is not running"})
                    return
                deployment["status"] = "stop_requested"
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except (AttributeError, OSError):
                with self.server.state.lock:
                    if self.server.state.deployment is deployment:
                        deployment["status"] = "remote_state_unknown"
                self._json(HTTPStatus.CONFLICT, {"error": "local process group could not be stopped; remote state is unknown"})
                return
            self._json(HTTPStatus.ACCEPTED, {"request_id": request_id, "status": "stop_requested"})
        elif self.path == "/api/shutdown" and self._session():
            self._json(HTTPStatus.OK, {"stopping": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
        else:
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_PUT(self) -> None:
        if not self._request_is_local():
            self._json(HTTPStatus.FORBIDDEN, {"error": "loopback Host and Origin required"})
            return
        body = self._body()
        if body is None or not self._session():
            return
        if self.path != "/api/config":
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        try:
            config = load_config(json.dumps(body.get("config"), ensure_ascii=False))
        except ConfigSchemaError as error:
            self._json(HTTPStatus.BAD_REQUEST, {"valid": False, "issues": [{**error.as_dict(), "severity": "error"}]})
            return
        result = validation_result(config)
        if not result["valid"]:
            self._json(HTTPStatus.BAD_REQUEST, result)
            return
        with self.server.state.lock:
            self.server.state.draft = config
            self.server.state.preflight = None
            self.server.state.pending_deployment = None
        self._json(HTTPStatus.OK, result)


def _generation_fingerprint(generation: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(path for path in generation.rglob("*") if path.is_file()):
        digest.update(path.relative_to(generation).as_posix().encode("utf-8"))
        digest.update(b"\0")
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


def create_server(pairing_code: Optional[str] = None, runtime_dir: Optional[Path] = None, project_root: Optional[Path] = None, deploy_runner: Any = None, preflight_runner: Any = None) -> Tuple[WorkbenchServer, str]:
    code = pairing_code or secrets.token_urlsafe(9)
    resolved_runtime_dir = runtime_dir or DEPLOY_DIR / ".runtime"
    return WorkbenchServer(WorkbenchState(code, resolved_runtime_dir), resolved_runtime_dir, project_root or PROJECT_ROOT, deploy_runner, preflight_runner), code


def serve() -> int:
    server, code = create_server()
    url = "http://127.0.0.1:{0}/".format(server.server_port)
    print("Workbench URL: {0}".format(url))
    print("Pairing code: {0}".format(code))
    try:
        webbrowser.open(url)
    except Exception:
        pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0