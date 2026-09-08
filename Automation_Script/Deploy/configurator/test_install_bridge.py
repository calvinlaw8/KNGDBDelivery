import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
DEPLOY_DIR = ROOT.parent
INSTALL = DEPLOY_DIR / "install.sh"


class InstallBridgeTests(unittest.TestCase):
    def test_install_function_renders_complete_runtime(self):
        script = r'''
source "$2"
PROJECT_ROOT="$1/project"
RUNTIME_DIR="$1/.runtime"
SELECTED_COMPONENTS=(redis rabbitmq mongodb mysql)
ANSIBLE_NODE_IP=192.0.2.10
ANSIBLE_NODE_HOSTNAME=ansible-node
ANSIBLE_NODE_USER=sysadmin
ANSIBLE_NODE_PASS="manager ssh password"
DB_USER=sysadmin
DB_PASS="database ssh password"
REDIS_IPS=(192.0.2.21 192.0.2.22 192.0.2.23)
REDIS_HOSTNAMES=(redis-1 redis-2 redis-3)
RABBITMQ_IPS=(192.0.2.31 192.0.2.32 192.0.2.33)
RABBITMQ_HOSTNAMES=(rabbitmq-1 rabbitmq-2 rabbitmq-3)
MONGODB_IPS=(192.0.2.41 192.0.2.42 192.0.2.43)
MONGODB_HOSTNAMES=(mongodb-1 mongodb-2 mongodb-3)
MYSQL_IPS=(192.0.2.51 192.0.2.52 192.0.2.53)
MYSQL_HOSTNAMES=(mysql-1 mysql-2 mysql-3)
redis_password=RedisPass
rabbitmq_cookie=CookieValue
rabbitmq_admin_password=RabbitPass
mongodb_admin_password=MongoPass
mysql_vip=192.0.2.60
mysql_vip_prefix=24
mysql_root_password=MysqlRoot
mysql_repl_password=MysqlRepl
mysql_vip_verify_password=MysqlVerify
keepalived_auth_pass=Keep123
render_wizard_configuration
printf 'summary\n' > "${PENDING_STAGING_DIR}/install-summary.txt"
publish_wizard_generation
'''
        with tempfile.TemporaryDirectory() as parent:
            completed = subprocess.run(
                ["/bin/bash", "-c", script, "test-install-bridge", parent, str(INSTALL)],
                cwd=str(DEPLOY_DIR.parent.parent),
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            runtime = Path(parent) / ".runtime"
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            generation_id = (runtime / "current").read_text(encoding="ascii").strip()
            generation = runtime / "generations" / generation_id
            source_check = subprocess.run(
                ["/bin/bash", "-c", 'set -u; source "$1"; [[ "${DEPLOY_COMPONENTS}" == "redis,rabbitmq,mongodb,mysql" ]]', "source-check", str(generation / "secrets/config.env")],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(source_check.returncode, 0, source_check.stdout + source_check.stderr)
            self.assertEqual(stat.S_IMODE(runtime.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((runtime / "current").stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE((generation / "secrets/config.env").stat().st_mode), 0o600)
            self.assertEqual((generation / "config/install-summary.txt").read_text(encoding="utf-8"), "summary\n")
            self.assertFalse((generation / "secrets/credentials.txt").exists())
            selected_text = "".join(
                (generation / "secrets/playbooks/group_vars/{0}.yml".format(name)).read_text(encoding="utf-8")
                for name in ("redis", "rabbitmq", "mongodb", "mysql")
            )
            self.assertNotIn("CHANGE_ME", selected_text)
            if shutil.which("ansible-playbook"):
                inventory = Path(parent) / "inventory"
                inventory.write_text("[db_all]\nlocalhost ansible_connection=local\n", encoding="utf-8")
                syntax_check = subprocess.run(
                    [shutil.which("ansible-playbook"), "-i", str(inventory), str(generation / "secrets/playbooks/site/site.yml"), "--syntax-check"],
                    check=False,
                    capture_output=True,
                    text=True,
                    env={**os.environ, "ANSIBLE_LOCAL_TEMP": str(Path(parent) / "ansible-tmp")},
                )
                self.assertEqual(syntax_check.returncode, 0, syntax_check.stdout + syntax_check.stderr)

    def test_invalid_input_preserves_existing_runtime(self):
        script = r'''
source "$2"
PROJECT_ROOT="$1/project"
RUNTIME_DIR="$1/.runtime"
mkdir -p "${RUNTIME_DIR}"
printf 'existing-generation\n' > "${RUNTIME_DIR}/current"
SELECTED_COMPONENTS=(redis)
ANSIBLE_NODE_IP=192.0.2.10
ANSIBLE_NODE_HOSTNAME=ansible-node
ANSIBLE_NODE_USER=sysadmin
ANSIBLE_NODE_PASS="manager ssh password"
DB_USER=sysadmin
DB_PASS="database ssh password"
REDIS_IPS=(192.0.2.21 192.0.2.22 192.0.2.23)
REDIS_HOSTNAMES=(redis-1 redis-2 redis-3)
redis_password=
render_wizard_configuration
'''
        with tempfile.TemporaryDirectory() as parent:
            completed = subprocess.run(
                ["/bin/bash", "-c", script, "test-install-bridge", parent, str(INSTALL)],
                cwd=str(DEPLOY_DIR.parent.parent),
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            runtime = Path(parent) / ".runtime"
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual((runtime / "current").read_text(encoding="utf-8"), "existing-generation\n")
            self.assertEqual(list(runtime.glob(".staging-*")), [])

    def test_explicit_credentials_export_is_private_and_opt_in(self):
        script = r'''
source "$2"
PROJECT_ROOT="$1/project"
RUNTIME_DIR="$1/.runtime"
PENDING_STAGING_DIR="$1/staging"
mkdir -p "${PENDING_STAGING_DIR}"
SELECTED_COMPONENTS=(redis)
ANSIBLE_NODE_PASS="manager ssh password"
DB_PASS="database ssh password"
redis_password=RedisPass
INSTALL_EXPORT_CREDENTIALS=1
INSTALL_EXPORT_CREDENTIALS_CONFIRM=EXPORT
maybe_export_credentials_file
'''
        with tempfile.TemporaryDirectory() as parent:
            completed = subprocess.run(
                ["/bin/bash", "-c", script, "test-install-bridge", parent, str(INSTALL)],
                cwd=str(DEPLOY_DIR.parent.parent),
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            exported = Path(parent) / "staging" / "credentials.txt"
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertTrue(exported.exists())
            self.assertEqual(stat.S_IMODE(exported.stat().st_mode), 0o600)
            self.assertFalse(list(exported.parent.glob(".credentials.txt.*")))

    def test_legacy_gate_archives_without_exposing_secrets_or_changing_source(self):
        script = r'''
source "$2"
PROJECT_ROOT="$1/project"
RUNTIME_DIR="$1/.runtime"
mkdir -p "${RUNTIME_DIR}"
cp "$3" "${RUNTIME_DIR}/config.env"
show_legacy_config_gate
'''
        legacy = ROOT / "examples" / "config-v1.redis.json"
        with tempfile.TemporaryDirectory() as parent:
            rendered = subprocess.run(
                ["/usr/bin/python3", "-c", "from pathlib import Path; from schema import load_config; from render import render_runtime_config; print(render_runtime_config(load_config(Path(__import__('sys').argv[1])), Path('/delivery'), Path('/runtime/playbooks')), end='')", str(legacy)],
                cwd=str(ROOT),
                check=True,
                capture_output=True,
                text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            source = Path(parent) / "legacy.env"
            source.write_text(rendered.stdout, encoding="utf-8")
            before = source.read_bytes()
            completed = subprocess.run(
                ["/bin/bash", "-c", script, "test-legacy-gate", parent, str(INSTALL), str(source)],
                cwd=str(DEPLOY_DIR.parent.parent),
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            runtime = Path(parent) / ".runtime"
            backups = list((runtime / "legacy-backups").glob("*.config.env"))
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual((runtime / "config.env").read_bytes(), before)
            self.assertEqual(len(backups), 1)
            self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o400)
            self.assertIn('"migration_status": "reentry_required"', completed.stdout)
            self.assertNotIn("RedisPass", completed.stdout + completed.stderr)


if __name__ == "__main__":
    unittest.main()