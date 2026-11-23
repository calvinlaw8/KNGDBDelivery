import json
from pathlib import Path
import unittest

try:
    from .redact import redact_sensitive, redacted_summary
    from .schema import CONFIG_SCHEMA, load_config
except ImportError:
    from redact import redact_sensitive, redacted_summary
    from schema import CONFIG_SCHEMA, load_config


class RedactionTests(unittest.TestCase):
    def test_schema_sensitive_nodes_are_removed_without_key_name_matching(self):
        source = Path(__file__).resolve().parent / "examples/config-v1.redis.json"
        config = load_config(source)
        exported = redact_sensitive(config, CONFIG_SCHEMA)
        self.assertNotIn("secrets", exported)
        encoded = json.dumps(exported)
        self.assertNotIn("RedisPass", encoded)
        self.assertEqual(exported["management"], config["management"])

    def test_summary_excludes_secret_values(self):
        source = Path(__file__).resolve().parent / "examples/config-v1.redis.json"
        summary = redacted_summary(load_config(source))
        self.assertEqual(summary["components"], ["redis"])
        self.assertNotIn("secrets", summary)


if __name__ == "__main__":
    unittest.main()