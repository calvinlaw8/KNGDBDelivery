import unittest

from cleanup import build_cleanup_plan


class CleanupPlanTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {
            "schema_version": 1,
            "configuration_sha256": "a" * 64,
            "components": [{
                "name": "redis",
                "resources": [
                    {"id": "redis:host:service:redis-server", "kind": "service", "node": "host", "name": "redis-server"},
                    {"id": "redis:host:file:/etc/redis/redis.conf", "kind": "file", "node": "host", "path": "/etc/redis/redis.conf"},
                    {"id": "redis:host:data_directory:/var/lib/redis", "kind": "data_directory", "node": "host", "path": "/var/lib/redis"},
                    {"id": "redis:host:package:redis-server", "kind": "package", "node": "host", "name": "redis-server"},
                ],
            }],
        }

    def test_plan_only_stops_and_disables_services_and_preserves_other_resources(self):
        reconciliation = {
            "blocked": False,
            "components": [{
                "name": "redis",
                "resources": [
                    {"ownership": "managed"},
                    {"ownership": "managed_missing"},
                    {"ownership": "managed_missing"},
                    {"ownership": "managed"},
                ],
            }],
        }
        plan = build_cleanup_plan(self.manifest, reconciliation, ["redis"])
        self.assertFalse(plan["execute"])
        self.assertEqual(plan["mode"], "dry_run_only")
        self.assertEqual(plan["components"][0]["services"][0]["action"], "stop_disable")
        for category in plan["components"][0]["preserved"].values():
            self.assertTrue(all(item["action"] == "preserve" for item in category))

    def test_blocked_reconciliation_refuses_plan(self):
        reconciliation = {"blocked": True, "components": []}
        with self.assertRaises(ValueError):
            build_cleanup_plan(self.manifest, reconciliation, ["redis"])

    def test_unknown_component_refuses_plan(self):
        reconciliation = {"blocked": False, "components": []}
        with self.assertRaises(ValueError):
            build_cleanup_plan(self.manifest, reconciliation, ["mysql"])


if __name__ == "__main__":
    unittest.main()
