#!/usr/bin/env bash
# 交付五一键部署向导：生成本机运行时配置后调用现有 Ansible 入口。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/.runtime"
RUNTIME_PLAYBOOK_DIR="${RUNTIME_DIR}/playbooks"
CONFIG_FILE="${RUNTIME_DIR}/config.env"
CREDENTIALS_FILE="${RUNTIME_DIR}/credentials.txt"
SUMMARY_FILE="${RUNTIME_DIR}/install-summary.txt"

info() { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m⚠ %s\033[0m\n' "$*"; }
die() { printf '\033[0;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " answer
    ANSWER="${answer:-${default}}"
  else
    read -r -p "${prompt}: " answer
    [[ -n "${answer}" ]] || die "该项不能为空：${prompt}"
    ANSWER="${answer}"
  fi
}

ask_secret() {
  local prompt="$1" answer confirm
  while true; do
    read -r -s -p "${prompt}: " answer; printf '\n'
    [[ -n "${answer}" ]] || { warn "该项不能为空"; continue; }
    read -r -s -p "再次输入确认: " confirm; printf '\n'
    if [[ "${answer}" == "${confirm}" ]]; then
      ANSWER="${answer}"
      return
    fi
    warn "两次输入不一致，请重试"
  done
}

ask_node_group() {
  local label="$1" prefix="$2" i
  local ip hostname
  for i in 1 2 3; do
    ask "${label} 节点${i} IP"; ip="${ANSWER}"
    ask "${label} 节点${i} 主机名"; hostname="${ANSWER}"
    case "${prefix}" in
      REDIS) REDIS_IPS[$((i - 1))]="${ip}"; REDIS_HOSTNAMES[$((i - 1))]="${hostname}" ;;
      RABBITMQ) RABBITMQ_IPS[$((i - 1))]="${ip}"; RABBITMQ_HOSTNAMES[$((i - 1))]="${hostname}" ;;
      MONGODB) MONGODB_IPS[$((i - 1))]="${ip}"; MONGODB_HOSTNAMES[$((i - 1))]="${hostname}" ;;
      MYSQL) MYSQL_IPS[$((i - 1))]="${ip}"; MYSQL_HOSTNAMES[$((i - 1))]="${hostname}" ;;
      *) die "未知节点组：${prefix}" ;;
    esac
  done
}

yaml_scalar() {
  local file="$1" key="$2" value="$3"
  awk -v key="${key}" -v value="${value}" '
    $0 ~ "^[[:space:]]*" key ":" {
      prefix=$0; sub(key ":.*$", "", prefix)
      gsub(/\\/, "\\\\", value); gsub(/"/, "\\\"", value)
      print prefix key ": \"" value "\""; next
    }
    { print }
  ' "${file}" > "${file}.tmp"
  mv "${file}.tmp" "${file}"
}

yaml_block() {
  local file="$1" start_key="$2" block="$3"
  local replacement="${block//$'\n'/|}"
  awk -v key="${start_key}" -v replacement="${replacement}" '
    BEGIN { line_count=split(replacement, lines, "|"); replacing=0 }
    $0 ~ "^[[:space:]]*" key ":" { for (i=1; i<=line_count; i++) print lines[i]; replacing=1; next }
    replacing && ($0 ~ /^[^[:space:]]/ || $0 == "") { replacing=0 }
    !replacing { print }
  ' "${file}" > "${file}.tmp"
  mv "${file}.tmp" "${file}"
}

shell_quote() { printf '%q' "$1"; }

