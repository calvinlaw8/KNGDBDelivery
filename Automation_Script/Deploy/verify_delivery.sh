#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PACKAGE_ROOT="${DELIVERY_ROOT}/离线安装包"
MANIFEST="${DELIVERY_ROOT}/sha256-packages.txt"
CONFIGURED_MODE=0
CONFIG_FILE="${DELIVERY_CONFIG_FILE:-${DELIVERY_ROOT}/Automation_Script/Deploy/config.env}"

if [[ "${1:-}" == "--configured" ]]; then
  CONFIGURED_MODE=1
fi

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

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

check_required_paths() {
  local path
  for path in \
    "${PACKAGE_ROOT}" \
    "${MANIFEST}" \
    "${DELIVERY_ROOT}/Automation_Script/Deploy/init_ansible.sh" \
    "${DELIVERY_ROOT}/Automation_Script/Deploy/validate_deb_payloads.sh" \
    "${DELIVERY_ROOT}/Automation_Script/Deploy/playbooks"; do
    [[ -e "${path}" ]] || fail "缺少交付资产：${path}"
  done
}

check_lfs_and_hashes() {
  local manifest_hash manifest_path actual_hash package_file extra_field
  while read -r manifest_hash manifest_path; do
    [[ -n "${manifest_hash}" && -n "${manifest_path}" ]] || continue
    package_file="${DELIVERY_ROOT}/${manifest_path}"
    [[ -f "${package_file}" ]] || {
      fail "SHA256 清单中的文件不存在：${manifest_path}"
      continue
    }
    if head -n 1 "${package_file}" | grep -q '^version https://git-lfs.github.com/spec/v1$'; then
      fail "LFS 文件尚未还原为真实载荷：${manifest_path}"
      continue
    fi
    actual_hash=$(sha256_file "${package_file}" || true)
    [[ "${actual_hash}" == "${manifest_hash}" ]] ||
      fail "SHA256 不匹配：${manifest_path}"
  done < "${MANIFEST}"
}

check_manifest_layout() {
  local line manifest_hash manifest_path actual_path extra_field
  local manifest_paths actual_paths
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    manifest_hash=${line%%[[:space:]]*}
    manifest_path=${line#${manifest_hash}}
    manifest_path=$(printf '%s\n' "${manifest_path}" | sed 's/^[[:space:]]*//')
    if [[ ! "${manifest_hash}" =~ ^[[:xdigit:]]{64}$ ]]; then
      fail "SHA256 清单哈希格式非法：${line}"
      continue
    fi
    if [[ "${manifest_path}" != 离线安装包/*/*.deb ||
          "${manifest_path}" == /* ||
          "${manifest_path}" == *../* ||
          "${manifest_path}" == */../* ||
          "${manifest_path}" == *$'\n'* ]]; then
      fail "SHA256 清单路径不安全或不是正式 .deb：${manifest_path}"
    fi
  done < "${MANIFEST}"

  manifest_paths=$(awk 'NF >= 2 {print $2}' "${MANIFEST}" | sort)

  actual_paths=$(find "${PACKAGE_ROOT}" -type f -print | while IFS= read -r actual_path; do
    actual_path=${actual_path#${DELIVERY_ROOT}/}
    printf '%s\n' "${actual_path}"
  done | sort)

  if [[ "${manifest_paths}" != "${actual_paths}" ]]; then
    fail "SHA256 清单与实际载荷文件集合不一致（拒绝缺失或额外载荷）"
    comm -23 <(printf '%s\n' "${manifest_paths}") <(printf '%s\n' "${actual_paths}") |
      while IFS= read -r manifest_path; do
        [[ -n "${manifest_path}" ]] && printf 'FAIL: 清单声明但载荷缺失：%s\n' "${manifest_path}" >&2
      done
    comm -13 <(printf '%s\n' "${manifest_paths}") <(printf '%s\n' "${actual_paths}") |
      while IFS= read -r actual_path; do
        [[ -n "${actual_path}" ]] && printf 'FAIL: 载荷存在但不在清单：%s\n' "${actual_path}" >&2
      done
  fi

  if [[ "${manifest_paths}" != "$(printf '%s\n' "${manifest_paths}" | uniq -u)" ]]; then
    fail "SHA256 清单包含重复路径"
  fi
}

check_payload_layout() {
  local component file
  for component in redis rabbitmq mongodb mysql; do
    local component_dir="${PACKAGE_ROOT}/${component}"
    [[ -d "${component_dir}" ]] || {
      fail "缺少正式载荷目录：${component_dir}"
      continue
    }
    while IFS= read -r -d '' file; do
      [[ "${file}" == *.deb ]] || fail "载荷目录存在非 .deb 文件：${file}"
    done < <(find "${component_dir}" -maxdepth 1 -type f -print0)
    while IFS= read -r -d '' file; do
      fail "载荷目录存在嵌套目录：${file}"
    done < <(find "${component_dir}" -mindepth 1 -type d -print0)
    while IFS= read -r -d '' file; do
      fail "载荷目录存在零字节 .deb：${file}"
    done < <(find "${component_dir}" -maxdepth 1 -type f -name '*.deb' -size 0 -print0)
  done
}

check_deb_metadata() {
  command -v dpkg-deb >/dev/null 2>&1 || {
    warn "当前环境没有 dpkg-deb，跳过 .deb 元数据检查；请在 Ubuntu 24.04 amd64 准备环境复核"
    return
  }
  local component package_file package_name package_version package_arch
  for component in redis rabbitmq mongodb mysql; do
    while IFS= read -r -d '' package_file; do
      package_name=$(dpkg-deb -f "${package_file}" Package 2>/dev/null || true)
      package_version=$(dpkg-deb -f "${package_file}" Version 2>/dev/null || true)
      package_arch=$(dpkg-deb -f "${package_file}" Architecture 2>/dev/null || true)
      [[ -n "${package_name}" && -n "${package_version}" && -n "${package_arch}" ]] ||
        fail "无法读取 .deb 元数据：${package_file}"
      [[ "${package_arch}" == amd64 || "${package_arch}" == all ]] ||
        fail "非 amd64/all 包：${package_file}（${package_arch}）"
    done < <(find "${PACKAGE_ROOT}/${component}" -maxdepth 1 -type f -name '*.deb' -print0)
  done
}

check_static_files() {
  local script
  while IFS= read -r -d '' script; do
    /bin/bash -n "${script}" || fail "Shell 语法检查失败：${script}"
  done < <(find "${DELIVERY_ROOT}/Automation_Script" -type f -name '*.sh' -print0)
  if ((CONFIGURED_MODE == 1)) && grep -n -h 'CHANGE_ME' \
    "${CONFIG_FILE}" >/dev/null 2>&1; then
    fail "实际部署配置中仍存在 CHANGE_ME 占位符"
  fi
}

check_required_paths
if ((failures == 0)); then
  check_manifest_layout
fi
if ((failures == 0)); then
  check_lfs_and_hashes
  check_payload_layout
  check_deb_metadata
  check_static_files
fi

if ((failures > 0)); then
  printf 'RESULT: FAILED（%d 个问题，%d 个警告）\n' "${failures}" "${warnings}" >&2
  exit 1
fi

printf 'RESULT: PASS（SHA256、LFS、载荷布局和静态检查通过；%d 个警告）\n' "${warnings}"