"""Loopback-only offline configuration workbench."""

import hmac
import json
import shutil
import secrets
import socket
import subprocess
import threading
import time
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
    from .generations import GenerationError, new_utc_generation_id, publish_staging
    from .preflight import run_preflight
    from .render import RenderError, render_files, write_staging_directory
except ImportError:
    from schema import ConfigSchemaError, load_config
    from redact import redact_sensitive, redacted_summary
    from schema import CONFIG_SCHEMA
    from secrets_policy import generate_secret
    from validate import validation_result
    from generations import GenerationError, new_utc_generation_id, publish_staging
    from preflight import run_preflight
    from render import RenderError, render_files, write_staging_directory


MAX_REQUEST_BYTES = 256 * 1024
SESSION_SECONDS = 30 * 60
CONFIRMATION_SECONDS = 5 * 60
STATIC_DIR = Path(__file__).resolve().parent / "workbench_static"
DEPLOY_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = DEPLOY_DIR.parent.parent


class WorkbenchState:
    def __init__(self, pairing_code: str) -> None:
        self.pairing_code = pairing_code
        self.sessions: Dict[str, float] = {}
        self.draft: Optional[Dict[str, Any]] = None
        self.preflight: Optional[Dict[str, Any]] = None
        self.pending_deployment: Optional[Dict[str, str]] = None
        self.deployment: Optional[Dict[str, Any]] = None
        self.deployment_lock = threading.Lock()
        self.fingerprint_key = secrets.token_bytes(32)
        self.lock = threading.Lock()

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
        return subprocess.Popen(
            ["/bin/bash", str(DEPLOY_DIR / "init_ansible.sh"), "deploy", "--components", components, "--yes"],
            cwd=str(DEPLOY_DIR),
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "DELIVERY_CONFIG_FILE": str(config_file),
                "DELIVERY_PLAYBOOK_DIR": str(playbook_dir),
                "DELIVERY_LOG_DIR": str(self.runtime_dir / "logs"),
                "DELIVERY_STATE_DIR": str(self.runtime_dir / "state"),
            },
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

    def watch_deployment(self, process: Any, request_id: str) -> None:
        try:
            exit_code = process.wait()
        except OSError:
            exit_code = None
        try:
            with self.state.lock:
                deployment = self.state.deployment
                if deployment and hmac.compare_digest(deployment["request_id"], request_id):
                    deployment["status"] = "succeeded" if exit_code == 0 else "failed"
                    deployment["exit_code"] = exit_code
        finally:
            if self.state.deployment_lock.locked():
                self.state.deployment_lock.release()

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
            with self.server.state.lock:
                self.server.state.preflight = {
                    "fingerprint": self._config_fingerprint(config),
                    "passed": not any(item.get("status") == "fail" for item in checks),
                }
            self._json(HTTPStatus.OK, {"results": checks})
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
            if hasattr(process, "wait"):
                self.server.deployment_thread = threading.Thread(target=self.server.watch_deployment, args=(process, request_id), daemon=True)
                self.server.deployment_thread.start()
            else:
                self.server.state.deployment_lock.release()
            self._json(HTTPStatus.ACCEPTED, deployment)
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


def create_server(pairing_code: Optional[str] = None, runtime_dir: Optional[Path] = None, project_root: Optional[Path] = None, deploy_runner: Any = None, preflight_runner: Any = None) -> Tuple[WorkbenchServer, str]:
    code = pairing_code or secrets.token_urlsafe(9)
    return WorkbenchServer(WorkbenchState(code), runtime_dir or DEPLOY_DIR / ".runtime", project_root or PROJECT_ROOT, deploy_runner, preflight_runner), code


def serve() -> int:
    server, code = create_server()
    print("Workbench URL: http://127.0.0.1:{0}/".format(server.server_port))
    print("Pairing code: {0}".format(code))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0