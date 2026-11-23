#!/usr/bin/env python3
"""Generate the JSON Schema document from the authoritative Python model."""

from pathlib import Path

from schema import write_json_schema


if __name__ == "__main__":
    write_json_schema(Path(__file__).resolve().parent / "schema" / "config-v1.json")