"""Tests for server-side secret generation policies."""

import unittest

try:
    from .secrets_policy import COMPATIBLE_ALPHABET, SECRET_LENGTHS, generate_secret
except ImportError:
    from secrets_policy import COMPATIBLE_ALPHABET, SECRET_LENGTHS, generate_secret


class SecretPolicyTests(unittest.TestCase):
    def test_all_known_fields_return_compatible_required_lengths(self):
        for name, expected_length in SECRET_LENGTHS.items():
            value = generate_secret(name)
            self.assertEqual(len(value), expected_length)
            self.assertTrue(set(value).issubset(set(COMPATIBLE_ALPHABET)))

    def test_keepalived_generation_stays_within_protocol_limit(self):
        self.assertEqual(len(generate_secret("keepalived_auth_password")), 8)

    def test_unknown_field_is_rejected(self):
        with self.assertRaises(ValueError):
            generate_secret("/secrets/anything")


if __name__ == "__main__":
    unittest.main()