import shutil
import unittest
from unittest.mock import patch

from preflight import TOTAL_TIMEOUT_SECONDS, run_preflight
from test_schema import config_for


class Completed:
    returncode = 0


class PreflightTests(unittest.TestCase):
    def test_checks_are_bounded_and_secrets_never_enter_argv_or_results(self):
        config = config_for(("redis",))
        commands = []

        def runner(arguments, environment, timeout):
            commands.append((arguments, environment, timeout))
            return Completed()

        with patch.object(shutil, "which", side_effect=lambda tool: "/opt/homebrew/bin/{0}".format(tool)):
            results = run_preflight(config, runner=runner, tcp_connect=lambda *_: None)
        arguments = str([item[0] for item in commands])
        environments = [item[1] for item in commands]
        self.assertNotIn(config["secrets"]["management_ssh_password"], arguments)
        self.assertNotIn(config["secrets"]["database_ssh_password"], arguments)
        self.assertTrue(all(environment.keys() == {"PATH", "SSHPASS"} for environment in environments))
        self.assertNotIn(config["secrets"]["database_ssh_password"], str(results))
        self.assertTrue(all(command[2] <= 12 for command in commands))
        self.assertGreater(TOTAL_TIMEOUT_SECONDS, 0)
        self.assertTrue(all(command[0][:3] == ["/opt/homebrew/bin/sshpass", "-e", "/opt/homebrew/bin/ssh"] for command in commands))
        self.assertTrue(all("PreferredAuthentications=password" in command[0] for command in commands))
        self.assertTrue(all("PubkeyAuthentication=no" in command[0] for command in commands))
        self.assertEqual({item["check"] for item in results}, {"dependencies", "tcp_22", "ssh", "sudo", "platform", "ports"})

    def test_unreachable_node_stops_remote_checks_for_that_node(self):
        config = config_for(("redis",))
        calls = []

        with patch.object(shutil, "which", return_value="/usr/bin/tool"):
            results = run_preflight(config, runner=lambda *_: calls.append(True), tcp_connect=lambda *_: (_ for _ in ()).throw(OSError()))
        self.assertEqual(calls, [])
        self.assertTrue(all(item["check"] in ("dependencies", "tcp_22") for item in results))

    def test_ssh_login_failures_are_classified_without_client_output(self):
        config = config_for(("redis",))

        def runner(arguments, environment, timeout):
            return type("Result", (), {"returncode": 5 if arguments[-1] == "true" else 0})()

        with patch.object(shutil, "which", return_value="/usr/bin/tool"):
            results = run_preflight(config, runner=runner, tcp_connect=lambda *_: None)
        failures = [item for item in results if item["check"] == "ssh"]
        self.assertTrue(failures)
        self.assertTrue(all(item["code"] == "ssh_authentication_rejected" for item in failures))
        self.assertNotIn(config["secrets"]["database_ssh_password"], str(failures))

    def test_occupied_component_port_is_warned_without_remote_output(self):
        config = config_for(("redis",))

        def runner(arguments, environment, timeout):
            return type("Result", (), {"returncode": 0 if "ss -ltn" in arguments[-1] else 0})()

        with patch.object(shutil, "which", return_value="/usr/bin/tool"):
            results = run_preflight(config, runner=runner, tcp_connect=lambda *_: None)
        ports = [item for item in results if item["check"] == "ports"]
        self.assertTrue(ports)
        self.assertTrue(all(item["status"] == "warning" for item in ports))
        self.assertTrue(all(item["code"] == "ports_occupied" for item in ports))
        self.assertNotIn("EXAMPLE_ONLY", str(results))

    def test_port_check_execution_failure_is_not_reported_as_available(self):
        config = config_for(("redis",))

        def runner(arguments, environment, timeout):
            return type("Result", (), {"returncode": 2 if "ss -ltn" in arguments[-1] else 0})()

        with patch.object(shutil, "which", return_value="/usr/bin/tool"):
            results = run_preflight(config, runner=runner, tcp_connect=lambda *_: None)
        ports = [item for item in results if item["check"] == "ports"]
        self.assertTrue(ports)
        self.assertTrue(all(item["status"] == "warning" for item in ports))
        self.assertTrue(all(item["code"] == "ports_check_failed" for item in ports))

    def test_sudo_password_bootstraps_temporary_nopasswd_access(self):
        config = config_for(("redis",))
        calls = []
        sudo_attempts = 0

        def runner(arguments, environment, timeout, input_text=None):
            nonlocal sudo_attempts
            command = arguments[-1]
            calls.append((arguments, environment, timeout, input_text))
            if command == "sudo -k && sudo -n true":
                sudo_attempts += 1
                return type("Result", (), {"returncode": 1 if sudo_attempts == 1 else 0})()
            return type("Result", (), {"returncode": 0})()

        with patch.object(shutil, "which", return_value="/usr/bin/tool"):
            results = run_preflight(config, runner=runner, tcp_connect=lambda *_: None)
        sudo_result = next(item for item in results if item["check"] == "sudo")
        self.assertEqual(sudo_result["status"], "pass")
        self.assertEqual(sudo_result["code"], "sudo_ok")
        bootstrap = next(call for call in calls if "visudo -cf" in call[0][-1])
        self.assertEqual(bootstrap[3], config["secrets"]["management_ssh_password"] + "\n" + "sysadmin ALL=(ALL) NOPASSWD: ALL\n")
        self.assertNotIn(config["secrets"]["management_ssh_password"], str(bootstrap[0]))


if __name__ == "__main__":
    unittest.main()