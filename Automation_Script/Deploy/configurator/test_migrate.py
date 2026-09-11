import json
from pathlib import Path
import stat
import tempfile
import unittest

from migrate import MigrationError, archive_legacy_bytes, archive_legacy_env, inspect_legacy_env, migrate_json_config, parse_legacy_env_bytes
from render import render_runtime_config
from schema import load_config


ROOT = Path(__file__).resolve().parent


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.config = load_config(ROOT / "examples/config-v1.redis.json")
        self.legacy = render_runtime_config(self.config, Path("/delivery"), Path("/runtime/playbooks")).encode("utf-8")

    def test_generated_legacy_env_is_recognized_without_secrets_in_preview(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.env"
            path.write_bytes(self.legacy)
            result = inspect_legacy_env(path)
        encoded = json.dumps(result, sort_keys=True)
        self.assertEqual(result["migration_status"], "reentry_required")
        self.assertEqual(result["preview"]["components"], ["redis"])
        self.assertNotIn(self.config["secrets"]["management_ssh_password"], encoded)
        self.assertNotIn(self.config["secrets"]["redis_password"], encoded)

    def test_non_utf8_secret_bytes_are_recognized_and_archived_without_previewing_them(self):
        secret = b"\xff\xfe"
        source = self.legacy.replace(b"ANSIBLE_NODE_PASS='manager-pass'", b"ANSIBLE_NODE_PASS='" + secret + b"'", 1)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "config.env"
            path.write_bytes(source)
            result = inspect_legacy_env(path)
            archived = archive_legacy_env(path, root / "runtime")
            archived_bytes = archived.read_bytes()
        self.assertEqual(result["migration_status"], "reentry_required")
        self.assertEqual(archived_bytes, source)
        self.assertNotIn(secret.decode("latin-1"), json.dumps(result, ensure_ascii=False))

    def test_non_utf8_preview_fields_are_rejected(self):
        source = self.legacy.replace(b"ANSIBLE_NODE_IP=", b"ANSIBLE_NODE_IP='\xff'\nANSIBLE_NODE_IP=", 1)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.env"
            path.write_bytes(source)
            with self.assertRaises(MigrationError):
                inspect_legacy_env(path)

    def test_shell_constructs_unknown_names_and_broken_arrays_are_rejected(self):
        attacks = (
            self.legacy + b"EVIL=$(id)\n",
            self.legacy + b"UNKNOWN='value'\n",
            self.legacy.replace(b"REDIS_IPS[0]", b"REDIS_IPS[4]", 1),
            self.legacy.replace(b"DB_IPS=(", b"DB_IPS=(; touch /tmp/x; ", 1),
        )
        for source in attacks:
            with self.subTest(source=source[-50:]):
                with self.assertRaises(MigrationError):
                    parse_legacy_env_bytes(source)

    def test_current_json_is_validated_and_unknown_versions_fail_closed(self):
        self.assertEqual(migrate_json_config(self.config), self.config)
        newer = dict(self.config)
        newer["schema_version"] = 2
        with self.assertRaises(MigrationError):
            migrate_json_config(newer)
        older = dict(self.config)
        older["schema_version"] = 0
        with self.assertRaises(MigrationError):
            migrate_json_config(older)

    def test_archive_is_read_only_deduplicated_and_does_not_change_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "config.env"
            source.write_bytes(self.legacy)
            before = source.read_bytes()
            first = archive_legacy_env(source, root / "runtime")
            second = archive_legacy_env(source, root / "runtime")
            self.assertEqual(first, second)
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(first.read_bytes(), before)
            self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o400)

    def test_unrecognized_legacy_bytes_can_only_be_archived_verbatim(self):
        source = b"\x00not a shell config\n"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "config.env"
            path.write_bytes(source)
            with self.assertRaises(MigrationError):
                inspect_legacy_env(path)
            archived = archive_legacy_bytes(path, root / "runtime")
            self.assertEqual(archived.read_bytes(), source)
            self.assertEqual(stat.S_IMODE(archived.stat().st_mode), 0o400)

    def test_inspection_never_executes_legacy_file(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "executed"
            source = self.legacy + "EVIL=$(touch {0})\n".format(marker).encode("utf-8")
            with self.assertRaises(MigrationError):
                parse_legacy_env_bytes(source)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()