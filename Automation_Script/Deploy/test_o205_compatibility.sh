#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

/bin/bash -n "${SCRIPT_DIR}/verify_delivery.sh"
/bin/bash -n "${SCRIPT_DIR}/install.sh"
/bin/bash -n "${SCRIPT_DIR}/init_ansible.sh"

python3 - "${ROOT}" "${SCRIPT_DIR}/compatibility-manifest.json" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
assert manifest["offline"] is True
assert manifest["python"]["minimum"] == "3.9"
assert any(item["name"] == "macOS" for item in manifest["platforms"])
assert any(item["name"] == "Ubuntu" and item["version"] == "24.04" for item in manifest["platforms"])
assert len(manifest["static_assets"]) == 4
for asset in manifest["static_assets"]:
    path = root / asset["path"]
    assert path.is_file()
PY

cd "${SCRIPT_DIR}"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=configurator python3 -m unittest -q configurator.test_workbench configurator.test_render configurator.test_generations

echo "O-205_OFFLINE_COMPATIBILITY=PASS"
