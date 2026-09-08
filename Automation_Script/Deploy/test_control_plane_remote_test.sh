#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ecopilot-remote-test.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/config.env" <<'EOF'
ANSIBLE_NODE_IP='192.0.2.10'
ANSIBLE_NODE_USER='sysadmin'
ANSIBLE_NODE_PASS='not-a-real-password'
EOF
printf '192.0.2.10\n' > "$WORK_DIR/allowlist"

bash "$SCRIPT_DIR/test_control_plane_remote.sh" \
  --config "$WORK_DIR/config.env" \
  --allowlist "$WORK_DIR/allowlist" \
  --evidence-dir "$WORK_DIR/evidence" > "$WORK_DIR/output"
grep -q '^PLAN_ONLY: ' "$WORK_DIR/output"
grep -q '^scenario=03-rerun-redis:' "$WORK_DIR/evidence/plan.txt"

if bash "$SCRIPT_DIR/test_control_plane_remote.sh" \
  --config "$WORK_DIR/config.env" \
  --allowlist "$WORK_DIR/allowlist" \
  --evidence-dir "$WORK_DIR/refused" \
  --execute --authorization 'wrong phrase' >/dev/null 2>&1; then
  printf 'FAIL: 错误授权短语未被拒绝\n' >&2
  exit 1
fi

printf 'REMOTE_CONTROL_PLANE_HARNESS_TESTS=PASS\n'