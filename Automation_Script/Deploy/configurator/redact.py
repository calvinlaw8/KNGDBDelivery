"""Schema-driven redaction for configuration previews and exports."""

from typing import Any, Dict, Mapping


def redact_sensitive(value: Any, rule: Mapping[str, Any]) -> Any:
    """Return a copy of value with every schema-marked sensitive node removed."""
    if rule.get("x-sensitive"):
        return None
    if isinstance(value, dict):
        properties = rule.get("properties", {})
        return {key: redact_sensitive(item, properties[key]) for key, item in value.items() if key in properties and not properties[key].get("x-sensitive")}
    if isinstance(value, list):
        item_rule = rule.get("items", {})
        return [redact_sensitive(item, item_rule) for item in value]
    return value


def redacted_summary(config: Mapping[str, Any]) -> Dict[str, Any]:
    """Build a non-sensitive import summary suitable for display."""
    return {
        "schema_version": config["schema_version"],
        "components": list(config["deployment"]["components"]),
        "management": dict(config["management"]),
    }