#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MODE=plan
CONFIG_FILE=
ALLOWLIST_FILE=
EVIDENCE_DIR=
AUTHORIZATION=
EXPECTED_AUTHORIZATION='我确认仅在专用测试环境执行控制面远端回归'

usage() {
  cat <<'EOF'
用法：test_control_plane_remote.sh --config FILE --allowlist FILE --evidence-dir DIR [--execute --authorization TEXT]

默认仅生成计划。真实执行必须同时提供 --execute、逐字授权短语，并满足：
  1. 管理节点 IP 独占一行存在于 allowlist；
  2. 管理节点 /etc/ecopilot-test-environment 内容为 ECOPILOT_E2E_TEST_ONLY；
  3. 配置文件由受信任的新向导生成。
EOF
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --config) [[ "$#" -ge 2 ]] || fail '--config 缺少参数'; CONFIG_FILE=$2; shift ;;
    --allowlist) [[ "$#" -ge 2 ]] || fail '--allowlist 缺少参数'; ALLOWLIST_FILE=$2; shift ;;
    --evidence-dir) [[ "$#" -ge 2 ]] || fail '--evidence-dir 缺少参数'; EVIDENCE_DIR=$2; shift ;;
    --authorization) [[ "$#" -ge 2 ]] || fail '--authorization 缺少参数'; AUTHORIZATION=$2; shift ;;
    --execute) MODE=execute ;;
    --help|-h) usage; exit 0 ;;
    *) fail "未知参数：$1" ;;
  esac
  shift
done

[[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]] || fail '必须提供存在的 --config'
[[ -n "$ALLOWLIST_FILE" && -f "$ALLOWLIST_FILE" ]] || fail '必须提供存在的 --allowlist'
[[ -n "$EVIDENCE_DIR" ]] || fail '必须提供 --evidence-dir'

# 此脚本只接受新向导生成且已由操作者确认可信的 config.env。
# shellcheck disable=SC1090
source "$CONFIG_FILE"
[[ -n "${ANSIBLE_NODE_IP:-}" && -n "${ANSIBLE_NODE_USER:-}" && -n "${ANSIBLE_NODE_PASS:-}" ]] || fail '配置缺少管理节点连接字段'
grep -Fqx "$ANSIBLE_NODE_IP" "$ALLOWLIST_FILE" || fail '管理节点不在 allowlist 中'

mkdir -p "$EVIDENCE_DIR"
chmod 700 "$EVIDENCE_DIR"
PLAN_FILE="$EVIDENCE_DIR/plan.txt"
cat > "$PLAN_FILE" <<EOF
target=${ANSIBLE_NODE_IP}
scenario=01-first-redis: deploy --yes --components redis
scenario=02-add-mongodb: deploy --yes --components mongodb
scenario=03-rerun-redis: deploy --yes --components redis
scenario=04-legacy-gate: run local fail-stop fixture; remote legacy conversion requires a separately approved restore window
snapshot=before and after each remote deployment; hashes and managed structure only
restore=not automatic; use the pre-run VM snapshot and evidence hashes after manual approval
EOF
chmod 600 "$PLAN_FILE"

if [[ "$MODE" == plan ]]; then
  printf 'PLAN_ONLY: %s\n' "$PLAN_FILE"
  exit 0
fi

[[ "$AUTHORIZATION" == "$EXPECTED_AUTHORIZATION" ]] || fail '执行授权短语不匹配'
for tool in ssh sshpass; do command -v "$tool" >/dev/null 2>&1 || fail "缺少工具：$tool"; done

REMOTE="${ANSIBLE_NODE_USER}@${ANSIBLE_NODE_IP}"
ssh_run() {
  SSHPASS="$ANSIBLE_NODE_PASS" sshpass -e ssh \
    -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$REMOTE" "$@"
}

marker=$(ssh_run "sudo -n cat /etc/ecopilot-test-environment" 2>/dev/null || true)
[[ "$marker" == 'ECOPILOT_E2E_TEST_ONLY' ]] || fail '远端测试环境标识缺失或不匹配'

snapshot() {
  local name=$1 destination="$EVIDENCE_DIR/$1.snapshot"
  ssh_run "sudo -n bash -s" > "$destination" <<'REMOTE'
set -euo pipefail
printf 'hosts_sha256='; sudo sha256sum /etc/hosts | awk '{print $1}'
printf 'inventory_sha256='; sudo sha256sum /etc/ansible/hosts | awk '{print $1}'
printf 'hosts_managed_structure\n'
sudo awk '/^# (BEGIN|END) ECOPILOT_COMPONENT / { print }' /etc/hosts
printf 'inventory_managed_structure\n'
sudo awk '/^# (BEGIN|END) ECOPILOT_COMPONENT / || /^\[(redis|rabbitmq|mongodb|mysql|db_all:children)\]$/ { print }' /etc/ansible/hosts
printf 'db_all_children\n'
sudo awk '/^\[db_all:children\]$/ { inside=1; next } /^\[/ { inside=0 } inside && NF { print }' /etc/ansible/hosts
REMOTE
  chmod 600 "$destination"
}

run_scenario() {
  local number=$1 component=$2 log="$EVIDENCE_DIR/$number.log"
  snapshot "$number-before"
  set +e
  DELIVERY_CONFIG_FILE="$CONFIG_FILE" bash "$SCRIPT_DIR/init_ansible.sh" deploy --yes --components "$component" > "$log" 2>&1
  exit_code=$?
  set -e
  chmod 600 "$log"
  printf '%s\n' "$exit_code" > "$EVIDENCE_DIR/$number.exit-code"
  snapshot "$number-after"
  [[ "$exit_code" -eq 0 ]] || fail "场景 $number 失败，退出码 $exit_code"
}

snapshot '00-baseline'
run_scenario '01-first-redis' redis
run_scenario '02-add-mongodb' mongodb
run_scenario '03-rerun-redis' redis
bash "$SCRIPT_DIR/test_control_plane_blocks.sh" > "$EVIDENCE_DIR/04-legacy-gate.log" 2>&1
chmod 600 "$EVIDENCE_DIR/04-legacy-gate.log"
printf 'REMOTE_CONTROL_PLANE_E2E=PASS\n'