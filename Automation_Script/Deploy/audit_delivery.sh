#!/usr/bin/env bash
# 本地只读审计：不连接远端、不读取运行时配置、不执行部署。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLAYBOOK_ROOT="${SCRIPT_DIR}/playbooks"

failures=0
warnings=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

check_shell_syntax() {
  local script
  while IFS= read -r -d '' script; do
    /bin/bash -n "${script}" || fail "Shell 语法检查失败：${script}"
  done < <(find "${DELIVERY_ROOT}/Automation_Script" -type f -name '*.sh' -print0)
}

check_yaml_syntax() {
  command -v ansible-playbook >/dev/null 2>&1 || {
    warn "当前环境没有 ansible-playbook，跳过 Playbook 语法检查"
    return
  }

  local playbook
  for playbook in \
    "${PLAYBOOK_ROOT}/preflights/00_preflight.yml" \
    "${PLAYBOOK_ROOT}/preflights/01_server_init.yml" \
    "${PLAYBOOK_ROOT}/preflights/02_postflight.yml" \
    "${PLAYBOOK_ROOT}/site/site.yml"; do
    [[ -f "${playbook}" ]] || { fail "缺少 Playbook 入口：${playbook}"; continue; }
    ansible-playbook --syntax-check -i 'localhost,' "${playbook}" >/dev/null 2>&1 ||
      fail "Ansible 语法检查失败：${playbook}"
  done
}

check_expected_layout() {
  local path
  for path in \
    "${SCRIPT_DIR}/init_ansible.sh" \
    "${SCRIPT_DIR}/run_test.sh" \
    "${SCRIPT_DIR}/verify_delivery.sh" \
    "${SCRIPT_DIR}/validate_deb_payloads.sh" \
    "${PLAYBOOK_ROOT}/group_vars/all.yml" \
    "${PLAYBOOK_ROOT}/site/site.yml"; do
    [[ -f "${path}" ]] || fail "缺少预期交付文件：${path}"
  done
}

check_secret_placeholders() {
  local file
  while IFS= read -r -d '' file; do
    if grep -nE '(^|[[:space:]])(password|passwd|secret|cookie|token):[[:space:]]*[^#[:space:]]+' "${file}" |
      grep -vE 'CHANGE_ME|<[^>]+>|\{\{.*\}\}' >/dev/null 2>&1; then
      fail "Playbook/group_vars 疑似包含非占位符敏感值：${file}"
    fi
  done < <(find "${PLAYBOOK_ROOT}" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
}

check_forbidden_destructive_patterns() {
  local matches
  matches=$(grep -RInE 'rm[[:space:]]+-rf[[:space:]].*(mnesia|rabbitmq|mongodb|mysql)|rm[[:space:]]+-f[[:space:]].*\.lock' \
    "${SCRIPT_DIR}" "${PLAYBOOK_ROOT}" 2>/dev/null || true)
  [[ -z "${matches}" ]] || fail "部署路径包含未经隔离授权的破坏性清理：${matches}"
}

check_sudo_stdin_split() {
  grep -q 'sudo -n bash -s' "${SCRIPT_DIR}/init_ansible.sh" ||
    fail "未找到免密 sudo 的独立 stdin 路径"
  grep -q "sudo -S -p '' bash -s" "${SCRIPT_DIR}/init_ansible.sh" ||
    fail "未找到需密码 sudo 的独立 stdin 路径"
  grep -q 'sudo -n true' "${SCRIPT_DIR}/init_ansible.sh" ||
    fail "未找到 sudo 能力探测"
}

check_runtime_config_isolation() {
  local runtime_dir="${SCRIPT_DIR}/.runtime"
  [[ ! -e "${runtime_dir}/config.env" ]] ||
    warn "检测到本机运行时配置；审计不会读取或输出其内容"
  grep -RInE '\.runtime/config\.env|source .*config\.env' \
    "${SCRIPT_DIR}" --exclude='audit_delivery.sh' --exclude='config.env' >/dev/null 2>&1 ||
    warn "未在部署脚本中找到运行时配置加载路径，请人工确认配置入口"
}

check_runtime_git_isolation() {
  local tracked staged unignored
  tracked=$(git -C "${DELIVERY_ROOT}" ls-files -- ':(glob)**/.runtime/**' ':(glob)**/config.env')
  [[ -z "${tracked}" ]] || fail "Git 索引包含运行时或现场配置文件"
  staged=$(git -C "${DELIVERY_ROOT}" diff --cached --name-only -- ':(glob)**/.runtime/**' ':(glob)**/config.env')
  [[ -z "${staged}" ]] || fail "Git 暂存区包含运行时或现场配置文件"
  unignored=$(git -C "${DELIVERY_ROOT}" ls-files --others --exclude-standard -- ':(glob)**/.runtime/**' ':(glob)**/config.env')
  [[ -z "${unignored}" ]] || fail "未忽略的工作树包含运行时或现场配置文件"
}

check_expected_layout
check_shell_syntax
check_yaml_syntax
check_secret_placeholders
check_forbidden_destructive_patterns
check_sudo_stdin_split
check_runtime_config_isolation
check_runtime_git_isolation

if ((failures > 0)); then
  printf 'RESULT: FAILED（%d 个问题，%d 个警告）\n' "${failures}" "${warnings}" >&2
  exit 1
fi

printf 'RESULT: PASS（只读交付审计通过；%d 个警告）\n' "${warnings}"