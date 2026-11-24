import json
import unittest

from ownership import reconcile_manifest, reconcile_resource


class OwnershipTests(unittest.TestCase):
    def test_unknown_and_conflicting_facts_block(self):
        resource = {"id": "redis:host:data_directory:/var/lib/redis", "kind": "data_directory", "node": "host"}
        unknown = reconcile_resource(resource, {"status": "unknown"})
        conflict = reconcile_resource(resource, {"status": "nonempty"})
        self.assertEqual(unknown["ownership"], "unknown")
        self.assertEqual(conflict["ownership"], "external_conflict")

    def test_reconciliation_is_secret_free_and_reports_conflicts(self):
        manifest = {
            "schema_version": 1,
            "configuration_sha256": "a" * 64,
            "components": [{
                "name": "redis",
                "nodes": [],
                "resources": [
                    {"id": "redis:host:package:redis-server", "kind": "package", "name": "redis-server", "version": "8.2.8", "node": "host"},
                    {"id": "redis:host:data_directory:/var/lib/redis", "kind": "data_directory", "path": "/var/lib/redis", "node": "host"},
                ],
            }],
        }
        facts = {
            "host": [
                {"id": "redis:host:package:redis-server", "status": "installed", "version": "8.2.8"},
                {"id": "redis:host:data_directory:/var/lib/redis", "status": "nonempty"},
            ]
        }
        report = reconcile_manifest(manifest, facts)
        self.assertTrue(report["blocked"])
        self.assertEqual(report["conflicts"], ["redis:host:data_directory:/var/lib/redis"])
        self.assertNotIn("password", json.dumps(report))


if __name__ == "__main__":
    unittest.main()
