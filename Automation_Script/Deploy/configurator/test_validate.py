import json
import subprocess
import sys
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path

from schema import load_config
from test_schema import EXAMPLE, config_for
from validate import validation_result


ROOT = Path(__file__).resolve().parent


class SemanticValidationTests(unittest.TestCase):
    def valid_config(self):
        config = config_for(("redis", "rabbitmq", "mongodb", "mysql"))
        config["secrets"].update(
            {
                "rabbitmq_cookie": "EXAMPLE_ONLY",
                "rabbitmq_admin_password": "EXAMPLE_ONLY",
                "mongodb_admin_password": "EXAMPLE_ONLY",
                "mysql_root_password": "EXAMPLE_ONLY",
                "mysql_replication_password": "EXAMPLE_ONLY",
                "mysql_vip_verify_password": "EXAMPLE_ONLY",
                "keepalived_auth_password": "Abc123_-",
            }
        )
        return config

    def test_valid_full_config_has_no_issues(self):
        self.assertEqual(validation_result(self.valid_config()), {"valid": True, "issues": []})

    def test_selected_component_and_secret_are_required(self):
        config = deepcopy(load_config(EXAMPLE))
        del config["components"]["redis"]
        del config["secrets"]["redis_password"]
        result = validation_result(config)
        self.assertEqual(
            [(item["code"], item["path"]) for item in result["issues"]],
            [
                ("missing_selected_component", "/components/redis"),
                ("missing_component_secret", "/secrets/redis_password"),
            ],
        )

    def test_format_role_duplicate_and_vip_errors_are_stably_sorted(self):
        config = self.valid_config()
        config["management"]["ip"] = "999.1.1.1"
        config["ssh"]["database_user"] = "INVALID USER"
        config["components"]["redis"]["nodes"][0]["role"] = "replica"
        config["components"]["mongodb"]["nodes"][0]["ip"] = config["components"]["redis"]["nodes"][0]["ip"]
        config["components"]["mysql"]["service"]["vip"] = config["components"]["mysql"]["nodes"][0]["ip"]
        issues = validation_result(config)["issues"]
        self.assertEqual(issues, sorted(issues, key=lambda item: (item["path"], item["code"], item["severity"], item["message"])))
        self.assertEqual(
            {item["code"] for item in issues},
            {"invalid_ipv4", "invalid_linux_username", "invalid_role_count", "duplicate_ip", "vip_conflict"},
        )

    def test_unselected_component_is_warning_only(self):
        config = self.valid_config()
        config["deployment"]["components"] = ["redis"]
        result = validation_result(config)
        self.assertTrue(result["valid"])
        self.assertEqual({item["code"] for item in result["issues"]}, {"unselected_component"})

    def test_keepalived_password_uses_existing_cli_constraint(self):
        config = self.valid_config()
        config["secrets"]["keepalived_auth_password"] = "too-long!"
        issues = validation_result(config)["issues"]
        self.assertEqual(
            [(item["code"], item["path"]) for item in issues],
            [("invalid_keepalived_auth", "/secrets/keepalived_auth_password")],
        )

    def test_existing_hostname_and_component_secret_constraints_are_preserved(self):
        config = self.valid_config()
        config["management"]["hostname"] = "ansible_node"
        config["secrets"]["redis_password"] = "not allowed!"
        issues = validation_result(config)["issues"]
        self.assertEqual(
            [(item["code"], item["path"]) for item in issues],
            [("invalid_component_secret", "/secrets/redis_password")],
        )

    def test_vip_outside_mysql_prefix_is_warning(self):
        config = self.valid_config()
        config["components"]["mysql"]["service"]["vip"] = "198.51.100.60"
        result = validation_result(config)
        self.assertTrue(result["valid"])
        self.assertEqual(
            [(item["code"], item["severity"]) for item in result["issues"]],
            [("vip_subnet_unconfirmed", "warning")],
        )

    def test_structural_error_uses_same_result_protocol(self):
        config = self.valid_config()
        del config["management"]["ip"]
        result = validation_result(config)
        self.assertFalse(result["valid"])
        self.assertEqual(
            [(item["code"], item["path"], item["severity"]) for item in result["issues"]],
            [("missing_required", "/management/ip", "error")],
        )

    def test_cli_json_matches_library_result(self):
        config = self.valid_config()
        config["components"]["mysql"]["service"]["vip_prefix"] = 0
        expected = validation_result(config)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(config), encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, "-m", "configurator", "validate", str(path), "--format", "json"],
                cwd=str(ROOT.parent),
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(json.loads(completed.stdout), expected)

    def test_cli_stdin_does_not_echo_secret_value(self):
        config = self.valid_config()
        secret = "DO_NOT_ECHO!"
        config["secrets"]["redis_password"] = secret
        completed = subprocess.run(
            [sys.executable, "-m", "configurator", "validate", "--format", "json"],
            cwd=str(ROOT.parent),
            check=False,
            capture_output=True,
            text=True,
            input=json.dumps(config),
        )
        self.assertEqual(completed.returncode, 2)
        self.assertNotIn(secret, completed.stdout)
        self.assertEqual(json.loads(completed.stdout)["issues"][0]["code"], "invalid_component_secret")


if __name__ == "__main__":
    unittest.main()