"""Contract tests for the loopback-only offline workbench."""

import http.client
import json
import socket
import tempfile
import threading
import unittest
from pathlib import Path

try:
    from .secrets_policy import COMPATIBLE_ALPHABET, SECRET_LENGTHS
    from .workbench import MAX_REQUEST_BYTES, create_server
except ImportError:
    from secrets_policy import COMPATIBLE_ALPHABET, SECRET_LENGTHS
    from workbench import MAX_REQUEST_BYTES, create_server


EXAMPLE = Path(__file__).resolve().parent / "examples/config-v1.redis.json"
STATIC_DIR = Path(__file__).resolve().parent / "workbench_static"


class WorkbenchTests(unittest.TestCase):
    def setUp(self):
        self.runtime_root = tempfile.TemporaryDirectory()
        self.deploy_calls = []
        self.server, self.code = create_server("pair-once", Path(self.runtime_root.name) / "runtime", deploy_runner=lambda *args: self.deploy_calls.append(args))
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()

    def tearDown(self):
        if self.thread.is_alive():
            self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.runtime_root.cleanup()

    def request(self, method, path, value=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        body = None if value is None else json.dumps(value)
        request_headers = {"Host": "127.0.0.1:{0}".format(self.port)}
        if body is not None:
            request_headers["Content-Type"] = "application/json"
        request_headers.update(headers or {})
        connection.request(method, path, body=body, headers=request_headers)
        response = connection.getresponse()
        payload = json.loads(response.read().decode("utf-8"))
        result = response.status, dict(response.getheaders()), payload
        connection.close()
        return result

    def pair(self):
        status, headers, payload = self.request("POST", "/api/pair", {"code": self.code})
        self.assertEqual(status, 200)
        self.assertTrue(payload["paired"])
        cookie = headers["Set-Cookie"]
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        return cookie.split(";", 1)[0]

    def test_loopback_security_headers_and_one_time_pairing(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        status, headers, payload = self.request("GET", "/health")
        self.assertEqual((status, payload), (200, {"status": "ready"}))
        self.assertIn("default-src 'self'", headers["Content-Security-Policy"])
        self.assertEqual(headers["Cache-Control"], "no-store")
        cookie = self.pair()
        self.assertTrue(cookie.startswith("ecopilot_session="))
        self.assertEqual(self.request("POST", "/api/pair", {"code": self.code})[0], 401)

    def test_host_origin_auth_content_type_and_size_fail_closed(self):
        self.assertEqual(self.request("GET", "/health", headers={"Host": "example.test"})[0], 403)
        self.assertEqual(
            self.request("POST", "/api/pair", {"code": self.code}, {"Origin": "http://example.test"})[0],
            403,
        )
        self.assertEqual(self.request("GET", "/api/config")[0], 401)
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        connection.request("POST", "/api/pair", body="{}", headers={"Content-Type": "text/plain"})
        self.assertEqual(connection.getresponse().status, 415)
        connection.close()
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        connection.request(
            "POST",
            "/api/pair",
            body="",
            headers={"Content-Type": "application/json", "Content-Length": str(MAX_REQUEST_BYTES + 1)},
        )
        self.assertEqual(connection.getresponse().status, 413)
        connection.close()

    def test_config_uses_shared_validation_and_stays_in_memory(self):
        cookie = self.pair()
        config = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        headers = {"Cookie": cookie}
        status, _, payload = self.request("POST", "/api/validate", {"revision": 7, "config": config}, headers)
        self.assertEqual((status, payload["valid"], payload["revision"]), (200, True, 7))
        config["management"]["ip"] = "not-an-ip"
        status, _, payload = self.request("PUT", "/api/config", {"config": config}, headers)
        self.assertEqual(status, 400)
        self.assertEqual(payload["issues"][0]["path"], "/management/ip")
        self.assertIsNone(self.request("GET", "/api/config", headers=headers)[2]["config"])

    def test_secret_generation_requires_pairing_and_only_accepts_known_fields(self):
        self.assertEqual(self.request("POST", "/api/secrets/generate", {"name": "redis_password"})[0], 401)
        cookie = self.pair()
        headers = {"Cookie": cookie}
        status, _, payload = self.request("POST", "/api/secrets/generate", {"name": "redis_password"}, headers)
        self.assertEqual(status, 200)
        self.assertEqual(payload["name"], "redis_password")
        self.assertEqual(len(payload["value"]), SECRET_LENGTHS["redis_password"])
        self.assertTrue(set(payload["value"]).issubset(set(COMPATIBLE_ALPHABET)))
        self.assertEqual(
            self.request("POST", "/api/secrets/generate", {"name": "/secrets/redis_password"}, headers)[0],
            400,
        )
        self.assertIsNone(self.request("GET", "/api/config", headers=headers)[2]["config"])

    def test_import_and_export_validate_without_disclosing_secrets(self):
        cookie = self.pair()
        headers = {"Cookie": cookie}
        text = EXAMPLE.read_text(encoding="utf-8")
        status, _, payload = self.request("POST", "/api/import", {"config": text}, headers)
        self.assertEqual((status, payload["valid"], payload["summary"]["components"]), (200, True, ["redis"]))
        self.assertNotIn("secrets", payload["summary"])
        config = json.loads(text)
        status, _, payload = self.request("POST", "/api/export", {"config": config}, headers)
        self.assertEqual(status, 200)
        self.assertNotIn("secrets", payload["config"])
        self.assertNotIn("RedisPass", json.dumps(payload))
        config["schema_version"] = 99
        self.assertEqual(self.request("POST", "/api/import", {"config": json.dumps(config)}, headers)[0], 400)

    def test_generate_revalidates_and_only_publishes_local_generation(self):
        cookie = self.pair()
        config = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        self.server.preflight_runner = lambda candidate: []
        self.assertEqual(
            self.request(
                "POST",
                "/api/preflight",
                {"config": config, "fingerprint_risk_acknowledged": True},
                {"Cookie": cookie},
            )[0],
            200,
        )
        status, _, payload = self.request("POST", "/api/generate", {"config": config}, {"Cookie": cookie})
        self.assertEqual(status, 200)
        self.assertEqual(payload["plan"]["components"][0]["name"], "redis")
        generation = self.server.runtime_dir / "generations" / payload["generation_id"]
        self.assertTrue((generation / "secrets/config.env").is_file())
        self.assertTrue((generation / "secrets/playbooks/site/site.yml").is_file())
        self.assertTrue((generation / "config/deployment-plan.json").is_file())
        self.assertEqual(list((self.server.runtime_dir / "logs").iterdir()), [])
        self.assertEqual(list((self.server.runtime_dir / "state").iterdir()), [])
        config["management"]["ip"] = "invalid"
        self.assertEqual(self.request("POST", "/api/generate", {"config": config}, {"Cookie": cookie})[0], 400)

    def test_preflight_requires_explicit_risk_acknowledgement(self):
        cookie = self.pair()
        config = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        self.assertEqual(self.request("POST", "/api/preflight", {"config": config}, {"Cookie": cookie})[0], 400)
        self.server.preflight_runner = lambda candidate: [{"node_id": "management", "check": "ssh", "status": "pass", "code": "ssh_login_ok", "advice": ""}]
        status, _, payload = self.request("POST", "/api/preflight", {"config": config, "fingerprint_risk_acknowledged": True}, {"Cookie": cookie})
        self.assertEqual(status, 200)
        self.assertEqual(payload["results"][0]["node_id"], "management")
        self.assertNotIn("EXAMPLE_ONLY", json.dumps(payload))

    def test_failed_preflight_blocks_generation(self):
        cookie = self.pair()
        config = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        self.server.preflight_runner = lambda candidate: [
            {
                "node_id": "management",
                "check": "ssh",
                "status": "fail",
                "code": "ssh_login_failed",
                "advice": "",
            }
        ]
        self.assertEqual(
            self.request(
                "POST",
                "/api/preflight",
                {"config": config, "fingerprint_risk_acknowledged": True},
                {"Cookie": cookie},
            )[0],
            200,
        )
        self.assertEqual(
            self.request("POST", "/api/generate", {"config": config}, {"Cookie": cookie})[0],
            409,
        )

    def test_deploy_requires_one_time_generation_confirmation(self):
        cookie = self.pair()
        config = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        self.server.preflight_runner = lambda candidate: []
        self.assertEqual(
            self.request(
                "POST",
                "/api/preflight",
                {"config": config, "fingerprint_risk_acknowledged": True},
                {"Cookie": cookie},
            )[0],
            200,
        )
        status, _, generated = self.request("POST", "/api/generate", {"config": config}, {"Cookie": cookie})
        self.assertEqual(status, 200)
        payload = {"generation_id": generated["generation_id"], "confirmation_token": generated["confirmation_token"], "request_id": "test-request-1"}
        self.assertEqual(self.request("POST", "/api/deploy", {**payload, "confirmation_token": "invalid"}, {"Cookie": cookie})[0], 409)
        self.assertEqual(self.request("POST", "/api/deploy", payload, {"Cookie": cookie})[0], 202)
        self.assertEqual(len(self.deploy_calls), 1)
        self.assertEqual(self.deploy_calls[0][2], "redis")
        status, _, retried = self.request("POST", "/api/deploy", payload, {"Cookie": cookie})
        self.assertEqual((status, retried), (202, {"generation_id": generated["generation_id"], "request_id": "test-request-1", "status": "started"}))
        self.assertEqual(len(self.deploy_calls), 1)
        status, _, deployment_status = self.request("GET", "/api/deploy/status", headers={"Cookie": cookie})
        self.assertEqual((status, deployment_status), (200, {"deployment": retried}))
        self.assertFalse(self.server.state.deployment_lock.locked())

    def test_deploy_start_failure_releases_lock_without_persisting_status(self):
        self.server.deploy_runner = lambda *args: (_ for _ in ()).throw(OSError("runner unavailable"))
        cookie = self.pair()
        config = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        self.server.preflight_runner = lambda candidate: []
        self.assertEqual(
            self.request("POST", "/api/preflight", {"config": config, "fingerprint_risk_acknowledged": True}, {"Cookie": cookie})[0],
            200,
        )
        _, _, generated = self.request("POST", "/api/generate", {"config": config}, {"Cookie": cookie})
        response = self.request(
            "POST",
            "/api/deploy",
            {"generation_id": generated["generation_id"], "confirmation_token": generated["confirmation_token"], "request_id": "failure-request"},
            {"Cookie": cookie},
        )
        self.assertEqual(response[0], 500)
        self.assertFalse(self.server.state.deployment_lock.locked())
        self.assertIsNone(self.server.state.deployment)

    def test_deploy_process_exit_updates_only_redacted_lifecycle_status(self):
        class Process:
            def __init__(self):
                self.release = threading.Event()
                self.waiting = threading.Event()

            def wait(self):
                self.waiting.set()
                self.release.wait(timeout=2)
                return 0

        process = Process()
        self.server.deploy_runner = lambda *args: process
        cookie = self.pair()
        config = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        self.server.preflight_runner = lambda candidate: []
        self.assertEqual(
            self.request("POST", "/api/preflight", {"config": config, "fingerprint_risk_acknowledged": True}, {"Cookie": cookie})[0],
            200,
        )
        _, _, generated = self.request("POST", "/api/generate", {"config": config}, {"Cookie": cookie})
        status, _, deployment = self.request(
            "POST",
            "/api/deploy",
            {"generation_id": generated["generation_id"], "confirmation_token": generated["confirmation_token"], "request_id": "lifecycle-request"},
            {"Cookie": cookie},
        )
        self.assertEqual((status, deployment["status"]), (202, "running"))
        self.assertTrue(process.waiting.wait(timeout=1))
        process.release.set()
        self.server.deployment_thread.join(timeout=1)
        status, _, lifecycle = self.request("GET", "/api/deploy/status", headers={"Cookie": cookie})
        self.assertEqual((status, lifecycle["deployment"]["status"], lifecycle["deployment"]["exit_code"]), (200, "succeeded", 0))
        self.assertNotIn(str(self.server.runtime_dir), json.dumps(lifecycle))

    def test_running_deployment_rejects_a_different_request(self):
        class Process:
            def __init__(self):
                self.release = threading.Event()
                self.waiting = threading.Event()

            def wait(self):
                self.waiting.set()
                self.release.wait(timeout=2)
                return 0

        process = Process()
        self.server.deploy_runner = lambda *args: process
        cookie = self.pair()
        config = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        self.server.preflight_runner = lambda candidate: []
        headers = {"Cookie": cookie}
        self.assertEqual(self.request("POST", "/api/preflight", {"config": config, "fingerprint_risk_acknowledged": True}, headers)[0], 200)
        _, _, first = self.request("POST", "/api/generate", {"config": config}, headers)
        self.assertEqual(
            self.request(
                "POST",
                "/api/deploy",
                {"generation_id": first["generation_id"], "confirmation_token": first["confirmation_token"], "request_id": "first-request"},
                headers,
            )[0],
            202,
        )
        self.assertTrue(process.waiting.wait(timeout=1))
        _, _, second = self.request("POST", "/api/generate", {"config": config}, headers)
        status, _, response = self.request(
            "POST",
            "/api/deploy",
            {"generation_id": second["generation_id"], "confirmation_token": second["confirmation_token"], "request_id": "second-request"},
            headers,
        )
        self.assertEqual((status, response), (409, {"error": "a deployment is already running"}))
        self.assertTrue(self.server.state.deployment_lock.locked())
        process.release.set()
        self.server.deployment_thread.join(timeout=1)
        self.assertFalse(self.server.state.deployment_lock.locked())

    def test_shutdown_releases_port_and_clears_state(self):
        cookie = self.pair()
        self.assertEqual(self.request("POST", "/api/shutdown", {}, {"Cookie": cookie})[0], 200)
        self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())
        self.server.server_close()
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", self.port), timeout=0.2)
        self.assertEqual(self.server.state.sessions, {})
        self.assertIsNone(self.server.state.draft)

    def test_static_workbench_covers_v1_fields_without_browser_persistence(self):
        html = (STATIC_DIR / "index.html").read_text(encoding="utf-8")
        script = (STATIC_DIR / "app.js").read_text(encoding="utf-8")
        stylesheet = (STATIC_DIR / "app.css").read_text(encoding="utf-8")
        for section in ("management", "components", "topology", "services", "secrets", "advanced"):
            self.assertIn('data-section="{0}"'.format(section), html)
        for field in (
            "management_ssh_password",
            "database_ssh_password",
            "redis_password",
            "rabbitmq_cookie",
            "mongodb_admin_password",
            "mysql_root_password",
            "keepalived_auth_password",
            "vip",
        ):
            self.assertIn(field, script)
        self.assertIn('autocomplete="new-password"', script)
        self.assertNotIn("localStorage", script)
        self.assertNotIn("sessionStorage", script)
        self.assertNotIn("location.hash", script)
        self.assertNotIn("replaceAll", script)
        self.assertNotIn(".at(", script)
        self.assertIn("restoreSession()", script)
        self.assertIn("if(!result.valid)", script)
        self.assertIn('src="/topology.js"', html)
        self.assertIn("TopologyGenerator.generate", script)
        self.assertIn("manualTopologyPaths", script)
        self.assertIn("data-topology-choice", script)
        self.assertIn("await validateDraft()", script)
        self.assertIn("render('components');scheduleValidation()", script)
        self.assertIn("new AbortController()", script)
        self.assertIn("setTimeout(async()=>", script)
        self.assertIn("data-secret-generate", script)
        self.assertIn("data-secret-visibility", script)
        self.assertIn("data-secret-copy", script)
        self.assertIn("navigator.clipboard.writeText", script)
        self.assertIn("control.type=hidden?'text':'password'", script)
        self.assertIn("dataset.issuePath", script)
        self.assertIn("aria-invalid", script)
        self.assertIn('id="import-file"', html)
        self.assertIn('id="status" role="status" aria-live="polite"', html)
        self.assertIn(":focus-visible", stylesheet)
        self.assertIn("prefers-reduced-motion:reduce", stylesheet)
        self.assertIn("/api/import", script)
        self.assertIn("/api/export", script)
        self.assertIn("confirm(`将替换当前内存草稿", script)
        self.assertIn("ecopilot-config-template.json", script)
        self.assertIn("仅支持 JSON 文件", script)
        self.assertIn("245760", script)
        self.assertIn("/api/deploy/status", script)
        self.assertIn("setInterval", script)
        self.assertIn("部署成功", script)
        self.assertIn("部署失败", script)


if __name__ == "__main__":
    unittest.main()