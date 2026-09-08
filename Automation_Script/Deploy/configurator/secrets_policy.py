"""Compatible server-side secret generation policies."""

import secrets
from typing import Dict


COMPATIBLE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:@+=,-"

SECRET_LENGTHS: Dict[str, int] = {
    "management_ssh_password": 24,
    "database_ssh_password": 24,
    "redis_password": 24,
    "rabbitmq_cookie": 24,
    "rabbitmq_admin_password": 24,
    "mongodb_admin_password": 24,
    "mysql_root_password": 24,
    "mysql_replication_password": 24,
    "mysql_vip_verify_password": 24,
    "keepalived_auth_password": 8,
}


def generate_secret(name: str) -> str:
    """Generate a compatible secret for a known configuration secret field."""
    if name not in SECRET_LENGTHS:
        raise ValueError("unknown secret field")
    return "".join(secrets.choice(COMPATIBLE_ALPHABET) for _ in range(SECRET_LENGTHS[name]))