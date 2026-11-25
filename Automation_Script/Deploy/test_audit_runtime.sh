#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ecopilot-o204-test.XXXXXX")
trap 'rm -rf -- "${TMP_DIR}"' EXIT

/bin/bash -n "${SCRIPT_DIR}/audit_runtime.sh"

REPORT="${TMP_DIR}/audit.json"
"${SCRIPT_DIR}/audit_runtime.sh" --self-test --output "${REPORT}"
/bin/bash -n "${SCRIPT_DIR}/audit_runtime.sh"

if [[ "$(stat -f '%Lp' "${REPORT}" 2>/dev/null || stat -c '%a' "${REPORT}")" != "600" ]]; then
  echo "FAIL: O-204 report permissions" >&2
  exit 1
fi
grep -q '"violations":0' "${REPORT}"
grep -RIn 'ECOPILOT-CANARY-' "${REPORT}" >/dev/null 2>&1 && {
  echo "FAIL: O-204 report contains canary" >&2
  exit 1
}

echo "O-204_RUNTIME_AUDIT=PASS"