write_runtime_config() {
  local i
  {
    printf '# 本机生成的运行时配置，禁止提交 Git。\n'
    printf 'PROJECT_ROOT=%q\n' "${PROJECT_ROOT}"
    printf 'PKG_ROOT=%q\nLOCAL_DB_PKG_DIR=%q\n' "${PROJECT_ROOT}/Automation_Script/Deploy/pkg" "${PROJECT_ROOT}/离线安装包"
    printf 'ANSIBLE_NODE_IP=%q\nANSIBLE_NODE_USER=%q\nANSIBLE_NODE_PASS=%q\nANSIBLE_NODE_HOSTNAME=%q\n' "${ANSIBLE_NODE_IP}" "${ANSIBLE_NODE_USER}" "${ANSIBLE_NODE_PASS}" "${ANSIBLE_NODE_HOSTNAME}"
    printf 'LOCAL_PLAYBOOK_DIR=%q\nREMOTE_PLAYBOOK_DIR=%q\nLOCAL_PAYLOAD_VALIDATOR=%q\nREMOTE_PAYLOAD_VALIDATOR=%q\nREMOTE_PKG_DIR=%q\n' \
      "${RUNTIME_PLAYBOOK_DIR}" "/home/sysadmin/playbooks" "${PROJECT_ROOT}/Automation_Script/Deploy/validate_deb_payloads.sh" "/home/sysadmin/validate_deb_payloads.sh" "/home/sysadmin/pkg"
    for i in 0 1 2; do printf 'REDIS_IPS[%d]=%q\nREDIS_HOSTNAMES[%d]=%q\n' "$i" "${REDIS_IPS[$i]}" "$i" "${REDIS_HOSTNAMES[$i]}"; done
    for i in 0 1 2; do printf 'RABBITMQ_IPS[%d]=%q\nRABBITMQ_HOSTNAMES[%d]=%q\n' "$i" "${RABBITMQ_IPS[$i]}" "$i" "${RABBITMQ_HOSTNAMES[$i]}"; done
    for i in 0 1 2; do printf 'MONGODB_IPS[%d]=%q\nMONGODB_HOSTNAMES[%d]=%q\n' "$i" "${MONGODB_IPS[$i]}" "$i" "${MONGODB_HOSTNAMES[$i]}"; done
    for i in 0 1 2; do printf 'MYSQL_IPS[%d]=%q\nMYSQL_HOSTNAMES[%d]=%q\n' "$i" "${MYSQL_IPS[$i]}" "$i" "${MYSQL_HOSTNAMES[$i]}"; done
    printf 'DB_IPS=("${REDIS_IPS[@]}" "${RABBITMQ_IPS[@]}" "${MONGODB_IPS[@]}" "${MYSQL_IPS[@]}")\nDB_HOSTNAMES=("${REDIS_HOSTNAMES[@]}" "${RABBITMQ_HOSTNAMES[@]}" "${MONGODB_HOSTNAMES[@]}" "${MYSQL_HOSTNAMES[@]}")\n'
    printf 'DB_USER=%q\nDB_PASS=%q\n' "${DB_USER}" "${DB_PASS}"
  } > "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
}

