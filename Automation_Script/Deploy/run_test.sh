#!/usr/bin/env bash
# 测试专用入口：无人值守重置测试虚拟机并执行固定运行时配置。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESET_DIR="${PROJECT_ROOT}/数据库集群虚拟机重置命令"
RESET_PLAYBOOK="${RESET_DIR}/T-eCopilot.yaml"
RUNTIME_DIR="${SCRIPT_DIR}/.runtime"
CONFIG_FILE="${RUNTIME_DIR}/config.env"
VAULT_PASSWORD_FILE="${VAULT_PASSWORD_FILE:-${RUNTIME_DIR}/vault-password}"

die() {
  printf '错误：%s\n' "$1" >&2
  exit 1
}

command -v ansible-playbook >/dev/null 2>&1 || die "本机缺少 ansible-playbook。请先使用现有初始化流程准备 Ansible。"
[[ -f "${RESET_PLAYBOOK}" ]] || die "找不到加密重置 Playbook：${RESET_PLAYBOOK}"
[[ -f "${CONFIG_FILE}" ]] || die "找不到固定测试配置：${CONFIG_FILE}；无人值守测试不会启动交互式 install.sh。"
vault_args=()
if [[ -f "${VAULT_PASSWORD_FILE}" ]]; then
  [[ -r "${VAULT_PASSWORD_FILE}" ]] || die "Vault 密码文件不可读：${VAULT_PASSWORD_FILE}"
  vault_mode=$(stat -f '%Lp' "${VAULT_PASSWORD_FILE}" 2>/dev/null || stat -c '%a' "${VAULT_PASSWORD_FILE}" 2>/dev/null || true)
  [[ "${vault_mode}" == "600" ]] || die "Vault 密码文件权限必须为 600：${VAULT_PASSWORD_FILE}（当前 ${vault_mode:-未知}）"
  vault_args=(--vault-password-file "${VAULT_PASSWORD_FILE}")
else
  vault_args=(--ask-vault-pass)
fi

post_reset_ssh_gate() {
  local ip label pass user attempt
  local failed=0
  local -a ips=("${ANSIBLE_NODE_IP}" "${DB_IPS[@]}")
  local -a labels=("管理节点" "${DB_HOSTNAMES[@]}")
  local -a users=("${ANSIBLE_NODE_USER}" "${DB_USER}" "${DB_USER}" "${DB_USER}" "${DB_USER}" "${DB_USER}" "${DB_USER}" "${DB_USER}" "${DB_USER}" "${DB_USER}" "${DB_USER}" "${DB_USER}" "${DB_USER}")
  local -a passwords=("${ANSIBLE_NODE_PASS}" "${DB_PASS}" "${DB_PASS}" "${DB_PASS}" "${DB_PASS}" "${DB_PASS}" "${DB_PASS}" "${DB_PASS}" "${DB_PASS}" "${DB_PASS}" "${DB_PASS}" "${DB_PASS}" "${DB_PASS}")

  command -v sshpass >/dev/null 2>&1 || die "重置后 SSH 门禁需要本机 sshpass。"

  printf '\n重置后连接门禁：检查全部节点 IP、TCP/22、SSH 服务和账号登录。\n'
  for i in "${!ips[@]}"; do
    ip="${ips[$i]}"
    label="${labels[$i]}"
    user="${users[$i]}"
    pass="${passwords[$i]}"
    printf '  %-12s %s ...' "${label}" "${ip}"
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      if ! nc -z -w 5 "${ip}" 22 >/dev/null 2>&1; then
        [[ "${attempt}" -lt 10 ]] && { sleep 10; continue; }
        printf ' 网络不可达或 TCP/22 未开放\n'
        failed=1
        break
      fi
      if SSHPASS="${pass}" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o ConnectTimeout=5 \
        "${user}@${ip}" 'hostname' >/dev/null 2>&1; then
        printf ' SSH 服务可用，账号登录成功\n'
        break
      fi
      if [[ "${attempt}" -lt 10 ]]; then
        sleep 10
      else
        printf ' TCP/22 可达但 SSH 账号认证失败\n'
        failed=1
      fi
    done
  done
  [[ "${failed}" -eq 0 ]] || die "重置后连接门禁失败；已停止部署，不将公钥分发结果归因于密码。"
  printf '重置后连接门禁通过：${#ips[@]} 个节点均可达且 SSH 登录成功。\n'
}

printf '\n测试专用自动化部署入口\n'
printf '执行顺序：SSH 指纹风险提示 -> 测试虚拟机快照重置 -> 固定配置部署。\n'
printf '模式：无人值守；不会请求 RESET、Vault 密码、服务器密码或配置录入。\n'
printf '\n警告：重置会覆盖测试虚拟机当前状态。本入口只能用于固定的隔离测试环境。\n'
printf '首次连接目标主机时的 SSH 指纹策略以现有部署脚本为准。\n\n'

cd "${RESET_DIR}"
if [[ "${vault_args[0]}" == "--ask-vault-pass" ]]; then
  printf '开始重置测试虚拟机；本机没有受保护 Vault 文件，将在终端安全询问 Vault 密码。\n'
else
  printf '开始重置测试虚拟机；Vault 密码从受保护文件读取。\n'
fi
ansible-playbook "${vault_args[@]}" "${RESET_PLAYBOOK}"

source "${CONFIG_FILE}"
post_reset_ssh_gate

printf '\n快照恢复完成且连接门禁通过，开始使用固定运行时配置执行完整部署。\n'
DELIVERY_CONFIG_FILE="${CONFIG_FILE}" \
  bash "${SCRIPT_DIR}/init_ansible.sh" deploy