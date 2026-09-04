#!/usr/bin/env bash
# eCopilot 数据库高可用部署向导：生成本机运行时配置后调用离线 Ansible 入口。
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/.runtime"
RUNTIME_PLAYBOOK_DIR="${RUNTIME_DIR}/playbooks"
CONFIG_FILE="${RUNTIME_DIR}/config.env"
CREDENTIALS_FILE="${RUNTIME_DIR}/credentials.txt"
SUMMARY_FILE="${RUNTIME_DIR}/install-summary.txt"
ALL_COMPONENTS=(redis rabbitmq mongodb mysql)
SELECTED_COMPONENTS=("${ALL_COMPONENTS[@]}")

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

ask_component_secret() {
  local prompt="$1"
  while true; do
    ask_secret "${prompt}"
    if [[ "${ANSWER}" =~ ^[A-Za-z0-9._:@+=,-]+$ ]]; then
      return
    fi
    warn "该服务凭据只能使用 ASCII 字母、数字及 . _ : @ + = , -，请重新输入"
  done
}

is_valid_subnet_prefix() {
  local value="$1" part
  local old_ifs="${IFS}"
  [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.'
  read -r -a parts <<< "${value}"
  IFS="${old_ifs}"
  for part in "${parts[@]}"; do
    ((10#${part} <= 255)) || return 1
  done
}

is_valid_host_number() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 254))
}

ask_subnet_prefix() {
  local label="$1" prefix="$2" current_prefix="${3:-}" subnet
  while true; do
    if [[ -n "${current_prefix}" ]]; then
      ask "${label} 主机 IP 地址前三段（例如 10.20.14；后续输入 10 得到 ${current_prefix}.10，输入 192.168.10.10 则直接使用该完整 IP；当前 ${current_prefix}）" "${current_prefix}"
    else
      ask "${label} 主机 IP 地址前三段（例如 10.20.14；后续输入 10 得到 10.20.14.10，输入 192.168.10.10 则直接使用该完整 IP）"
    fi
    subnet="${ANSWER}"
    if is_valid_subnet_prefix "${subnet}"; then
      case "${prefix}" in
        REDIS) REDIS_SUBNET_PREFIX="${subnet}" ;;
        RABBITMQ) RABBITMQ_SUBNET_PREFIX="${subnet}" ;;
        MONGODB) MONGODB_SUBNET_PREFIX="${subnet}" ;;
        MYSQL) MYSQL_SUBNET_PREFIX="${subnet}" ;;
        *) die "未知节点组：${prefix}" ;;
      esac
      return
    fi
    warn "IP 前三段格式无效，请输入例如 10.20.14"
    current_prefix=""
  done
}

ask_node_ip() {
  local label="$1" prefix="$2" index="$3" current_ip="$4" subnet="$5" input
  while true; do
    ask "${label} 节点$((index + 1)) 主机号或完整 IP（例如输入 10，则地址为 ${subnet}.10；输入 192.168.10.10，则地址为 192.168.10.10；当前 ${current_ip}）" "${current_ip}"
    input="${ANSWER}"
    if is_valid_host_number "${input}"; then
      ANSWER="${subnet}.${input}"
      return
    fi
    if is_valid_ip "${input}"; then
      ANSWER="${input}"
      return
    fi
    warn "请输入 1-254 的主机号，或完整 IPv4 地址"
  done
}

hostname_for_index() {
  local hostname_prefix="$1" index="$2"
  printf '%s%s' "${hostname_prefix}" "${index}"
}

ask_node_group() {
  local label="$1" prefix="$2" i subnet ip hostname hostname_prefix
  case "${prefix}" in
    REDIS) ask_subnet_prefix "${label}" "${prefix}" "${REDIS_SUBNET_PREFIX:-}" ;;
    RABBITMQ) ask_subnet_prefix "${label}" "${prefix}" "${RABBITMQ_SUBNET_PREFIX:-}" ;;
    MONGODB) ask_subnet_prefix "${label}" "${prefix}" "${MONGODB_SUBNET_PREFIX:-}" ;;
    MYSQL) ask_subnet_prefix "${label}" "${prefix}" "${MYSQL_SUBNET_PREFIX:-}" ;;
    *) die "未知节点组：${prefix}" ;;
  esac
  case "${prefix}" in
    REDIS) subnet="${REDIS_SUBNET_PREFIX}" ;;
    RABBITMQ) subnet="${RABBITMQ_SUBNET_PREFIX}" ;;
    MONGODB) subnet="${MONGODB_SUBNET_PREFIX}" ;;
    MYSQL) subnet="${MYSQL_SUBNET_PREFIX}" ;;
  esac
  for i in 1 2 3; do
    ask_node_ip "${label}" "${prefix}" "$((i - 1))" "" "${subnet}"; ip="${ANSWER}"
    case "${prefix}" in
      REDIS) REDIS_IPS[$((i - 1))]="${ip}" ;;
      RABBITMQ) RABBITMQ_IPS[$((i - 1))]="${ip}" ;;
      MONGODB) MONGODB_IPS[$((i - 1))]="${ip}" ;;
      MYSQL) MYSQL_IPS[$((i - 1))]="${ip}" ;;
      *) die "未知节点组：${prefix}" ;;
    esac
  done
  while true; do
    read -r -p "${label} 主机名前缀（例如 db-node，节点输入 1/2/3 将生成 db-node1/2/3；如输入 T-Redis-0，节点输入 1/2/3 将生成 T-Redis-01/02/03；留空则逐台输入完整主机名）: " hostname_prefix
    [[ -z "${hostname_prefix}" ]] && break
    if is_valid_hostname "$(hostname_for_index "${hostname_prefix}" "1")"; then
      break
    fi
    warn "主机名前缀无效，请使用字母、数字、连字符或下划线"
  done
  for i in 1 2 3; do
    if [[ -n "${hostname_prefix}" ]]; then
      ask "${label} 节点${i} 主机名（可输入完整主机名，输入数字则使用默认名称）" "$(hostname_for_index "${hostname_prefix}" "${i}")"
    else
      ask "${label} 节点${i} 主机名"
    fi
    hostname="${ANSWER}"
    if [[ -n "${hostname_prefix}" && "${hostname}" =~ ^[0-9]+$ ]]; then
      hostname="$(hostname_for_index "${hostname_prefix}" "${hostname}")"
    fi
    case "${prefix}" in
      REDIS) REDIS_HOSTNAMES[$((i - 1))]="${hostname}" ;;
      RABBITMQ) RABBITMQ_HOSTNAMES[$((i - 1))]="${hostname}" ;;
      MONGODB) MONGODB_HOSTNAMES[$((i - 1))]="${hostname}" ;;
      MYSQL) MYSQL_HOSTNAMES[$((i - 1))]="${hostname}" ;;
      *) die "未知节点组：${prefix}" ;;
    esac
  done
}

