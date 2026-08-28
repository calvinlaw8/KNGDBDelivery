#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PACKAGE_ROOT="${PACKAGE_ROOT:-${DELIVERY_ROOT}/离线安装包}"

failures=0

target_package() {
  case "$1" in
    redis) echo "redis-server" ;;
    rabbitmq) echo "rabbitmq-server" ;;
    mongodb) echo "mongodb-org-server" ;;
    mysql) echo "mysql-community-server" ;;
    *) return 1 ;;
  esac
}

target_version() {
  case "$1" in
    redis) echo "8.2.8" ;;
    rabbitmq) echo "4.2.9" ;;
    mongodb) echo "8.2.12" ;;
    mysql) echo "8.4.11" ;;
    *) return 1 ;;
  esac
}

matches_target_version() {
  local package_version="$1"
  local expected_version="$2"
  local upstream_version="${package_version#*:}"

  [[ "${upstream_version}" == "${expected_version}" ||
     "${upstream_version}" == "${expected_version}-"* ]]
}

failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

command -v dpkg-deb >/dev/null 2>&1 || {
  echo 'FAIL: dpkg-deb 未安装；请在 Ubuntu 24.04 准备环境执行此校验器' >&2
  exit 2
}

[[ -d "${PACKAGE_ROOT}" ]] || {
  echo "FAIL: 正式离线包目录不存在：${PACKAGE_ROOT}" >&2
  exit 2
}

for component in redis rabbitmq mongodb mysql; do
  expected_package=$(target_package "${component}")
  expected_version=$(target_version "${component}")
  component_dir="${PACKAGE_ROOT}/${component}"
  [[ -d "${component_dir}" ]] || {
    fail "${component}: 目录不存在：${component_dir}"
    continue
  }

  deb_files=()
  while IFS= read -r -d '' package_file; do
    deb_files+=("${package_file}")
  done < <(find "${component_dir}" -maxdepth 1 -type f -print0 | sort -z)

  if ((${#deb_files[@]} == 0)); then
    fail "${component}: 未找到正式 .deb 载荷（目标 ${expected_package} ${expected_version}）"
    continue
  fi

  while IFS= read -r -d '' non_deb_file; do
    fail "${component}: 存在非 .deb 文件：${non_deb_file}"
  done < <(find "${component_dir}" -maxdepth 1 -type f ! -name '*.deb' -print0)

  package_found=0
  for package_file in "${deb_files[@]}"; do
    package_name=$(dpkg-deb -f "${package_file}" Package 2>/dev/null || true)
    package_version=$(dpkg-deb -f "${package_file}" Version 2>/dev/null || true)
    package_arch=$(dpkg-deb -f "${package_file}" Architecture 2>/dev/null || true)

    [[ -n "${package_name}" && -n "${package_version}" && -n "${package_arch}" ]] || {
      fail "${component}: 无法读取包元数据：${package_file}"
      continue
    }

    [[ "${package_arch}" == amd64 || "${package_arch}" == all ]] ||
      fail "${component}: 非 amd64/all 包：${package_file}（${package_arch}）"

    if [[ "${package_name}" == "${expected_package}" ]] &&
       matches_target_version "${package_version}" "${expected_version}"; then
      package_found=1
    fi

    printf 'INFO: %s | %s | %s | %s\n' "${component}" "${package_name}" "${package_version}" "${package_arch}"
  done

  ((package_found == 1)) ||
    fail "${component}: 未找到目标主包 ${expected_package}（上游版本 ${expected_version}）"
done

if ((failures > 0)); then
  printf 'RESULT: FAILED (%d 个问题)\n' "${failures}" >&2
  exit 1
fi

echo 'RESULT: PASS（主包、扩展名和 amd64/all 元数据检查通过）'