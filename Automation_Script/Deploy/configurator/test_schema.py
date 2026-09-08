import json
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path

from schema import CONFIG_SCHEMA, ConfigSchemaError, load_config, write_json_schema


EXAMPLE = Path(__file__).resolve().parent / "examples" / "config-v1.redis.json"


def component_fixtures():
    return {
        "redis": {
            "nodes": [
                {"ip": "192.0.2.21", "hostname": "redis-node1", "role": "master"},
                {"ip": "192.0.2.22", "hostname": "redis-node2", "role": "replica"},
                {"ip": "192.0.2.23", "hostname": "redis-node3", "role": "replica"},
            ],
            "service": {"port": 6379, "sentinel_port": 26379, "sentinel_master_name": "mymaster"},
        },
        "rabbitmq": {
            "nodes": [
                {"ip": "192.0.2.31", "hostname": "rabbitmq-node1", "role": "seed"},
                {"ip": "192.0.2.32", "hostname": "rabbitmq-node2", "role": "member"},
                {"ip": "192.0.2.33", "hostname": "rabbitmq-node3", "role": "member"},
            ],
            "service": {"management_port": 15672, "admin_user": "admin"},
        },
        "mongodb": {
            "nodes": [
                {"ip": "192.0.2.41", "hostname": "mongodb-node1", "role": "primary"},
                {"ip": "192.0.2.42", "hostname": "mongodb-node2", "role": "secondary"},
                {"ip": "192.0.2.43", "hostname": "mongodb-node3", "role": "secondary"},
            ],
            "service": {"port": 27017, "replica_set": "rs0", "admin_user": "admin"},
        },
        "mysql": {
            "nodes": [
                {"ip": "192.0.2.51", "hostname": "mysql-node1", "role": "primary"},
                {"ip": "192.0.2.52", "hostname": "mysql-node2", "role": "replica"},
                {"ip": "192.0.2.53", "hostname": "mysql-node3", "role": "replica"},
            ],
            "service": {
                "port": 3306,
                "replication_user": "repl",
                "vip_verify_user": "ecopilot_vip_verify",
                "vip": "192.0.2.60",
                "vip_prefix": 24,
                "keepalived_interface": "auto",
                "keepalived_router_id": 61,
            },
        },
    }


def config_for(components):
    config = deepcopy(load_config(EXAMPLE))
    config["deployment"]["components"] = list(components)
    fixtures = component_fixtures()
    config["components"] = {name: fixtures[name] for name in components}
    return config


class ConfigSchemaTests(unittest.TestCase):
    def test_valid_example_loads(self) -> None:
        config = load_config(EXAMPLE)
        self.assertEqual(config["deployment"]["components"], ["redis"])

    def test_duplicate_key_is_rejected(self) -> None:
        with self.assertRaises(ConfigSchemaError) as raised:
            load_config('{"schema_version":1,"schema_version":1}')
        self.assertEqual(raised.exception.code, "duplicate_key")

    def test_unknown_version_is_rejected(self) -> None:
        config = load_config(EXAMPLE)
        config["schema_version"] = 2
        with self.assertRaises(ConfigSchemaError) as raised:
            load_config(json.dumps(config))
        self.assertEqual(raised.exception.as_dict()["path"], "/schema_version")
        self.assertEqual(raised.exception.code, "unsupported_version")

    def test_excessive_json_nesting_is_rejected_before_schema_validation(self) -> None:
        nested = []
        for _ in range(33):
            nested = [nested]
        with self.assertRaises(ConfigSchemaError) as raised:
            load_config(json.dumps(nested))
        self.assertEqual(raised.exception.code, "nesting_limit")

    def test_excessive_json_items_are_rejected_before_schema_validation(self) -> None:
        with self.assertRaises(ConfigSchemaError) as raised:
            load_config(json.dumps([0] * 1001))
        self.assertEqual(raised.exception.code, "item_limit")

    def test_unknown_field_is_rejected_with_pointer(self) -> None:
        config = load_config(EXAMPLE)
        config["management"]["unexpected"] = True
        with self.assertRaises(ConfigSchemaError) as raised:
            load_config(json.dumps(config))
        self.assertEqual(raised.exception.as_dict()["path"], "/management/unexpected")
        self.assertEqual(raised.exception.code, "unknown_field")

    def test_missing_required_field_is_rejected(self) -> None:
        config = deepcopy(load_config(EXAMPLE))
        del config["ssh"]["database_user"]
        with self.assertRaises(ConfigSchemaError) as raised:
            load_config(json.dumps(config))
        self.assertEqual(raised.exception.as_dict()["path"], "/ssh/database_user")
        self.assertEqual(raised.exception.code, "missing_required")

    def test_generated_schema_matches_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "config-v1.json"
            write_json_schema(destination)
            self.assertEqual(json.loads(destination.read_text(encoding="utf-8")), CONFIG_SCHEMA)

    def test_each_single_component_and_full_deployment_are_supported(self) -> None:
        component_names = tuple(component_fixtures())
        for component_name in component_names:
            with self.subTest(component=component_name):
                load_config(json.dumps(config_for((component_name,))))
        load_config(json.dumps(config_for(component_names)))


if __name__ == "__main__":
    unittest.main()