ask_node() {
  local label="$1" prefix="$2" index="$3" ip hostname current_ip current_hostname subnet current_subnet
  case "${prefix}" in
    REDIS) current_ip="${REDIS_IPS[$index]:-}"; current_hostname="${REDIS_HOSTNAMES[$index]:-}"; current_subnet="${REDIS_SUBNET_PREFIX:-}" ;;
    RABBITMQ) current_ip="${RABBITMQ_IPS[$index]:-}"; current_hostname="${RABBITMQ_HOSTNAMES[$index]:-}"; current_subnet="${RABBITMQ_SUBNET_PREFIX:-}" ;;
    MONGODB) current_ip="${MONGODB_IPS[$index]:-}"; current_hostname="${MONGODB_HOSTNAMES[$index]:-}"; current_subnet="${MONGODB_SUBNET_PREFIX:-}" ;;
    MYSQL) current_ip="${MYSQL_IPS[$index]:-}"; current_hostname="${MYSQL_HOSTNAMES[$index]:-}"; current_subnet="${MYSQL_SUBNET_PREFIX:-}" ;;
    *) die "未知节点组：${prefix}" ;;
  esac
  ask_subnet_prefix "${label}" "${prefix}" "${current_subnet}"; subnet="${ANSWER}"
  ask_node_ip "${label}" "${prefix}" "${index}" "${current_ip}" "${subnet}"; ip="${ANSWER}"
  ask "${label} 节点$((index + 1)) 主机名" "${current_hostname}"; hostname="${ANSWER}"
  case "${prefix}" in
    REDIS) REDIS_SUBNET_PREFIX="${subnet}"; REDIS_IPS[$index]="${ip}"; REDIS_HOSTNAMES[$index]="${hostname}" ;;
    RABBITMQ) RABBITMQ_SUBNET_PREFIX="${subnet}"; RABBITMQ_IPS[$index]="${ip}"; RABBITMQ_HOSTNAMES[$index]="${hostname}" ;;
    MONGODB) MONGODB_SUBNET_PREFIX="${subnet}"; MONGODB_IPS[$index]="${ip}"; MONGODB_HOSTNAMES[$index]="${hostname}" ;;
    MYSQL) MYSQL_SUBNET_PREFIX="${subnet}"; MYSQL_IPS[$index]="${ip}"; MYSQL_HOSTNAMES[$index]="${hostname}" ;;
  esac
}

edit_node_group() {
  local label="$1" prefix="$2" choice
  while true; do
    show_node_group "${label} group" "${prefix}"
    printf '1. 修改节点 1\n2. 修改节点 2\n3. 修改节点 3\n4. 整组重新录入\n5. 返回总览\n0. 取消部署\n'
    ask "请选择操作（0-5）"
    choice="${ANSWER}"
    case "${choice}" in
      1) ask_node "${label}" "${prefix}" 0 ;;
      2) ask_node "${label}" "${prefix}" 1 ;;
      3) ask_node "${label}" "${prefix}" 2 ;;
      4) ask_node_group "${label}" "${prefix}" ;;
      5) return ;;
      0) cancel_deployment; return ;;
      *) warn "请输入 0 到 5" ;;
    esac
  done
}

ask_management_config() {
  ask "Ansible 管理节点 IP"; ANSIBLE_NODE_IP="${ANSWER}"
  ask "Ansible 管理节点主机名"; ANSIBLE_NODE_HOSTNAME="${ANSWER}"
  ask "Ansible 管理节点账号"; ANSIBLE_NODE_USER="${ANSWER}"
  ask_secret "Ansible 管理节点密码"; ANSIBLE_NODE_PASS="${ANSWER}"
}

ask_database_ssh_config() {
  while true; do
    ask "数据库服务器 Linux 登录账号（用于 SSH 登录，不是数据库账号）"; DB_USER="${ANSWER}"
    if is_valid_linux_username "${DB_USER}"; then
      break
    fi
    warn "账号名无效，请输入合法 Linux 用户名（小写字母、数字、下划线或连字符）"
  done
  ask_secret "数据库服务器 Linux 登录密码（用于 SSH 登录）"; DB_PASS="${ANSWER}"
}

component_is_selected() {
  local component="$1" selected
  for selected in "${SELECTED_COMPONENTS[@]}"; do
    [[ "${component}" == "${selected}" ]] && return 0
  done
  return 1
}

