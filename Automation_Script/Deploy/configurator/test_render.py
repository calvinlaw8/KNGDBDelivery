import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from render import RenderError, render_files, write_staging_directory
from test_schema import config_for


ROOT = Path(__file__).resolve().parent
TEMPLATES = ROOT.parent / "playbooks" / "group_vars"


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.config = config_for(("redis", "rabbitmq", "mongodb", "mysql"))
        self.config["secrets"].update(
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

    def test_render_is_deterministic_and_redacts_summary(self):
        project_root = Path("/opt/ecopilot delivery")
        runtime_dir = project_root / ".runtime/playbooks"
        first = render_files(self.config, project_root, runtime_dir, TEMPLATES)
        second = render_files(self.config, project_root, runtime_dir, TEMPLATES)
        self.assertEqual(first, second)
        for secret in self.config["secrets"].values():
            self.assertNotIn(secret, first["deployment-summary.txt"])
            self.assertNotIn(secret, first["deployment-plan.json"])
        plan = json.loads(first["deployment-plan.json"])
        self.assertEqual(len(plan["configuration_sha256"]), 64)
        self.assertEqual([item["name"] for item in plan["components"]], ["redis", "rabbitmq", "mongodb", "mysql"])

    def test_managed_resources_declaration_is_complete_and_secret_free(self):
        files = render_files(self.config, Path("/opt/ecopilot"), Path("/opt/ecopilot/.runtime/playbooks"), TEMPLATES)
        manifest = json.loads(files["managed-resources.json"])
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["configuration_sha256"], files["configuration.sha256"].strip())
        self.assertEqual([component["name"] for component in manifest["components"]], ["redis", "rabbitmq", "mongodb", "mysql"])
        for component in manifest["components"]:
            self.assertEqual(component["ownership"], "planned_new")
            self.assertTrue(component["nodes"])
            self.assertTrue(component["resources"])
            for resource in component["resources"]:
                self.assertIn(resource["kind"], ("file", "service", "data_directory", "package"))
                self.assertTrue(resource["id"])
                self.assertTrue(resource["recovery_prerequisite"])
        manifest_text = files["managed-resources.json"]
        for secret in self.config["secrets"].values():
            self.assertNotIn(secret, manifest_text)

    def test_runtime_config_is_compatible_with_bash_32(self):
        self.config["secrets"]["management_ssh_password"] = "a password with 'quote'"
        files = render_files(self.config, Path("/tmp/project root"), Path("/tmp/runtime playbooks"), TEMPLATES)
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.env"
            config_path.write_text(files["config.env"], encoding="utf-8")
            completed = subprocess.run(
                ["/bin/bash", "-c", 'source "$1" && printf "%s\\n%s\\n" "$ANSIBLE_NODE_PASS" "${#DB_IPS[@]}"', "bash", str(config_path)],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stdout, "a password with 'quote'\n12\n")

    def test_rabbitmq_only_runtime_config_does_not_expand_unselected_arrays(self):
        config = config_for(("rabbitmq",))
        config["secrets"].update(
            {
                "rabbitmq_cookie": "EXAMPLE_ONLY",
                "rabbitmq_admin_password": "EXAMPLE_ONLY",
            }
        )
        files = render_files(config, Path("/tmp/project"), Path("/tmp/runtime"), TEMPLATES)
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.env"
            config_path.write_text(files["config.env"], encoding="utf-8")
            completed = subprocess.run(
                ["/bin/bash", "-c", 'set -u; source "$1"; printf "%s\\n" "${#DB_IPS[@]}"', "bash", str(config_path)],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "3\n")

    def test_group_vars_use_json_values_and_explicit_roles(self):
        files = render_files(self.config, Path("/tmp/project"), Path("/tmp/runtime"), TEMPLATES)
        self.assertIn('redis_replicas: [\n  "192.0.2.22",', files["playbooks/group_vars/redis.yml"])
        self.assertIn('mysql_nodes: [', files["playbooks/group_vars/mysql.yml"])
        self.assertIn('"role": "primary"', files["playbooks/group_vars/mysql.yml"])
        self.assertNotIn('redis_password: "CHANGE_ME"', files["playbooks/group_vars/redis.yml"])

    def test_invalid_config_is_not_rendered(self):
        self.config["components"]["mysql"]["service"]["vip_prefix"] = 0
        with self.assertRaises(RenderError):
            render_files(self.config, Path("/tmp/project"), Path("/tmp/runtime"), TEMPLATES)

    def test_full_and_single_component_staging_permissions(self):
        for selected in (("redis", "rabbitmq", "mongodb", "mysql"), ("redis",), ("rabbitmq",), ("mongodb",), ("mysql",)):
            with self.subTest(selected=selected), tempfile.TemporaryDirectory() as parent:
                config = config_for(selected)
                required_secrets = {
                    "rabbitmq": {"rabbitmq_cookie": "EXAMPLE_ONLY", "rabbitmq_admin_password": "EXAMPLE_ONLY"},
                    "mongodb": {"mongodb_admin_password": "EXAMPLE_ONLY"},
                    "mysql": {
                        "mysql_root_password": "EXAMPLE_ONLY",
                        "mysql_replication_password": "EXAMPLE_ONLY",
                        "mysql_vip_verify_password": "EXAMPLE_ONLY",
                        "keepalived_auth_password": "Abc123_-",
                    },
                }
                for component in selected:
                    config["secrets"].update(required_secrets.get(component, {}))
                destination = Path(parent) / "staging"
                files = render_files(config, Path(parent) / "project", destination / "playbooks", TEMPLATES)
                write_staging_directory(destination, files)
                self.assertEqual(os.stat(str(destination)).st_mode & 0o777, 0o700)
                for relative_name in files:
                    self.assertEqual(os.stat(str(destination / relative_name)).st_mode & 0o777, 0o600)
                self.assertNotIn("CHANGE_ME", "".join(files["playbooks/group_vars/{0}.yml".format(name)] for name in selected))

    def test_render_cli_writes_new_staging_directory(self):
        with tempfile.TemporaryDirectory() as parent:
            config_path = Path(parent) / "config.json"
            output = Path(parent) / "output"
            config_path.write_text(json.dumps(self.config), encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, "-m", "configurator", "render", str(config_path), "--output", str(output), "--project-root", "/opt/ecopilot"],
                cwd=str(ROOT.parent),
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(json.loads(completed.stdout)["output"], str(output))
            self.assertTrue((output / "deployment-plan.json").is_file())
            repeated = subprocess.run(
                [sys.executable, "-m", "configurator", "render", str(config_path), "--output", str(output), "--project-root", "/opt/ecopilot"],
                cwd=str(ROOT.parent),
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(repeated.returncode, 2)

    @unittest.skipUnless(shutil.which("ansible-playbook"), "ansible-playbook is not installed")
    def test_rendered_group_vars_pass_ansible_syntax_check(self):
        with tempfile.TemporaryDirectory() as parent:
            destination = Path(parent) / "staging"
            playbooks = destination / "playbooks"
            files = render_files(self.config, Path(parent) / "project", playbooks, TEMPLATES)
            write_staging_directory(destination, files)
            shutil.copytree(str(ROOT.parent / "playbooks/preflights"), str(playbooks / "preflights"))
            shutil.copytree(str(ROOT.parent / "playbooks/site"), str(playbooks / "site"))
            inventory = Path(parent) / "inventory"
            inventory.write_text("[db_all]\nlocalhost ansible_connection=local\n", encoding="utf-8")
            completed = subprocess.run(
                [shutil.which("ansible-playbook"), "-i", str(inventory), str(playbooks / "site/site.yml"), "--syntax-check"],
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "ANSIBLE_LOCAL_TEMP": str(Path(parent) / "ansible-tmp")},
            )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)


if __name__ == "__main__":
    unittest.main()