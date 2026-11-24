import unittest

from rebuild import build_rebuild_plan


class RebuildPlanTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {
            "schema_version": 1,
            "configuration_sha256": "a" * 64,
            "components": [{
                "name": "redis",
                "resources": [
                    {"id": "redis:host:data_directory:/var/lib/redis", "kind": "data_directory", "node": "host", "path": "/var/lib/redis"},
                ],
            }],
        }
        self.reconciliation = {
            "blocked": False,
            "components": [{"name": "redis", "resources": [{"ownership": "managed"}]}],
        }
        self.backup = {
            "change_id": "CHG-001",
            "backup_time": "2026-11-24T10:00:00+08:00",
            "snapshot_id": "SNAP-001",
            "restoration_verified": True,
        }

    def test_builds_one_component_quarantine_only_plan(self):
        plan = build_rebuild_plan(self.manifest, self.reconciliation, "redis", self.backup)
        self.assertFalse(plan["execute"])
        self.assertEqual(plan["component"], "redis")
        self.assertEqual(plan["confirmation_phrase"], "REBUILD-REDIS-DATA")
        self.assertEqual(plan["data_directories"][0]["action"], "quarantine_only")
        self.assertIn("purge_quarantine_requires_separate_confirmation", plan["steps"])

    def test_rejects_missing_or_unverified_backup(self):
        with self.assertRaises(ValueError):
            build_rebuild_plan(self.manifest, self.reconciliation, "redis", {})
        unverified = dict(self.backup, restoration_verified=False)
        with self.assertRaises(ValueError):
            build_rebuild_plan(self.manifest, self.reconciliation, "redis", unverified)

    def test_rejects_multi_or_unknown_component(self):
        with self.assertRaises(ValueError):
            build_rebuild_plan(self.manifest, self.reconciliation, "redis,mongodb", self.backup)
        with self.assertRaises(ValueError):
            build_rebuild_plan(self.manifest, self.reconciliation, "unknown", self.backup)

    def test_rejects_blocked_ownership(self):
        reconciliation = {"blocked": True, "components": []}
        with self.assertRaises(ValueError):
            build_rebuild_plan(self.manifest, reconciliation, "redis", self.backup)


if __name__ == "__main__":
    unittest.main()