select_components() {
  local requested component selected
  local -a parsed=()
  ask "选择部署组件（逗号分隔：redis,rabbitmq,mongodb,mysql；默认全部）" "redis,rabbitmq,mongodb,mysql"
  requested="${ANSWER//,/ }"
  for component in ${requested}; do
    case "${component}" in
      redis|rabbitmq|mongodb|mysql) ;;
      *) warn "未知组件：${component}"; return 1 ;;
    esac
    for selected in "${parsed[@]}"; do
      [[ "${selected}" == "${component}" ]] && { warn "组件重复：${component}"; return 1; }
    done
    parsed+=("${component}")
  done
  [[ "${#parsed[@]}" -gt 0 ]] || { warn "至少选择一个组件"; return 1; }
  SELECTED_COMPONENTS=("${parsed[@]}")
}

ask_component_config() {
  component_is_selected redis && ask_redis_credentials
  component_is_selected rabbitmq && ask_rabbitmq_credentials
  component_is_selected mongodb && ask_mongodb_credentials
  component_is_selected mysql && ask_mysql_credentials
}

ask_redis_credentials() {
  ask_component_secret "Redis 服务访问密码（用于客户端连接 Redis，不是服务器 SSH 登录密码）"; redis_password="${ANSWER}"
}

ask_rabbitmq_credentials() {
  ask_component_secret "RabbitMQ 节点间通信 Cookie（用于 RabbitMQ 集群节点互认证，不是服务器 SSH 登录密码）"; rabbitmq_cookie="${ANSWER}"
  ask_component_secret "RabbitMQ 管理员服务密码（用于 RabbitMQ 管理和客户端访问，不是服务器 SSH 登录密码）"; rabbitmq_admin_password="${ANSWER}"
}

ask_mongodb_credentials() {
  ask_component_secret "MongoDB admin 服务访问密码（用于登录 MongoDB，不是服务器 SSH 登录密码）"; mongodb_admin_password="${ANSWER}"
}

ask_mysql_credentials() {
  ask_component_secret "MySQL root 数据库密码（用于登录 MySQL，不是服务器 SSH 登录密码）"; mysql_root_password="${ANSWER}"
  ask_component_secret "MySQL replication 复制账号密码（用于 MySQL 主从复制，不是服务器 SSH 登录密码）"; mysql_repl_password="${ANSWER}"
  ask_component_secret "MySQL VIP 验证账号密码（仅用于管理节点验收，不是 root 密码）"; mysql_vip_verify_password="${ANSWER}"
  ask "MySQL Keepalived VIP"; mysql_vip="${ANSWER}"
  while true; do
    ask "MySQL Keepalived VIP 前缀长度（1-32，默认 24）" "24"
    mysql_vip_prefix="${ANSWER}"
    if [[ "${mysql_vip_prefix}" =~ ^[0-9]+$ ]] && ((10#${mysql_vip_prefix} >= 1 && 10#${mysql_vip_prefix} <= 32)); then
      break
    fi
    warn "VIP 前缀长度必须是 1 到 32 的整数"
  done
  while true; do
    ask_secret "Keepalived 节点认证密码（用于 MySQL 高可用节点通信，不是服务器 SSH 登录密码，最多 8 个字符）"
    keepalived_auth_pass="${ANSWER}"
    if [[ "${keepalived_auth_pass}" =~ ^[A-Za-z0-9._:@+=,-]+$ && "${#keepalived_auth_pass}" -le 8 ]]; then
      break
    fi
    warn "Keepalived auth_pass 只能使用 ASCII 字母、数字及 . _ : @ + = , -，且最多 8 个字符"
  done
}

show_node_group() {
  local label="$1" prefix="$2" i
  printf '%s：\n' "${label}"
  case "${prefix}" in
    REDIS) for i in 0 1 2; do printf '  节点%d: %s (%s)\n' "$((i + 1))" "${REDIS_IPS[$i]}" "${REDIS_HOSTNAMES[$i]}"; done ;;
    RABBITMQ) for i in 0 1 2; do printf '  节点%d: %s (%s)\n' "$((i + 1))" "${RABBITMQ_IPS[$i]}" "${RABBITMQ_HOSTNAMES[$i]}"; done ;;
    MONGODB) for i in 0 1 2; do printf '  节点%d: %s (%s)\n' "$((i + 1))" "${MONGODB_IPS[$i]}" "${MONGODB_HOSTNAMES[$i]}"; done ;;
    MYSQL) for i in 0 1 2; do printf '  节点%d: %s (%s)\n' "$((i + 1))" "${MYSQL_IPS[$i]}" "${MYSQL_HOSTNAMES[$i]}"; done ;;
  esac
}

show_overview() {
  info "部署参数总览"
  printf 'Ansible 管理节点：%s (%s)，账号：%s\n' "${ANSIBLE_NODE_IP}" "${ANSIBLE_NODE_HOSTNAME}" "${ANSIBLE_NODE_USER}"
  printf '管理节点密码：已输入\n'
  printf '数据库服务器 Linux 登录账号：%s，密码：已输入\n' "${DB_USER}"
  printf '选中组件：%s\n' "${SELECTED_COMPONENTS[*]}"
  component_is_selected redis && show_node_group "REDIS group" REDIS
  component_is_selected rabbitmq && show_node_group "RABBITMQ group" RABBITMQ
  component_is_selected mongodb && show_node_group "MONGODB group" MONGODB
  component_is_selected mysql && show_node_group "MYSQL group" MYSQL
  printf '选中组件凭据/Cookie：已输入\n'
  component_is_selected mysql && printf 'MySQL Keepalived VIP：%s\n' "${mysql_vip}"
}

is_valid_ip() {
  local value="$1" part
  local old_ifs="${IFS}"
  [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.'
  read -r -a parts <<< "${value}"
  IFS="${old_ifs}"
  for part in "${parts[@]}"; do
    ((10#${part} <= 255)) || return 1
  done
}

is_valid_linux_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]
}

is_valid_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*[A-Za-z0-9]$|^[A-Za-z0-9]$ ]]
}

