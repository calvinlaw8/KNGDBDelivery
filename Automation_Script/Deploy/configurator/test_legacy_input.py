import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from legacy_input import LegacyInputError, config_from_nul_bytes
from validate import validation_result


COMMON = ["192.0.2.10", "ansible-node", "sysadmin", "ssh manager 'password'", "sysadmin", "ssh database password"]
NODES = {
    "redis": ["192.0.2.21", "192.0.2.22", "192.0.2.23", "redis-1", "redis-2", "redis-3", "RedisPass"],
    "rabbitmq": ["192.0.2.31", "192.0.2.32", "192.0.2.33", "rabbitmq-1", "rabbitmq-2", "rabbitmq-3", "CookieValue", "RabbitPass"],
    "mongodb": ["192.0.2.41", "192.0.2.42", "192.0.2.43", "mongodb-1", "mongodb-2", "mongodb-3", "MongoPass"],
    "mysql": [
        "192.0.2.51", "192.0.2.52", "192.0.2.53", "mysql-1", "mysql-2", "mysql-3",
        "192.0.2.60", "24", "MysqlRoot", "MysqlRepl", "MysqlVerify", "Keep123",
    ],
}
ROOT = Path(__file__).resolve().parent


def payload_for(selected):
    fields = [",".join(selected)] + COMMON
    for component in ("redis", "rabbitmq", "mongodb", "mysql"):
        if component in selected:
            fields.extend(NODES[component])
    return ("\0".join(fields) + "\0").encode("utf-8")


class LegacyInputTests(unittest.TestCase):
    def test_all_component_and_single_component_payloads_are_valid(self):
        selections = (("redis", "rabbitmq", "mongodb", "mysql"), ("redis",), ("rabbitmq",), ("mongodb",), ("mysql",))
        for selected in selections:
            with self.subTest(selected=selected):
                config = config_from_nul_bytes(payload_for(selected))
                self.assertEqual(config["deployment"]["components"], list(selected))
                self.assertEqual(validation_result(config), {"valid": True, "issues": []})

    def test_incomplete_and_trailing_payloads_are_rejected(self):
        with self.assertRaises(LegacyInputError):
            config_from_nul_bytes(payload_for(("redis",))[:-20])
        with self.assertRaises(LegacyInputError):
            config_from_nul_bytes(payload_for(("redis",)) + b"extra\0")

    def test_render_wizard_cli_reads_stdin_without_echoing_secrets(self):
        payload = payload_for(("redis",))
        with tempfile.TemporaryDirectory() as parent:
            output = Path(parent) / "staging"
            runtime_playbooks = Path(parent) / "published/playbooks"
            completed = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "configurator",
                    "render-wizard",
                    "--output",
                    str(output),
                    "--project-root",
                    str(Path(parent) / "project"),
                    "--runtime-playbook-dir",
                    str(runtime_playbooks),
                ],
                input=payload,
                check=False,
                capture_output=True,
                cwd=str(ROOT.parent),
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            combined_output = completed.stdout + completed.stderr
            self.assertEqual(completed.returncode, 0, combined_output.decode("utf-8", errors="replace"))
            self.assertTrue((output / "playbooks/group_vars/redis.yml").is_file())
            self.assertIn(str(runtime_playbooks), (output / "config.env").read_text(encoding="utf-8"))
            for secret in (b"ssh manager 'password'", b"ssh database password", b"RedisPass"):
                self.assertNotIn(secret, combined_output)

    def test_validate_wizard_cli_uses_shared_validation_without_echoing_secrets(self):
        payload = payload_for(("redis",))
        completed = subprocess.run(
            [sys.executable, "-m", "configurator", "validate-wizard", "--format", "json"],
            input=payload,
            check=False,
            capture_output=True,
            cwd=str(ROOT.parent),
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        combined_output = completed.stdout + completed.stderr
        self.assertEqual(completed.returncode, 0, combined_output.decode("utf-8", errors="replace"))
        self.assertIn(b'"valid": true', completed.stdout)
        for secret in (b"ssh manager 'password'", b"ssh database password", b"RedisPass"):
            self.assertNotIn(secret, combined_output)

    def test_validate_wizard_rejects_shared_semantic_errors_without_echoing_secrets(self):
        fields = ["redis"] + COMMON + list(NODES["redis"])
        fields[8] = fields[7]
        payload = ("\0".join(fields) + "\0").encode("utf-8")
        completed = subprocess.run(
            [sys.executable, "-m", "configurator", "validate-wizard", "--format", "json"],
            input=payload,
            check=False,
            capture_output=True,
            cwd=str(ROOT.parent),
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        combined_output = completed.stdout + completed.stderr
        self.assertEqual(completed.returncode, 2)
        self.assertIn(b'"valid": false', completed.stdout)
        self.assertIn(b"duplicate_ip", completed.stdout)
        for secret in (b"ssh manager 'password'", b"ssh database password", b"RedisPass"):
            self.assertNotIn(secret, combined_output)

    def test_doctor_reports_machine_readable_prerequisites(self):
        completed = subprocess.run(
            [sys.executable, "-m", "configurator", "doctor", "--format", "json"],
            check=False,
            capture_output=True,
            cwd=str(ROOT.parent),
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", errors="replace"))
        result = __import__("json").loads(completed.stdout)
        self.assertTrue(result["valid"])
        self.assertEqual(result["minimum_python"], "3.9")


if __name__ == "__main__":
    unittest.main()