#!/usr/bin/env bash
# Read-only runtime security audit. Never prints or reads secret values.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/.runtime"
MODE="audit"
REPORT="${RUNTIME_DIR}/audit/security.json"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --self-test) MODE="self-test"; shift ;;
    --output)
      [[ "$#" -ge 2 ]] || { printf 'FAIL: --output 缺少报告路径\n' >&2; exit 2; }
      REPORT="$2"
      shift 2
      ;;
    *) printf 'FAIL: 未知参数：%s\n' "$1" >&2; exit 2 ;;
  esac
done

failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

check_mode() {
  local mode="$1"
  [[ "${mode}" =~ ^(audit|self-test)$ ]]
}

check_git_tracking() {
  local tracked staged unignored
  tracked=$(git -C "${DELIVERY_ROOT}" ls-files -- ':(glob)**/.runtime/**' ':(glob)**/config.env')
  staged=$(git -C "${DELIVERY_ROOT}" diff --cached --name-only -- ':(glob)**/.runtime/**' ':(glob)**/config.env')
  unignored=$(git -C "${DELIVERY_ROOT}" ls-files --others --exclude-standard -- ':(glob)**/.runtime/**' ':(glob)**/config.env')
  [[ -z "${tracked}" ]] || fail "runtime_git_tracked"
  [[ -z "${staged}" ]] || fail "runtime_git_staged"
  [[ -z "${unignored}" ]] || fail "runtime_git_unignored"
}

check_runtime_permissions() {
  [[ -d "${RUNTIME_DIR}" ]] || return 0
  local mode path
  mode=$(stat -f '%Lp' "${RUNTIME_DIR}" 2>/dev/null || stat -c '%a' "${RUNTIME_DIR}" 2>/dev/null || printf 'unknown')
  [[ "${mode}" == "700" ]] || fail "runtime_directory_permission"
  while IFS= read -r -d '' path; do
    if [[ "${path}" == */secrets/* || "${path}" == */credentials.txt ]]; then
      mode=$(stat -f '%Lp' "${path}" 2>/dev/null || stat -c '%a' "${path}" 2>/dev/null || printf 'unknown')
      [[ "${mode}" == "600" ]] || fail "runtime_sensitive_file_permission"
    fi
  done < <(find "${RUNTIME_DIR}" -type f -print0)
}

check_source_boundaries() {
  if grep -RInE '(\b(password|secret|cookie|token)\b.*(argv|process\.argv|sys\.argv)|localStorage.*(password|secret|cookie|token)|\?(password|secret|cookie|token)=)' \
    "${SCRIPT_DIR}" --include='*.py' --include='*.js' --include='*.sh' \
    --exclude='audit_runtime.sh' >/dev/null 2>&1; then
    fail "source_secret_boundary_violation"
  fi
  if grep -RInE 'rm[[:space:]]+-rf([[:space:]]|$)' \
    "${SCRIPT_DIR}" --include='*.sh' --include='*.py' >/dev/null 2>&1; then
    warn_pattern='rm_rf_directive'
  fi
}

self_test_canary() {
  local canary="ECOPILOT-CANARY-$(date +%s)-$$"
  local test_root report_dir scan process_args outside_hits=0
  test_root=$(mktemp -d "${TMPDIR:-/tmp}/ecopilot-audit.XXXXXX")
  chmod 700 "${test_root}"
  report_dir=$(dirname "${REPORT}")
  mkdir -p "${report_dir}"
  chmod 700 "${report_dir}"

  local allowed="${test_root}/.runtime/generations/test/secrets/config.env"
  mkdir -p "$(dirname "${allowed}")"
  chmod 700 "$(dirname "${allowed}")"
  printf 'canary=%s\n' "${canary}" > "${allowed}"
  chmod 600 "${allowed}"

  printf 'canary=%s\n' "${canary}" > "${test_root}/ordinary.log"
  printf 'http://127.0.0.1:12345/?token=%s\n' "${canary}" > "${test_root}/browser-url.txt"
  process_args=$(ps -ax -o args= 2>/dev/null || true)
  if [[ "${process_args}" == *"${canary}"* ]]; then
    fail "canary_process_argument"
  fi

  while IFS= read -r -d '' scan; do
    if grep -Fq "${canary}" "${scan}" 2>/dev/null; then
      case "${scan}" in
        "${allowed}") ;;
        *) outside_hits=$((outside_hits + 1)) ;;
      esac
    fi
  done < <(find "${test_root}" -type f -print0)

  [[ "${outside_hits}" -eq 2 ]] || fail "canary_allowlist_probe_failed"

  if [[ -e "${test_root}/ordinary.log" && -e "${test_root}/browser-url.txt" ]]; then
    :
  fi

  rm -rf -- "${test_root}"
  [[ ! -e "${test_root}" ]] || fail "abnormal_exit_temp_residue"

  local report_tmp="${REPORT}.tmp.$$"
  printf '{"audit":"o204","mode":"self-test","violations":%d}\n' "${failures}" > "${report_tmp}"
  chmod 600 "${report_tmp}"
  mv "${report_tmp}" "${REPORT}"
  chmod 600 "${REPORT}"
}

check_mode "${MODE}" || fail "invalid_mode"
check_git_tracking
check_runtime_permissions
check_source_boundaries

if [[ "${MODE}" == "self-test" ]]; then
  self_test_canary
  if ((failures == 0)); then
    printf 'RESULT: PASS（运行时安全自检通过；canary 未进入进程参数或非允许落盘位置）\n'
  else
    printf 'RESULT: FAILED（运行时安全自检发现 %d 类问题）\n' "${failures}" >&2
    exit 1
  fi
else
  report_tmp="${REPORT}.tmp.$$"
  mkdir -p "$(dirname "${REPORT}")"
  chmod 700 "$(dirname "${REPORT}")"
  printf '{"audit":"o204","mode":"audit","violations":%d}\n' "${failures}" > "${report_tmp}"
  chmod 600 "${report_tmp}"
  mv "${report_tmp}" "${REPORT}"
  chmod 600 "${REPORT}"
  if ((failures > 0)); then
    printf 'RESULT: FAILED（运行时安全审计发现 %d 类问题）\n' "${failures}" >&2
    exit 1
  fi
  printf 'RESULT: PASS（只读运行时安全审计通过）\n'
fi