validate_configuration() {
  local error_count=0 i j ip hostname
  local all_ips all_hostnames
  all_ips=("${ANSIBLE_NODE_IP}")
  all_hostnames=("${ANSIBLE_NODE_HOSTNAME}")
  component_is_selected redis && { all_ips+=("${REDIS_IPS[@]}"); all_hostnames+=("${REDIS_HOSTNAMES[@]}"); }
  component_is_selected rabbitmq && { all_ips+=("${RABBITMQ_IPS[@]}"); all_hostnames+=("${RABBITMQ_HOSTNAMES[@]}"); }
  component_is_selected mongodb && { all_ips+=("${MONGODB_IPS[@]}"); all_hostnames+=("${MONGODB_HOSTNAMES[@]}"); }
  component_is_selected mysql && { all_ips+=("${MYSQL_IPS[@]}"); all_hostnames+=("${MYSQL_HOSTNAMES[@]}"); }
  for ip in "${all_ips[@]}"; do
    if ! is_valid_ip "${ip}"; then
      warn "IP 地址格式无效：${ip}"; error_count=$((error_count + 1))
    fi
  done
  for hostname in "${all_hostnames[@]}"; do
    if ! is_valid_hostname "${hostname}"; then
      warn "主机名格式无效：${hostname}"; error_count=$((error_count + 1))
    fi
  done
  if ! is_valid_ip "${ANSIBLE_NODE_IP}"; then
    warn "Ansible 管理节点 IP 地址格式无效：${ANSIBLE_NODE_IP}"; error_count=$((error_count + 1))
  fi
  if component_is_selected mysql && ! is_valid_ip "${mysql_vip}"; then
    warn "MySQL VIP 地址格式无效：${mysql_vip}"; error_count=$((error_count + 1))
  fi
  for ((i = 0; i < ${#all_ips[@]}; i++)); do
    for ((j = i + 1; j < ${#all_ips[@]}; j++)); do
      if [[ "${all_ips[$i]}" == "${all_ips[$j]}" ]]; then
        warn "节点 IP 重复：${all_ips[$i]}"; error_count=$((error_count + 1))
      fi
    done
  done
  for ((i = 0; i < ${#all_hostnames[@]}; i++)); do
    for ((j = i + 1; j < ${#all_hostnames[@]}; j++)); do
      if [[ "${all_hostnames[$i]}" == "${all_hostnames[$j]}" ]]; then
        warn "节点主机名重复：${all_hostnames[$i]}"; error_count=$((error_count + 1))
      fi
    done
  done
  if component_is_selected mysql; then
    for ip in "${all_ips[@]}"; do
      if [[ "${mysql_vip}" == "${ip}" ]]; then
        warn "MySQL VIP 不能与数据库节点 IP 相同：${mysql_vip}"; error_count=$((error_count + 1))
      fi
    done
  fi
  ((error_count == 0))
}

cancel_deployment() {
  local answer
  ask "确定取消本次部署？当前输入不会保存" "n"
  answer="${ANSWER}"
  case "${answer}" in
    [Yy]) exit 0 ;;
    *) info "已返回配置流程" ;;
  esac
}

reset_configuration() {
  local choice number
  local -a menu_actions=()
  info "请选择需要修改的配置"
  component_is_selected redis && menu_actions+=(redis_nodes redis_credentials)
  component_is_selected rabbitmq && menu_actions+=(rabbitmq_nodes rabbitmq_credentials)
  component_is_selected mongodb && menu_actions+=(mongodb_nodes mongodb_credentials)
  component_is_selected mysql && menu_actions+=(mysql_nodes mysql_credentials)
  menu_actions+=(management database_ssh reselect_components return)
  number=1
  local action
  for action in "${menu_actions[@]}"; do
    case "${action}" in
      redis_nodes) printf '%d. Redis 节点组\n' "${number}" ;;
      redis_credentials) printf '%d. Redis 凭据\n' "${number}" ;;
      rabbitmq_nodes) printf '%d. RabbitMQ 节点组\n' "${number}" ;;
      rabbitmq_credentials) printf '%d. RabbitMQ 凭据\n' "${number}" ;;
      mongodb_nodes) printf '%d. MongoDB 节点组\n' "${number}" ;;
      mongodb_credentials) printf '%d. MongoDB 凭据\n' "${number}" ;;
      mysql_nodes) printf '%d. MySQL 节点组\n' "${number}" ;;
      mysql_credentials) printf '%d. MySQL 凭据和 VIP\n' "${number}" ;;
      management) printf '%d. Ansible 管理节点\n' "${number}" ;;
      database_ssh) printf '%d. 数据库 SSH\n' "${number}" ;;
      reselect_components) printf '%d. 重新选择组件并完整录入\n' "${number}" ;;
      return) printf '%d. 取消修改，返回总览\n' "${number}" ;;
    esac
    number=$((number + 1))
  done
  printf '0. 取消部署\n'
  while true; do
    ask "请选择要修改的配置（0-$((number - 1))）"
    choice="${ANSWER}"
    if [[ "${choice}" == 0 ]]; then
      cancel_deployment
      continue
    fi
    [[ "${choice}" =~ ^[0-9]+$ ]] && ((10#${choice} >= 1 && 10#${choice} < number)) || {
      warn "请输入 0 到 $((number - 1))"
      continue
    }
    action="${menu_actions[$((10#${choice} - 1))]}"
    case "${action}" in
      redis_nodes) edit_node_group "Redis" REDIS; return ;;
      redis_credentials) ask_redis_credentials; return ;;
      rabbitmq_nodes) edit_node_group "RabbitMQ" RABBITMQ; return ;;
      rabbitmq_credentials) ask_rabbitmq_credentials; return ;;
      mongodb_nodes) edit_node_group "MongoDB" MONGODB; return ;;
      mongodb_credentials) ask_mongodb_credentials; return ;;
      mysql_nodes) edit_node_group "MySQL" MYSQL; return ;;
      mysql_credentials) ask_mysql_credentials; return ;;
      management) ask_management_config; return ;;
      database_ssh) ask_database_ssh_config; return ;;
      reselect_components) collect_all_inputs; return ;;
      return) return ;;
    esac
  done
}