main() {
  [[ -t 0 && -t 1 ]] || die "install.sh 需要在交互式终端运行；请直接执行 bash Automation_Script/Deploy/install.sh"
  mkdir -p "${RUNTIME_PLAYBOOK_DIR}"
  chmod 700 "${RUNTIME_DIR}"
  cp -R "${SCRIPT_DIR}/playbooks/preflights" "${RUNTIME_PLAYBOOK_DIR}/"
  cp -R "${SCRIPT_DIR}/playbooks/site" "${RUNTIME_PLAYBOOK_DIR}/"
  mkdir -p "${RUNTIME_PLAYBOOK_DIR}/group_vars"
  cp "${SCRIPT_DIR}/playbooks/group_vars/"*.yml "${RUNTIME_PLAYBOOK_DIR}/group_vars/"

  info "交付五一键部署向导"
  warn "密码和 Cookie 只保存到 ${RUNTIME_DIR}，不会写入 Git 或普通操作日志。"

  ask "Ansible 管理节点 IP"; ANSIBLE_NODE_IP="${ANSWER}"
  ask "Ansible 管理节点主机名"; ANSIBLE_NODE_HOSTNAME="${ANSWER}"
  ask "Ansible 管理节点账号"; ANSIBLE_NODE_USER="${ANSWER}"
  ask_secret "Ansible 管理节点密码"; ANSIBLE_NODE_PASS="${ANSWER}"

  info "数据库服务器 SSH 配置"
  ask "数据库服务器 SSH 账号"; DB_USER="${ANSWER}"
  ask_secret "数据库服务器 SSH 密码"; DB_PASS="${ANSWER}"
  ask_node_group "Redis" REDIS
  ask_node_group "RabbitMQ" RABBITMQ
  ask_node_group "MongoDB" MONGODB
  ask_node_group "MySQL" MYSQL

  info "组件配置"
  ask_secret "Redis 密码"; redis_password="${ANSWER}"
  ask_secret "RabbitMQ Erlang Cookie"; rabbitmq_cookie="${ANSWER}"
  ask_secret "RabbitMQ admin 密码"; rabbitmq_admin_password="${ANSWER}"
  ask_secret "MongoDB admin 密码"; mongodb_admin_password="${ANSWER}"
  ask_secret "MySQL root 密码"; mysql_root_password="${ANSWER}"
  ask_secret "MySQL replication 密码"; mysql_repl_password="${ANSWER}"
  ask "MySQL Keepalived VIP"; mysql_vip="${ANSWER}"
  ask_secret "Keepalived auth_pass"; keepalived_auth_pass="${ANSWER}"

  write_runtime_config
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/all.yml" mongodb_primary_ip "${MONGODB_IPS[0]}"
  yaml_block "${RUNTIME_PLAYBOOK_DIR}/group_vars/all.yml" mongodb_replica_ips "$(printf 'mongodb_replica_ips:\n  - \"%s\"\n  - \"%s\"' "${MONGODB_IPS[1]}" "${MONGODB_IPS[2]}")"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/all.yml" mysql_primary_ip "${MYSQL_IPS[0]}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/redis.yml" redis_password "${redis_password}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/redis.yml" redis_master_ip "${REDIS_IPS[0]}"
  yaml_block "${RUNTIME_PLAYBOOK_DIR}/group_vars/redis.yml" redis_replicas "$(printf 'redis_replicas:\n  - \"%s\"\n  - \"%s\"' "${REDIS_IPS[1]}" "${REDIS_IPS[2]}")"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/rabbitmq.yml" rabbitmq_seed_node_ip "${RABBITMQ_IPS[0]}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/rabbitmq.yml" rabbitmq_seed_hostname "${RABBITMQ_HOSTNAMES[0]}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/rabbitmq.yml" rabbitmq_node_prefix "${RABBITMQ_HOSTNAMES[0]%[-_][0-9]*}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/rabbitmq.yml" erlang_cookie "${rabbitmq_cookie}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/rabbitmq.yml" rabbitmq_admin_password "${rabbitmq_admin_password}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mongodb.yml" mongodb_admin_password "${mongodb_admin_password}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_root_password "${mysql_root_password}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_repl_password "${mysql_repl_password}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_vip "${mysql_vip}"
  yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" keepalived_auth_pass "${keepalived_auth_pass}"
  yaml_block "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_nodes "$(printf 'mysql_nodes:\n  - ip: \"%s\"\n    hostname: \"%s\"\n    server_id: 1\n    role: \"primary\"\n    keepalived_priority: 100\n  - ip: \"%s\"\n    hostname: \"%s\"\n    server_id: 2\n    role: \"replica\"\n    keepalived_priority: 90\n  - ip: \"%s\"\n    hostname: \"%s\"\n    server_id: 3\n    role: \"replica\"\n    keepalived_priority: 80' "${MYSQL_IPS[0]}" "${MYSQL_HOSTNAMES[0]}" "${MYSQL_IPS[1]}" "${MYSQL_HOSTNAMES[1]}" "${MYSQL_IPS[2]}" "${MYSQL_HOSTNAMES[2]}")"

  {
    printf '交付五安装摘要\n生成时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Ansible 管理节点：%s (%s)\n' "${ANSIBLE_NODE_IP}" "${ANSIBLE_NODE_HOSTNAME}"
    printf 'Redis：%s\nRabbitMQ：%s\nMongoDB：%s\nMySQL：%s\n' "${REDIS_IPS[*]}" "${RABBITMQ_IPS[*]}" "${MONGODB_IPS[*]}" "${MYSQL_IPS[*]}"
    printf '\nMySQL VIP：%s\nMongoDB keyFile：部署后各节点 %s\n' "${mysql_vip}" "/etc/mongodb-keyfile"
    printf '\n敏感凭据位置：%s（权限 600）\n运行时配置位置：%s（目录权限 700）\n' "${CREDENTIALS_FILE}" "${CONFIG_FILE}"
  } > "${SUMMARY_FILE}"
  chmod 600 "${SUMMARY_FILE}"
  {
    printf 'Redis password=%s\nRabbitMQ admin password=%s\nRabbitMQ Erlang Cookie=%s\nMongoDB admin password=%s\nMySQL root password=%s\nMySQL replication password=%s\nKeepalived auth_pass=%s\n' \
      "${redis_password}" "${rabbitmq_admin_password}" "${rabbitmq_cookie}" "${mongodb_admin_password}" "${mysql_root_password}" "${mysql_repl_password}" "${keepalived_auth_pass}"
  } > "${CREDENTIALS_FILE}"
  chmod 600 "${CREDENTIALS_FILE}"

  if [[ "${INSTALL_DRY_RUN:-0}" == "1" ]]; then
    info "配置生成完成（dry-run，未连接远端）"
    grep -R -n 'CHANGE_ME' "${RUNTIME_DIR}" && die "运行时配置仍包含 CHANGE_ME"
    printf '运行时文件：%s\n' "${RUNTIME_DIR}"
    exit 0
  fi

  info "配置生成完成，开始初始化和部署"
  DELIVERY_CONFIG_FILE="${CONFIG_FILE}" DELIVERY_PLAYBOOK_DIR="${RUNTIME_PLAYBOOK_DIR}" \
    bash "${SCRIPT_DIR}/init_ansible.sh" deploy
  info "安装完成"
    printf '\n安装摘要已写入：%s\n' "${SUMMARY_FILE}"
    printf '敏感凭据已写入权限 600 的文件：%s\n' "${CREDENTIALS_FILE}"
    printf '请勿把上述文件内容复制到终端、日志或 Git。\n'
}

main "$@"