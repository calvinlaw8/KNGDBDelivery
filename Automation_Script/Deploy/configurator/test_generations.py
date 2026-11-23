import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

from generations import GenerationError, new_utc_generation_id, publish_staging, read_current, remove_unreferenced_generation, resolve_current


GENERATION_ONE = "20260907T120000Z-0123456789abcdef"
GENERATION_TWO = "20260907T120001Z-fedcba9876543210"


class GenerationTests(unittest.TestCase):
    def test_new_generation_id_uses_utc_aware_clock(self):
        fixed = __import__("datetime").datetime(2026, 9, 8, 1, 2, 3, tzinfo=__import__("datetime").timezone.utc)
        with patch("generations.datetime") as mock_datetime:
            mock_datetime.now.return_value = fixed
            self.assertRegex(new_utc_generation_id(), r"^20260908T010203Z-[0-9a-f]{16}$")
            mock_datetime.now.assert_called_once_with(__import__("datetime").timezone.utc)

    def make_staging(self, parent: Path, name: str, marker: str) -> Path:
        staging = parent / name
        staging.mkdir(mode=0o700)
        (staging / "config.env").write_text(marker, encoding="utf-8")
        (staging / "configuration.sha256").write_text("0" * 64 + "\n", encoding="ascii")
        (staging / "deployment-plan.json").write_text("{}\n", encoding="utf-8")
        (staging / "deployment-summary.txt").write_text("summary\n", encoding="utf-8")
        (staging / "managed-resources.json").write_text("{}\n", encoding="utf-8")
        playbooks = staging / "playbooks"
        playbooks.mkdir(mode=0o700)
        (playbooks / "site.yml").write_text("---\n", encoding="utf-8")
        for path in staging.rglob("*"):
            os.chmod(str(path), 0o700 if path.is_dir() else 0o600)
        return staging

    def test_publish_switches_pointer_and_preserves_fixed_resolution(self):
        with tempfile.TemporaryDirectory() as parent_name:
            parent = Path(parent_name)
            runtime = parent / ".runtime"
            first = publish_staging(runtime, self.make_staging(parent, "first", "one"), GENERATION_ONE)
            fixed = resolve_current(runtime)
            self.assertEqual(fixed, first)
            (runtime / "logs/deploy.log").write_text("log\n", encoding="utf-8")
            (runtime / "state/redis.deploy.verified").write_text("state\n", encoding="utf-8")
            second = publish_staging(runtime, self.make_staging(parent, "second", "two"), GENERATION_TWO)
            self.assertEqual(resolve_current(runtime), second)
            self.assertEqual((fixed / "secrets/config.env").read_text(encoding="utf-8"), "one")
            self.assertTrue((fixed / "config/deployment-plan.json").is_file())
            self.assertTrue((fixed / "config/managed-resources.json").is_file())
            self.assertFalse((fixed / "managed-resources.json").exists())
            self.assertTrue((fixed / "secrets/playbooks/site.yml").is_file())
            self.assertEqual((runtime / "logs/deploy.log").read_text(encoding="utf-8"), "log\n")
            self.assertEqual((runtime / "state/redis.deploy.verified").read_text(encoding="utf-8"), "state\n")
            self.assertEqual(stat.S_IMODE((runtime / "current").stat().st_mode), 0o600)
            self.assertTrue((runtime / "logs").is_dir())
            self.assertTrue((runtime / "state").is_dir())

    def test_failed_publish_keeps_current_and_staging(self):
        with tempfile.TemporaryDirectory() as parent_name:
            parent = Path(parent_name)
            runtime = parent / ".runtime"
            publish_staging(runtime, self.make_staging(parent, "first", "one"), GENERATION_ONE)
            staging = self.make_staging(parent, "second", "two")
            with self.assertRaises(GenerationError):
                publish_staging(runtime, staging, GENERATION_ONE)
            self.assertEqual(read_current(runtime), GENERATION_ONE)
            self.assertTrue(staging.is_dir())
            self.assertTrue((staging / "config.env").is_file())
            self.assertFalse((staging / "config").exists())

    def test_cleanup_refuses_current_and_checkpoint_references(self):
        with tempfile.TemporaryDirectory() as parent_name:
            parent = Path(parent_name)
            runtime = parent / ".runtime"
            publish_staging(runtime, self.make_staging(parent, "first", "one"), GENERATION_ONE)
            publish_staging(runtime, self.make_staging(parent, "second", "two"), GENERATION_TWO)
            with self.assertRaises(GenerationError):
                remove_unreferenced_generation(runtime, GENERATION_TWO)
            checkpoint = runtime / "state/deploy.state"
            checkpoint.write_text("generation_id={0}\n".format(GENERATION_ONE), encoding="utf-8")
            with self.assertRaises(GenerationError):
                remove_unreferenced_generation(runtime, GENERATION_ONE)
            checkpoint.unlink()
            remove_unreferenced_generation(runtime, GENERATION_ONE)
            self.assertFalse((runtime / "generations" / GENERATION_ONE).exists())


if __name__ == "__main__":
    unittest.main()