collect_all_inputs() {
  ask_management_config
  info "数据库服务器 SSH 配置"
  ask_database_ssh_config
  while ! select_components; do :; done
  component_is_selected redis && ask_node_group "Redis" REDIS
  component_is_selected rabbitmq && ask_node_group "RabbitMQ" RABBITMQ
  component_is_selected mongodb && ask_node_group "MongoDB" MONGODB
  component_is_selected mysql && ask_node_group "MySQL" MYSQL
  info "组件配置"
  ask_component_config
}

confirm_overview() {
  local answer validation_round=0
  while true; do
    show_overview
    validation_round=$((validation_round + 1))
    info "正在进行第 ${validation_round} 次配置校验"
    if ! validate_configuration; then
      warn "配置校验未通过，请先修改错误配置；修正后将重新校验"
      reset_configuration
      continue
    fi
    printf '\033[0;32m✓ 配置校验通过：IP、主机名、重复项和 MySQL VIP 均符合要求\033[0m\n'
    ask "确认以上配置并开始部署？[y] 开始部署，[n] 返回修改菜单，[q] 取消" "y"
    answer="${ANSWER}"
    case "${answer}" in
      [Yy]) return ;;
      [Nn]) reset_configuration ;;
      [Qq]) cancel_deployment ;;
      *) warn "请输入 y、n 或 q" ;;
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
  local i selected_components_csv
  selected_components_csv=$(IFS=,; printf '%s' "${SELECTED_COMPONENTS[*]}")
  {
    printf '# 本机生成的运行时配置，禁止提交 Git。\n'
    printf 'PROJECT_ROOT=%q\n' "${PROJECT_ROOT}"
    printf 'DEPLOY_COMPONENTS=%q\n' "${selected_components_csv}"
    printf 'PKG_ROOT=%q\nLOCAL_DB_PKG_DIR=%q\n' "${PROJECT_ROOT}/Automation_Script/Deploy/pkg" "${PROJECT_ROOT}/离线安装包"
    printf 'ANSIBLE_NODE_IP=%q\nANSIBLE_NODE_USER=%q\nANSIBLE_NODE_PASS=%q\nANSIBLE_NODE_HOSTNAME=%q\n' "${ANSIBLE_NODE_IP}" "${ANSIBLE_NODE_USER}" "${ANSIBLE_NODE_PASS}" "${ANSIBLE_NODE_HOSTNAME}"
    printf 'LOCAL_PLAYBOOK_DIR=%q\nREMOTE_PLAYBOOK_DIR=%q\nLOCAL_PAYLOAD_VALIDATOR=%q\nREMOTE_PAYLOAD_VALIDATOR=%q\nREMOTE_PKG_DIR=%q\n' \
      "${RUNTIME_PLAYBOOK_DIR}" "/home/${ANSIBLE_NODE_USER}/playbooks" "${PROJECT_ROOT}/Automation_Script/Deploy/validate_deb_payloads.sh" "/home/${ANSIBLE_NODE_USER}/validate_deb_payloads.sh" "/home/${ANSIBLE_NODE_USER}/pkg"
    printf 'REDIS_IPS=()\nREDIS_HOSTNAMES=()\nRABBITMQ_IPS=()\nRABBITMQ_HOSTNAMES=()\nMONGODB_IPS=()\nMONGODB_HOSTNAMES=()\nMYSQL_IPS=()\nMYSQL_HOSTNAMES=()\n'
    if component_is_selected redis; then for i in 0 1 2; do printf 'REDIS_IPS[%d]=%q\nREDIS_HOSTNAMES[%d]=%q\n' "$i" "${REDIS_IPS[$i]}" "$i" "${REDIS_HOSTNAMES[$i]}"; done; fi
    if component_is_selected rabbitmq; then for i in 0 1 2; do printf 'RABBITMQ_IPS[%d]=%q\nRABBITMQ_HOSTNAMES[%d]=%q\n' "$i" "${RABBITMQ_IPS[$i]}" "$i" "${RABBITMQ_HOSTNAMES[$i]}"; done; fi
    if component_is_selected mongodb; then for i in 0 1 2; do printf 'MONGODB_IPS[%d]=%q\nMONGODB_HOSTNAMES[%d]=%q\n' "$i" "${MONGODB_IPS[$i]}" "$i" "${MONGODB_HOSTNAMES[$i]}"; done; fi
    if component_is_selected mysql; then for i in 0 1 2; do printf 'MYSQL_IPS[%d]=%q\nMYSQL_HOSTNAMES[%d]=%q\n' "$i" "${MYSQL_IPS[$i]}" "$i" "${MYSQL_HOSTNAMES[$i]}"; done; fi
    printf 'DB_IPS=("${REDIS_IPS[@]}" "${RABBITMQ_IPS[@]}" "${MONGODB_IPS[@]}" "${MYSQL_IPS[@]}")\nDB_HOSTNAMES=("${REDIS_HOSTNAMES[@]}" "${RABBITMQ_HOSTNAMES[@]}" "${MONGODB_HOSTNAMES[@]}" "${MYSQL_HOSTNAMES[@]}")\n'
    printf 'DB_USER=%q\nDB_PASS=%q\n' "${DB_USER}" "${DB_PASS}"
  } > "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
}

show_deployment_guide() {
  local guide_file="${SCRIPT_DIR}/部署向导说明.md"
  if [[ ! -f "${guide_file}" ]]; then
    warn "找不到部署说明：${guide_file}"
    return
  fi
  if command -v less >/dev/null 2>&1; then
    less "${guide_file}"
  elif command -v more >/dev/null 2>&1; then
    more "${guide_file}"
  else
    cat "${guide_file}"
  fi
}

show_deployment_status() {
  local component operation result state_file recorded_at last_stage
  local found=0
  info "本地部署状态"
  if [[ ! -d "${RUNTIME_DIR}/state" ]]; then
    printf '尚无本地 checkpoint 状态记录。\n'
    return
  fi
  for component in "${ALL_COMPONENTS[@]}"; do
    for operation in deploy verify; do
      for result in verified failed; do
        state_file="${RUNTIME_DIR}/state/${component}.${operation}.${result}"
        [[ -f "${state_file}" ]] || continue
        recorded_at=$(awk -F= '/^recorded_at=/ { print substr($0, index($0, "=") + 1); exit }' "${state_file}")
        last_stage=$(awk -F= '/^last_successful_stage=/ { print substr($0, index($0, "=") + 1); exit }' "${state_file}")
        printf '%-9s %-7s %-8s 时间：%s；最后成功阶段：%s\n' \
          "${component}" "${operation}" "${result}" "${recorded_at:-未知}" "${last_stage:-未知}"
        found=1
      done
    done
  done
  [[ "${found}" -eq 1 ]] || printf '尚无本地 checkpoint 状态记录。\n'
  printf '状态仅用于排障，不会跳过实际预检、部署或验证。\n'
}

resume_existing_deployment() {
  local choice deploy_args saved_components
  [[ -f "${CONFIG_FILE}" && -d "${RUNTIME_PLAYBOOK_DIR}" ]] || \
    die "未找到可继续的运行时配置，请先完成一次配置录入。"

  info "继续既有部署"
  printf '不会重新采集配置、删除数据或回退已成功组件。\n'
  saved_components=$(sed -n 's/^DEPLOY_COMPONENTS=//p' "${CONFIG_FILE}" | head -n 1)
  if [[ "${saved_components}" =~ ^(redis|rabbitmq|mongodb|mysql)(,(redis|rabbitmq|mongodb|mysql))*$ ]]; then
    printf '本运行时配置的组件范围：%s\n' "${saved_components}"
    ask "确认按原组件范围重试？[y] 继续，[n] 返回菜单" "y"
    case "${ANSWER}" in
      [Yy]) deploy_args=(--components "${saved_components}") ;;
      *) return ;;
    esac
    DELIVERY_CONFIG_FILE="${CONFIG_FILE}" DELIVERY_PLAYBOOK_DIR="${RUNTIME_PLAYBOOK_DIR}" \
      bash "${SCRIPT_DIR}/init_ansible.sh" deploy "${deploy_args[@]}"
    info "继续部署结束"
    return
  fi
  warn "既有运行时配置未记录组件范围，将使用兼容的全量续装菜单。"
  printf '1. 从 Redis 开始（Redis、RabbitMQ、MongoDB、MySQL）\n'
  printf '2. 从 RabbitMQ 开始（RabbitMQ、MongoDB、MySQL）\n'
  printf '3. 从 MongoDB 开始（MongoDB、MySQL）\n'
  printf '4. 从 MySQL 开始（MySQL）\n'
  printf '0. 返回启动菜单\n'
  ask "请选择继续位置（0-4）" "3"
  choice="${ANSWER}"
  case "${choice}" in
    1) deploy_args=(--from redis) ;;
    2) deploy_args=(--from rabbitmq) ;;
    3) deploy_args=(--from mongodb) ;;
    4) deploy_args=(--from mysql) ;;
    0) return ;;
    *) warn "请输入 0-4"; return ;;
  esac

  DELIVERY_CONFIG_FILE="${CONFIG_FILE}" DELIVERY_PLAYBOOK_DIR="${RUNTIME_PLAYBOOK_DIR}" \
    bash "${SCRIPT_DIR}/init_ansible.sh" deploy "${deploy_args[@]}"
  info "继续部署结束"
}

redeploy_existing_configuration() {
  local saved_components deploy_args
  [[ -f "${CONFIG_FILE}" && -d "${RUNTIME_PLAYBOOK_DIR}" ]] || \
    die "未找到可重新部署的运行时配置，请先完成一次配置录入。"

  saved_components=$(sed -n 's/^DEPLOY_COMPONENTS=//p' "${CONFIG_FILE}" | head -n 1)
  if [[ ! "${saved_components}" =~ ^(redis|rabbitmq|mongodb|mysql)(,(redis|rabbitmq|mongodb|mysql))*$ ]]; then
    warn "既有运行时配置未记录组件范围，无法安全执行显式重新部署。"
    return
  fi

  printf '将对原组件范围重新执行部署：%s\n' "${saved_components}"
  printf '不会清空数据、删除已成功组件或承诺事务回滚。\n'
  ask "确认进入部署计划确认环节？[y] 继续，[n] 返回菜单" "n"
  case "${ANSWER}" in
    [Yy]) deploy_args=(--components "${saved_components}") ;;
    *) return ;;
  esac
  DELIVERY_CONFIG_FILE="${CONFIG_FILE}" DELIVERY_PLAYBOOK_DIR="${RUNTIME_PLAYBOOK_DIR}" \
    bash "${SCRIPT_DIR}/init_ansible.sh" deploy "${deploy_args[@]}"
  info "重新部署结束"
}

main() {
  [[ -t 0 && -t 1 ]] || die "install.sh 需要在交互式终端运行；请直接执行 bash Automation_Script/Deploy/install.sh"

  info "eCopilot 数据库高可用部署向导"
  warn "安全提示：本向导首次连接目标主机时不人工验证 SSH 主机指纹。"
  warn "本方式仅适用于受控部署网络。"
  warn "不建议在不可信网络中执行。"
  printf '\n'
  printf '本向导将配置 Redis、RabbitMQ、MongoDB、MySQL 四套三节点服务，并通过离线 Ansible 完成部署。\n'
  printf '部署版本：Redis 8.2.8；RabbitMQ 4.2.9 + Erlang 27.3.4.16-1；MongoDB 8.2.12；MySQL 8.4.11。\n'
  printf '部署架构：Redis 主从 + Sentinel、RabbitMQ 三节点、MongoDB rs0 三节点副本集、MySQL GTID 异步主从 + Keepalived VIP。\n'
  printf '部署会修改目标服务器的主机名、/etc/hosts、软件和服务配置。预计耗时约 10-30 分钟。\n'
  printf '前置条件：Ubuntu 24.04.x amd64、SSH 可达、Linux 账号可 sudo、交付包离线资产完整。\n'
  printf '同组节点同一网段时，可先输入网段前三段（例如 10.20.14），再输入主机号。\n'
  printf '节点位于不同网段时，请为每个节点直接输入完整 IPv4 地址。\n'
  printf '查看部署说明：启动菜单中选择“查看部署说明”，阅读结束后返回菜单。\n'
  warn "密码和 Cookie 只保存到 ${RUNTIME_DIR}，不会写入 Git 或普通操作日志。"
  local start_choice next_choice status_choice="" resume_choice="" redeploy_choice=""
  while true; do
    printf '\n1. 开始录入配置\n2. 查看部署说明\n'
    next_choice=3
    if [[ -d "${RUNTIME_DIR}/state" ]]; then
      status_choice="${next_choice}"
      printf '%s. 查看本地部署状态\n' "${status_choice}"
      next_choice=$((next_choice + 1))
    else
      status_choice=""
    fi
    if [[ -f "${CONFIG_FILE}" && -d "${RUNTIME_PLAYBOOK_DIR}" ]]; then
      resume_choice="${next_choice}"
      printf '%s. 使用既有配置继续部署\n' "${resume_choice}"
      next_choice=$((next_choice + 1))
      redeploy_choice="${next_choice}"
      printf '%s. 按既有配置重新部署\n' "${redeploy_choice}"
    else
      resume_choice=""
      redeploy_choice=""
    fi
    printf '0. 退出向导\n'
    ask "请选择操作" "1"
    start_choice="${ANSWER}"
    if [[ "${start_choice}" == "1" ]]; then
      break
    elif [[ "${start_choice}" == "2" ]]; then
      show_deployment_guide
    elif [[ -n "${status_choice}" && "${start_choice}" == "${status_choice}" ]]; then
      show_deployment_status
    elif [[ -n "${resume_choice}" && "${start_choice}" == "${resume_choice}" ]]; then
      resume_existing_deployment
    elif [[ -n "${redeploy_choice}" && "${start_choice}" == "${redeploy_choice}" ]]; then
      redeploy_existing_configuration
    elif [[ "${start_choice}" == "0" ]]; then
      cancel_deployment
    else
      warn "请输入菜单中显示的编号"
    fi
  done

  collect_all_inputs
  confirm_overview

  rm -rf "${RUNTIME_DIR}"
  mkdir -p "${RUNTIME_PLAYBOOK_DIR}/group_vars"
  chmod 700 "${RUNTIME_DIR}"
  cp -R "${SCRIPT_DIR}/playbooks/preflights" "${RUNTIME_PLAYBOOK_DIR}/"
  cp -R "${SCRIPT_DIR}/playbooks/site" "${RUNTIME_PLAYBOOK_DIR}/"
  cp "${SCRIPT_DIR}/playbooks/group_vars/"*.yml "${RUNTIME_PLAYBOOK_DIR}/group_vars/"

  write_runtime_config
  if component_is_selected mongodb; then
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/all.yml" mongodb_primary_ip "${MONGODB_IPS[0]}"
    yaml_block "${RUNTIME_PLAYBOOK_DIR}/group_vars/all.yml" mongodb_replica_ips "$(printf 'mongodb_replica_ips:\n  - \"%s\"\n  - \"%s\"' "${MONGODB_IPS[1]}" "${MONGODB_IPS[2]}")"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mongodb.yml" mongodb_admin_password "${mongodb_admin_password}"
  fi
  if component_is_selected mysql; then
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/all.yml" mysql_primary_ip "${MYSQL_IPS[0]}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_root_password "${mysql_root_password}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_repl_password "${mysql_repl_password}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_vip_verify_host "${MYSQL_IPS[0]}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_vip_verify_password "${mysql_vip_verify_password}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_vip "${mysql_vip}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_vip_prefix "${mysql_vip_prefix}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" keepalived_auth_pass "${keepalived_auth_pass}"
    yaml_block "${RUNTIME_PLAYBOOK_DIR}/group_vars/mysql.yml" mysql_nodes "$(printf 'mysql_nodes:\n  - ip: \"%s\"\n    hostname: \"%s\"\n    server_id: 1\n    role: \"primary\"\n    keepalived_priority: 100\n  - ip: \"%s\"\n    hostname: \"%s\"\n    server_id: 2\n    role: \"replica\"\n    keepalived_priority: 90\n  - ip: \"%s\"\n    hostname: \"%s\"\n    server_id: 3\n    role: \"replica\"\n    keepalived_priority: 80' "${MYSQL_IPS[0]}" "${MYSQL_HOSTNAMES[0]}" "${MYSQL_IPS[1]}" "${MYSQL_HOSTNAMES[1]}" "${MYSQL_IPS[2]}" "${MYSQL_HOSTNAMES[2]}")"
  fi
  if component_is_selected redis; then
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/redis.yml" redis_password "${redis_password}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/redis.yml" redis_master_ip "${REDIS_IPS[0]}"
    yaml_block "${RUNTIME_PLAYBOOK_DIR}/group_vars/redis.yml" redis_replicas "$(printf 'redis_replicas:\n  - \"%s\"\n  - \"%s\"' "${REDIS_IPS[1]}" "${REDIS_IPS[2]}")"
  fi
  if component_is_selected rabbitmq; then
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/rabbitmq.yml" rabbitmq_seed_node_ip "${RABBITMQ_IPS[0]}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/rabbitmq.yml" rabbitmq_seed_hostname "${RABBITMQ_HOSTNAMES[0]}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/rabbitmq.yml" rabbitmq_node_prefix "${RABBITMQ_HOSTNAMES[0]%[-_][0-9]*}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/rabbitmq.yml" erlang_cookie "${rabbitmq_cookie}"
    yaml_scalar "${RUNTIME_PLAYBOOK_DIR}/group_vars/rabbitmq.yml" rabbitmq_admin_password "${rabbitmq_admin_password}"
  fi

  {
    printf 'eCopilot 数据库高可用部署摘要\n生成时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Ansible 管理节点：%s (%s)\n' "${ANSIBLE_NODE_IP}" "${ANSIBLE_NODE_HOSTNAME}"
    printf '选中组件：%s\n' "${SELECTED_COMPONENTS[*]}"
    component_is_selected redis && printf 'Redis：%s\n' "${REDIS_IPS[*]}"
    component_is_selected rabbitmq && printf 'RabbitMQ：%s\n' "${RABBITMQ_IPS[*]}"
    component_is_selected mongodb && printf 'MongoDB：%s\nMongoDB keyFile：部署后各节点 %s\n' "${MONGODB_IPS[*]}" "/etc/mongodb-keyfile"
    component_is_selected mysql && printf 'MySQL：%s\nMySQL VIP：%s/%s\n' "${MYSQL_IPS[*]}" "${mysql_vip}" "${mysql_vip_prefix}"
    printf '\n敏感凭据位置：%s（权限 600）\n运行时配置位置：%s（目录权限 700）\n' "${CREDENTIALS_FILE}" "${CONFIG_FILE}"
  } > "${SUMMARY_FILE}"
  chmod 600 "${SUMMARY_FILE}"
  credentials_tmp="${CREDENTIALS_FILE}.tmp.$$"
  {
    printf 'eCopilot 数据库高可用部署凭据清单\n生成时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[Ansible 管理节点]\nIP=%s\n主机名=%s\n账号=%s\n密码=%s\n\n' \
      "${ANSIBLE_NODE_IP}" "${ANSIBLE_NODE_HOSTNAME}" "${ANSIBLE_NODE_USER}" "${ANSIBLE_NODE_PASS}"
    printf '[数据库服务器 SSH]\n账号=%s\n密码=%s\n\n' "${DB_USER}" "${DB_PASS}"
    if component_is_selected redis; then
      printf '[Redis 节点]\n'
      for i in 0 1 2; do printf '节点%d IP=%s 主机名=%s\n' "$((i + 1))" "${REDIS_IPS[$i]}" "${REDIS_HOSTNAMES[$i]}"; done
      printf '服务密码=%s\n\n' "${redis_password}"
    fi
    if component_is_selected rabbitmq; then
      printf '[RabbitMQ 节点]\n'
      for i in 0 1 2; do printf '节点%d IP=%s 主机名=%s\n' "$((i + 1))" "${RABBITMQ_IPS[$i]}" "${RABBITMQ_HOSTNAMES[$i]}"; done
      printf '节点间通信 Cookie=%s\n管理员服务密码=%s\n\n' "${rabbitmq_cookie}" "${rabbitmq_admin_password}"
    fi
    if component_is_selected mongodb; then
      printf '[MongoDB 节点]\n'
      for i in 0 1 2; do printf '节点%d IP=%s 主机名=%s\n' "$((i + 1))" "${MONGODB_IPS[$i]}" "${MONGODB_HOSTNAMES[$i]}"; done
      printf 'admin 服务密码=%s\n\n' "${mongodb_admin_password}"
    fi
    if component_is_selected mysql; then
      printf '[MySQL 节点]\n'
      for i in 0 1 2; do printf '节点%d IP=%s 主机名=%s\n' "$((i + 1))" "${MYSQL_IPS[$i]}" "${MYSQL_HOSTNAMES[$i]}"; done
      printf 'root 数据库密码=%s\nreplication 复制账号密码=%s\nVIP 验证账号密码=%s\nKeepalived VIP=%s\nKeepalived 节点通信认证密码=%s\n' \
        "${mysql_root_password}" "${mysql_repl_password}" "${mysql_vip_verify_password}" "${mysql_vip}" "${keepalived_auth_pass}"
    fi
  } > "${credentials_tmp}"
  chmod 600 "${credentials_tmp}"
  mv "${credentials_tmp}" "${CREDENTIALS_FILE}"
  chmod 600 "${CREDENTIALS_FILE}"

  if [[ "${INSTALL_DRY_RUN:-0}" == "1" ]]; then
    info "配置生成完成（dry-run，未连接远端）"
    printf '运行时文件：%s\n' "${RUNTIME_DIR}"
    exit 0
  fi

  info "配置生成完成，开始初始化和部署"
  DELIVERY_CONFIG_FILE="${CONFIG_FILE}" DELIVERY_PLAYBOOK_DIR="${RUNTIME_PLAYBOOK_DIR}" \
    bash "${SCRIPT_DIR}/init_ansible.sh" deploy --components "$(IFS=,; printf '%s' "${SELECTED_COMPONENTS[*]}")"
  info "安装完成"
    printf '\n安装摘要已写入：%s\n' "${SUMMARY_FILE}"
    printf '敏感凭据已写入权限 600 的文件：%s\n' "${CREDENTIALS_FILE}"
    printf '请勿把上述文件内容复制到终端、日志或 Git。\n'
}

main "$@"