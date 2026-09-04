#!/usr/bin/env bash
# ============================================================
# init_ansible.sh — Ansible 管理节点完整初始化脚本
# 对应文档：1. Ansible管理节点初始化操作指令.md（Step 0~9）
#
# 支持系统：macOS / Linux / WSL（Windows Subsystem for Linux）
#   Windows 原生环境请使用 WSL 执行本脚本
#
# 执行方式（在项目根目录下执行）：
#   bash "Automation_Script/Deploy/init_ansible.sh"
#
# 阶段说明：
#   Step 0~3  校验并上传随交付包提供的 Ansible/sshpass 离线资产
#   Step 4~9  配置阶段（全程离线，SSH 驱动管理节点）
#
# 幂等性：所有步骤均可重复执行，已完成的步骤自动跳过
# ============================================================
set -euo pipefail

# ============================================================
# 工具函数
# ============================================================
info() { echo -e "\n\033[1;34m[Step $1]\033[0m $2"; }
ok()   { echo -e "\033[0;32m  ✔ $*\033[0m"; }
warn() { echo -e "\033[0;33m  ⚠ $*\033[0m"; }
err()  { echo -e "\033[0;31m  ✘ $*\033[0m" >&2; exit 1; }
log()  { echo -e "  → $*"; }

# ============================================================
# 本地前置工具
# ============================================================
ensure_local_tools() {
  local tool
  for tool in ssh sshpass scp rsync; do
    command -v "${tool}" &>/dev/null || \
      err "本机缺少 ${tool}；请在受控准备环境预先安装后重试。交付脚本不会联网安装工具。"
  done
}

# ============================================================
# 加载变量 & SSH 工具
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${DELIVERY_CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
[[ -f "${CONFIG_FILE}" ]] || err "配置文件不存在：${CONFIG_FILE}"
source "${CONFIG_FILE}"
DELIVERY_LOG_DIR="${DELIVERY_LOG_DIR:-$(cd "$(dirname "${CONFIG_FILE}")" && pwd)/logs}"
DELIVERY_STATE_DIR="${DELIVERY_STATE_DIR:-$(cd "$(dirname "${CONFIG_FILE}")" && pwd)/state}"
VERBOSE=0
AUTO_APPROVE=0
STATE_OPERATION=""
LAST_SUCCESSFUL_STAGE=""
LAST_SUCCESSFUL_LOG_FILE=""
LOCAL_DELIVERY_VERIFIER="${SCRIPT_DIR}/verify_delivery.sh"
ALL_COMPONENTS=(redis rabbitmq mongodb mysql)
SELECTED_COMPONENTS=("${ALL_COMPONENTS[@]}")
SELECTED_COMPONENTS_CSV="redis,rabbitmq,mongodb,mysql"
SELECTED_HOST_PATTERN="redis:rabbitmq:mongodb:mysql"
SELECTED_LIMIT_PATTERN="redis:rabbitmq:mongodb:mysql:localhost"
SELECTED_DB_IPS=()
SELECTED_DB_HOSTNAMES=()

[[ -n "${ANSIBLE_NODE_USER:-}" ]] || err "ANSIBLE_NODE_USER 未配置"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
REMOTE="${ANSIBLE_NODE_USER}@${ANSIBLE_NODE_IP}"

# 所有本地→管理节点的 SSH/SCP 均通过此函数，密码用环境变量传递（不暴露在进程列表）
ssh_run() {
  SSHPASS="${ANSIBLE_NODE_PASS}" sshpass -e \
    ssh ${SSH_OPTS} "${REMOTE}" "$@"
}

scp_run() {
  local attempt sshpass_file
  sshpass_file="$(mktemp "${TMPDIR:-/tmp}/ecopilot-scp-pass.XXXXXX")"
  chmod 600 "${sshpass_file}"
  printf '%s\n' "${ANSIBLE_NODE_PASS}" > "${sshpass_file}"
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if sshpass -f "${sshpass_file}" scp ${SSH_OPTS} \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no "$@"; then
      rm -f -- "${sshpass_file}"
      return 0
    fi
    [[ "${attempt}" -lt 10 ]] && sleep 5
  done
  rm -f -- "${sshpass_file}"
  return 1
}

# 将 sudo 密码通过 SSH 标准输入传递，避免出现在远端命令参数中。
sudo_run() {
  local command="$1"
  printf '%s\n' "${ANSIBLE_NODE_PASS}" | \
    ssh_run "sudo -S -p '' bash -c $(printf '%q' "${command}")"
}

sudo_script_run() {
  local script="$1"
  if ssh_run "sudo -n true" >/dev/null 2>&1; then
    printf '%s\n' "${script}" | ssh_run "sudo -n bash -s"
  else
    {
      printf '%s\n' "${ANSIBLE_NODE_PASS}"
      printf '%s\n' "${script}"
    } | ssh_run "sudo -S -p '' bash -s"
  fi
}

remote_secret_script_run() {
  local secret="$1"
  local script="$2"
  {
    printf '%s\n' "${secret}"
    printf '%s\n' "${script}"
  } | ssh_run 'read -r ECOPILOT_SECRET; script_file=$(mktemp); chmod 600 "$script_file"; cat > "$script_file"; ECOPILOT_SECRET="$ECOPILOT_SECRET" bash "$script_file"; rc=$?; rm -f -- "$script_file"; exit "$rc"'
}

DEPLOY_SUDOERS_FILE="/etc/sudoers.d/ecopilot-deploy-${ANSIBLE_NODE_USER}"
DB_SUDOERS_FILE="/etc/sudoers.d/ecopilot-deploy-${DB_USER:-dbuser}"

cleanup_deploy_sudoers() {
  set +e
  remote_secret_script_run "${DB_PASS}" "$(cat <<EOF
for ip in ${SELECTED_DB_IPS[*]}; do
  ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${DB_USER}@\${ip} \\
    "sudo -n rm -f '${DB_SUDOERS_FILE}'" >/dev/null 2>&1 || true
done
EOF
)" >/dev/null 2>&1 || true
  sudo_script_run "rm -f '${DEPLOY_SUDOERS_FILE}'" >/dev/null 2>&1 || true
}

component_is_valid() {
  case "$1" in
    redis|rabbitmq|mongodb|mysql) return 0 ;;
    *) return 1 ;;
  esac
}

component_is_selected() {
  local component="$1" selected
  for selected in "${SELECTED_COMPONENTS[@]}"; do
    [[ "${selected}" == "${component}" ]] && return 0
  done
  return 1
}

set_selected_components() {
  local requested="$1" component parsed_component parsed_count=0
  local -a parsed_components=()
  requested="${requested//,/ }"
  for component in ${requested}; do
    component_is_valid "${component}" || err "未知组件：${component}（仅支持 redis、rabbitmq、mongodb、mysql）"
    if [[ "${parsed_count}" -gt 0 ]]; then
      for parsed_component in "${parsed_components[@]}"; do
        [[ "${parsed_component}" == "${component}" ]] && continue 2
      done
    fi
    parsed_components+=("${component}")
    parsed_count=$((parsed_count + 1))
  done
  [[ "${#parsed_components[@]}" -gt 0 ]] || err "--components 必须至少指定一个组件"
  SELECTED_COMPONENTS=("${parsed_components[@]}")
  refresh_selected_topology
}

set_components_from() {
  local start_component="$1" component include=0
  component_is_valid "${start_component}" || err "未知组件：${start_component}（仅支持 redis、rabbitmq、mongodb、mysql）"
  SELECTED_COMPONENTS=()
  for component in "${ALL_COMPONENTS[@]}"; do
    [[ "${component}" == "${start_component}" ]] && include=1
    [[ "${include}" -eq 1 ]] && SELECTED_COMPONENTS+=("${component}")
  done
  refresh_selected_topology
}

refresh_selected_topology() {
  local component
  SELECTED_DB_IPS=()
  SELECTED_DB_HOSTNAMES=()
  for component in "${SELECTED_COMPONENTS[@]}"; do
    case "${component}" in
      redis)
        SELECTED_DB_IPS+=("${REDIS_IPS[@]}")
        SELECTED_DB_HOSTNAMES+=("${REDIS_HOSTNAMES[@]}")
        ;;
      rabbitmq)
        SELECTED_DB_IPS+=("${RABBITMQ_IPS[@]}")
        SELECTED_DB_HOSTNAMES+=("${RABBITMQ_HOSTNAMES[@]}")
        ;;
      mongodb)
        SELECTED_DB_IPS+=("${MONGODB_IPS[@]}")
        SELECTED_DB_HOSTNAMES+=("${MONGODB_HOSTNAMES[@]}")
        ;;
      mysql)
        SELECTED_DB_IPS+=("${MYSQL_IPS[@]}")
        SELECTED_DB_HOSTNAMES+=("${MYSQL_HOSTNAMES[@]}")
        ;;
    esac
  done
  SELECTED_COMPONENTS_CSV=$(IFS=,; printf '%s' "${SELECTED_COMPONENTS[*]}")
  SELECTED_HOST_PATTERN=$(IFS=:; printf '%s' "${SELECTED_COMPONENTS[*]}")
  SELECTED_LIMIT_PATTERN="${SELECTED_HOST_PATTERN}:localhost"
}

component_role_name() {
  case "$1" in
    redis) printf '%s' 'REDIS' ;;
    rabbitmq) printf '%s' 'RABBITMQ' ;;
    mongodb) printf '%s' 'MONGODB' ;;
    mysql) printf '%s' 'MYSQL' ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

component_topology_sha256() {
  local component="$1" role ips_var hostnames_var index
  role=$(component_role_name "${component}")
  ips_var="${role}_IPS[@]"
  hostnames_var="${role}_HOSTNAMES[@]"
  local -a ips=("${!ips_var}")
  local -a hostnames=("${!hostnames_var}")
  {
    printf 'component=%s\n' "${component}"
    for ((index = 0; index < ${#ips[@]}; index++)); do
      printf 'node.%s.ip=%s\n' "${index}" "${ips[${index}]}"
      printf 'node.%s.hostname=%s\n' "${index}" "${hostnames[${index}]}"
    done
  } | sha256_file /dev/stdin
}

record_component_state() {
  local component="$1" result="$2"
  local state_file topology_sha256 payload_manifest_sha256 script_sha256
  [[ -n "${STATE_OPERATION}" ]] || err "checkpoint 缺少操作类型"
  mkdir -p "${DELIVERY_STATE_DIR}"
  chmod 700 "${DELIVERY_STATE_DIR}"
  state_file="${DELIVERY_STATE_DIR}/${component}.${STATE_OPERATION}.${result}"
  rm -f -- "${DELIVERY_STATE_DIR}/${component}.${STATE_OPERATION}.verified" \
            "${DELIVERY_STATE_DIR}/${component}.${STATE_OPERATION}.failed"
  topology_sha256=$(component_topology_sha256 "${component}")
  payload_manifest_sha256=$(sha256_file "${SCRIPT_DIR}/../../sha256-packages.txt")
  script_sha256=$(sha256_file "${SCRIPT_DIR}/init_ansible.sh")
  {
    printf 'schema_version=2\n'
    printf 'component=%s\n' "${component}"
    printf 'operation=%s\n' "${STATE_OPERATION}"
    printf 'state=%s\n' "${result}"
    printf 'result=%s\n' "${result}"
    printf 'recorded_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'last_successful_stage=%s\n' "${LAST_SUCCESSFUL_STAGE:-none}"
    printf 'log_file=%s\n' "${LAST_SUCCESSFUL_LOG_FILE:-none}"
    printf 'topology_sha256=%s\n' "${topology_sha256}"
    printf 'payload_manifest_sha256=%s\n' "${payload_manifest_sha256}"
    printf 'script_sha256=%s\n' "${script_sha256}"
  } > "${state_file}"
  chmod 600 "${state_file}"
}

component_payload_version() {
  local component="$1" group_vars_file version erlang_version
  group_vars_file="${LOCAL_PLAYBOOK_DIR}/group_vars/${component}.yml"
  version=$(awk -F'"' '/^(redis|rabbitmq|mongodb|mysql)_version:/ { print $2; exit }' "${group_vars_file}")
  if [[ "${component}" == "rabbitmq" ]]; then
    erlang_version=$(awk -F'"' '/^erlang_version:/ { print $2; exit }' "${group_vars_file}")
    printf 'RabbitMQ %s / Erlang %s' "${version:-未知}" "${erlang_version:-未知}"
  else
    printf '%s %s' "${component}" "${version:-未知}"
  fi
}

show_deployment_plan() {
  local component ip hostname version index=0
  echo ""
  echo "本次部署计划："
  printf '  组件：%s\n' "${SELECTED_COMPONENTS[*]}"
  echo "  目标节点："
  for ip in "${SELECTED_DB_IPS[@]}"; do
    hostname="${SELECTED_DB_HOSTNAMES[${index}]}"
    printf '    - %s (%s)\n' "${hostname}" "${ip}"
    index=$((index + 1))
  done
  echo "  前置检查：执行"
  for component in "${ALL_COMPONENTS[@]}"; do
    if component_is_selected "${component}"; then
      version=$(component_payload_version "${component}")
      printf '  %-9s：部署并验证（载荷版本：%s）\n' "${component}" "${version}"
    else
      printf '  %-9s：跳过（不修改）\n' "${component}"
    fi
  done
  echo "  控制面写入：管理节点 /etc/hosts、/etc/ansible/hosts、/etc/ansible/group_vars"
  echo "  部署后终检：执行"
  echo "  数据保护：不会自动卸载、清空数据或回退已成功组件"
}

confirm_deployment_plan() {
  local answer
  if [[ "${AUTO_APPROVE}" -eq 1 ]]; then
    log "已通过 --yes 确认部署计划"
    return 0
  fi
  [[ -t 0 ]] || err "非交互部署必须显式传入 --yes；未执行任何远程操作"
  printf '确认按上述计划执行远程变更？[y/N] '
  read -r answer
  case "${answer}" in
    y|Y|yes|YES) ;;
    *) err "操作已取消；未执行任何远程操作" ;;
  esac
}

# ============================================================
# ── 安装阶段 ────────────────────────────────────────────────
# ============================================================

# Step 0: 校验随交付包携带的管理节点离线资产
step0_verify_offline_assets() {
  info "0" "校验随交付包携带的管理节点离线资产 → ${PKG_ROOT}"

  local required_files=(
    "${PKG_ROOT}/ansible/ansible-13.6.0-py3-none-any.whl"
    "${PKG_ROOT}/ansible/ansible_core-2.20.5-py3-none-any.whl"
    "${PKG_ROOT}/pip/pip-26.1-py3-none-any.whl"
    "${PKG_ROOT}/sshpass/sshpass_1.09-1_amd64.deb"
  )
  local asset
  for asset in "${required_files[@]}"; do
    [[ -f "${asset}" ]] || err "缺少随交付包提供的离线资产：${asset}；禁止现场下载补齐。"
  done

  local ansible_wheel_count
  ansible_wheel_count=$(find "${PKG_ROOT}/ansible" -maxdepth 1 -type f -name '*.whl' | wc -l | tr -d ' ')
  (( ansible_wheel_count >= 9 )) || \
    err "Ansible 离线 wheel 不完整（当前 ${ansible_wheel_count} 个，至少需要 9 个）；禁止现场下载补齐。"
  ok "管理节点离线资产完整（Ansible wheel: ${ansible_wheel_count} 个，pip 和 sshpass 已就绪）"
}

# Step 1: 远程设置管理节点主机名
step1_set_hostname() {
  info "1" "设置管理节点主机名 → ${ANSIBLE_NODE_HOSTNAME}"

  local current
  current=$(ssh_run "hostname" 2>/dev/null || echo "")
  if [[ "${current}" == "${ANSIBLE_NODE_HOSTNAME}" ]]; then
    ok "主机名已是 ${ANSIBLE_NODE_HOSTNAME}，跳过"
    return
  fi

  sudo_run "hostnamectl set-hostname $(printf '%q' "${ANSIBLE_NODE_HOSTNAME}")"

  local actual
  actual=$(ssh_run "hostname")
  [[ "${actual}" == "${ANSIBLE_NODE_HOSTNAME}" ]] || \
    err "主机名不符，期望 ${ANSIBLE_NODE_HOSTNAME}，实际 ${actual}"
  ok "主机名已设置为：${actual}"
}

# 比较本地与远端文件名和 SHA256，避免同名旧文件被数量检查误判为已同步。
asset_set_matches() {
  local local_dir="$1"
  local remote_dir="$2"
  local pattern="$3"
  local local_manifest remote_manifest

  local_manifest=$(find "${local_dir}" -maxdepth 1 -type f -name "${pattern}" \
    -exec shasum -a 256 {} \; |
    awk '{name=$NF; sub(".*/", "", name); print $1 "  " name}' | sort)
  remote_manifest=$(ssh_run "cd '${remote_dir}' && sha256sum ${pattern} 2>/dev/null" 2>/dev/null |
    sort || true)
  [[ -n "${local_manifest}" && "${local_manifest}" == "${remote_manifest}" ]]
}

# Step 2: 上传离线包到管理节点
step2_upload() {
  info "2" "上传离线包 → ${ANSIBLE_NODE_IP}:${REMOTE_PKG_DIR}"

  ssh_run "mkdir -p '${REMOTE_PKG_DIR}/ansible' '${REMOTE_PKG_DIR}/pip' '${REMOTE_PKG_DIR}/sshpass'"

  # ── ansible whl（幂等：文件名和 SHA256 完全一致才跳过）──────
  local local_whl
  local_whl=$(ls "${PKG_ROOT}/ansible/"*.whl 2>/dev/null | wc -l | tr -d ' ')
  if asset_set_matches "${PKG_ROOT}/ansible" "${REMOTE_PKG_DIR}/ansible" "*.whl"; then
    ok "ansible whl 已同步（文件名和 SHA256 一致），跳过上传"
  else
    log "上传 ansible wheel 包（${local_whl} 个）..."
    SSHPASS="${ANSIBLE_NODE_PASS}" sshpass -e \
      scp ${SSH_OPTS} "${PKG_ROOT}/ansible/"*.whl \
      "${REMOTE}:${REMOTE_PKG_DIR}/ansible/"
    ok "ansible whl 上传完成（${local_whl} 个）"
  fi

  # ── pip whl（幂等：文件名和 SHA256 完全一致才跳过）────────
  local local_pip
  local_pip=$(ls "${PKG_ROOT}/pip/"pip-*.whl 2>/dev/null | wc -l | tr -d ' ')
  if asset_set_matches "${PKG_ROOT}/pip" "${REMOTE_PKG_DIR}/pip" "pip-*.whl"; then
    ok "pip whl 已同步（文件名和 SHA256 一致），跳过上传"
  else
    log "上传 pip wheel..."
    SSHPASS="${ANSIBLE_NODE_PASS}" sshpass -e \
      scp ${SSH_OPTS} "${PKG_ROOT}/pip/"pip-*.whl \
      "${REMOTE}:${REMOTE_PKG_DIR}/pip/"
    ok "pip whl 上传完成"
  fi

  # ── sshpass deb（幂等）──────────────────────────────────────
  local remote_sshpass
  remote_sshpass=$(ssh_run "ls '${REMOTE_PKG_DIR}/sshpass/'sshpass_*.deb 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo 0)
  if [[ "${remote_sshpass}" -ge 1 ]]; then
    ok "sshpass .deb 已存在，跳过上传"
  else
    log "上传 sshpass .deb..."
    SSHPASS="${ANSIBLE_NODE_PASS}" sshpass -e \
      scp ${SSH_OPTS} "${PKG_ROOT}/sshpass/"sshpass_*.deb \
      "${REMOTE}:${REMOTE_PKG_DIR}/sshpass/"
    ok "sshpass .deb 上传完成"
  fi
}

# Step 2b: 上传 Playbook 目录到管理节点
step2b_upload_playbooks() {
  info "2b" "上传 Playbook 目录 → ${ANSIBLE_NODE_IP}:${REMOTE_PLAYBOOK_DIR}"

  [[ -d "${LOCAL_PLAYBOOK_DIR}" ]] || \
    err "本地 Playbook 目录不存在：${LOCAL_PLAYBOOK_DIR}"
  [[ -f "${LOCAL_PAYLOAD_VALIDATOR}" ]] || \
    err "本地正式载荷校验器不存在：${LOCAL_PAYLOAD_VALIDATOR}"

  ssh_run "mkdir -p '${REMOTE_PLAYBOOK_DIR}'"

  # 上传目录内容（每次覆盖，确保远端与本地同步）
  scp_run -r "${LOCAL_PLAYBOOK_DIR}/." \
    "${REMOTE}:${REMOTE_PLAYBOOK_DIR}/"
  scp_run "${LOCAL_PAYLOAD_VALIDATOR}" \
    "${REMOTE}:${REMOTE_PAYLOAD_VALIDATOR}"

  ssh_run "test -f '${REMOTE_PLAYBOOK_DIR}/preflights/00_preflight.yml' && \
           test -f '${REMOTE_PLAYBOOK_DIR}/preflights/01_server_init.yml' && \
           test -f '${REMOTE_PLAYBOOK_DIR}/site/site.yml'" || \
    err "远端 Playbook 目录不完整：${REMOTE_PLAYBOOK_DIR} 缺少 preflights 或 site 入口文件"

  local count
  count=$(ssh_run "find '${REMOTE_PLAYBOOK_DIR}' -name '*.yml' | wc -l | tr -d ' '")
  ok "上传完成（${count} 个 .yml 和正式载荷校验器，目标：${REMOTE_PLAYBOOK_DIR}）"

  # 将 group_vars 同步到 /etc/ansible/group_vars/，确保所有子目录 playbook 都能找到变量
  if ssh_run "test -d '${REMOTE_PLAYBOOK_DIR}/group_vars'" 2>/dev/null; then
    sudo_script_run "$(cat <<EOF
set -e
mkdir -p /etc/ansible/group_vars
cp '${REMOTE_PLAYBOOK_DIR}/group_vars/'*.yml /etc/ansible/group_vars/
chown root:${ANSIBLE_NODE_USER} /etc/ansible/group_vars/*.yml
chmod 0640 /etc/ansible/group_vars/*.yml
source_files=\$(find '${REMOTE_PLAYBOOK_DIR}/group_vars' -maxdepth 1 -type f -name '*.yml' -exec basename {} \\; | sort)
target_files=\$(find /etc/ansible/group_vars -maxdepth 1 -type f -name '*.yml' -exec basename {} \\; | sort)
test "\${source_files}" = "\${target_files}"
test -z "\$(find /etc/ansible/group_vars -maxdepth 1 -type f \( ! -user root -o ! -group ${ANSIBLE_NODE_USER} \))"
test -z "\$(find /etc/ansible/group_vars -maxdepth 1 -type f -name '*.yml' ! -perm 0640)"
EOF
)"
    ok "group_vars → /etc/ansible/group_vars/ 同步完成"
  fi
}

# Step 2c: 上传 DB 离线包（redis / rabbitmq / mongodb / mysql）
step2c_upload_db_packages() {
  info "2c" "上传 DB 离线包 → ${ANSIBLE_NODE_IP}:${REMOTE_PKG_DIR}"

  [[ -d "${LOCAL_DB_PKG_DIR}" ]] || \
    err "DB 离线包目录不存在：${LOCAL_DB_PKG_DIR}"

  local sshpass_file="$(mktemp "${TMPDIR:-/tmp}/ecopilot-sshpass.XXXXXX")"
  chmod 600 "${sshpass_file}"
  printf '%s\n' "${ANSIBLE_NODE_PASS}" > "${sshpass_file}"
  trap 'rm -f -- "${sshpass_file:-}"' RETURN

  for db in "${ALL_COMPONENTS[@]}"; do
    component_is_selected "${db}" || continue
    local src="${LOCAL_DB_PKG_DIR}/${db}"
    local dst="${REMOTE_PKG_DIR}/${db}"

    [[ -d "${src}" ]] || err "本地 ${db} 正式包目录不存在：${src}"

      ssh_run "mkdir -p '${dst}' && test -d '${dst}'" || \
        err "管理节点离线包目录创建失败：${dst}"
    rsync -a --delete \
        --rsync-path="mkdir -p '${dst}' && exec rsync" \
      -e "sshpass -f ${sshpass_file} ssh ${SSH_OPTS}" \
      "${src}/" "${REMOTE}:${dst}/"
    local package_count
    package_count=$(find "${src}" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')
    ok "${db}：已镜像同步 ${package_count} 个 .deb → ${dst}"
  done

  rm -f -- "${sshpass_file}"
  trap - RETURN
  ok "DB 正式包目录镜像同步完成"
}

# Step 3: 在管理节点上安装 Ansible + sshpass
step3_install() {
  info "3" "在管理节点上安装 Ansible + sshpass"

  # 仅展开非敏感路径；sudo 密码由 sudo_script_run 通过 stdin 传递。
  # 注意：不做"已安装跳过"的幂等检查。
  # 原因：pip "Requirement already satisfied" 会跳过写操作（含 console_scripts），
  # 若 Python 包已在 dist-packages 但 /usr/local/bin/ansible 不存在，
  # pip 不报错也不重建 binary，导致后续所有步骤失败。
  # 解决：始终带 --force-reinstall --no-deps，强制重建 console_scripts。
  sudo_script_run "$(cat <<EOF
# 安装 sshpass（幂等）
if ! command -v sshpass &>/dev/null; then
  dpkg -i ${REMOTE_PKG_DIR}/sshpass/sshpass_*.deb
fi

# 安装 Ansible（借用 pip whl 内置 pip，pip 本身不装到系统）。
# 已有可用命令时跳过重装，避免重复卸载管理节点上正在工作的 Ansible。
if ! command -v ansible-playbook &>/dev/null; then
  PIP_WHL=\$(ls ${REMOTE_PKG_DIR}/pip/pip-*.whl | head -1)
  python3 "\${PIP_WHL}/pip" install \
    --no-index \
    --find-links ${REMOTE_PKG_DIR}/ansible \
    --force-reinstall \
    --no-deps \
    ansible ansible-core \
    --break-system-packages
else
  echo "Ansible 已安装，跳过离线重装"
fi
EOF
)"

  local ver
  ver=$(ssh_run "ansible --version | head -1") || true
  if [[ -z "${ver}" ]]; then
    err "Step 3 安装后 ansible 命令仍不可用，请检查 /usr/local/bin/ 或 pip 日志"
  fi
  ok "安装完成：${ver}"
}

# Step 3b: 配置管理节点 NOPASSWD sudo（确保后续步骤无需交互式密码）
step3b_nopasswd_ansible_node() {
  info "3b" "配置管理节点 NOPASSWD sudo"

  sudo_script_run "$(cat <<EOF
if grep -q '^${ANSIBLE_NODE_USER} ALL=(ALL) NOPASSWD: ALL$' '${DEPLOY_SUDOERS_FILE}' 2>/dev/null; then
  echo "  ✔ 已配置，跳过"
else
  printf '%s\n' '${ANSIBLE_NODE_USER} ALL=(ALL) NOPASSWD: ALL' > '${DEPLOY_SUDOERS_FILE}'
  chmod 440 '${DEPLOY_SUDOERS_FILE}'
  visudo -cf '${DEPLOY_SUDOERS_FILE}'
  echo "  ✔ 配置完成（权限 440）"
fi
EOF
)"
  ok "管理节点 NOPASSWD sudo 已就绪"
}

# ============================================================
# ── 配置阶段 ────────────────────────────────────────────────
# ============================================================

# Step 4: 在管理节点生成 SSH 密钥对
step4_keygen() {
  info "4" "生成 SSH 密钥对（管理节点 ~/.ssh/id_rsa）"

  # 幂等：密钥已存在则跳过（不覆盖，避免破坏已有免密 SSH 关系）
  if ssh_run "test -f ~/.ssh/id_rsa" 2>/dev/null; then
    ok "~/.ssh/id_rsa 已存在，跳过"
    return
  fi

  ssh_run "ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ''"
  ok "密钥对已生成：~/.ssh/id_rsa"
}

# Step 5: 分发公钥到选中 DB 服务器（建立免密 SSH）
step5_distribute_pubkey() {
  info "5" "分发公钥到 DB 服务器（${#SELECTED_DB_IPS[@]} 台）"

  # 拓扑和账号在本地展开；数据库密码通过管理节点脚本 stdin 传递。
  remote_secret_script_run "${DB_PASS}" "$(cat <<EOF
total_ok=0; total_skip=0; total_fail=0
for ip in ${SELECTED_DB_IPS[*]}; do
  if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
       ${DB_USER}@\${ip} true 2>/dev/null; then
    echo "  ✔ \${ip} 已有免密 SSH，跳过"
    total_skip=\$((total_skip+1))
  else
    if SSHPASS="\${ECOPILOT_SECRET}" sshpass -e \
         ssh-copy-id -o StrictHostKeyChecking=no \
         -i ~/.ssh/id_rsa.pub ${DB_USER}@\${ip} >/dev/null 2>&1; then
      echo "  ✔ \${ip} 公钥已分发"
      total_ok=\$((total_ok+1))
    else
      echo "  ✘ \${ip} 分发失败" >&2
      total_fail=\$((total_fail+1))
    fi
  fi
done
echo "  → 完成：新增 \${total_ok}，跳过 \${total_skip}，失败 \${total_fail}"
[ "\${total_fail}" -eq 0 ] || exit 1
EOF
  )"
  ok "公钥分发完成（免密 SSH 已建立）"
}

# Step 6: 配置 DB 服务器 NOPASSWD sudo
step6_nopasswd_sudo() {
  info "6" "配置 DB 服务器 NOPASSWD sudo（${#SELECTED_DB_IPS[@]} 台）"

  remote_secret_script_run "${DB_PASS}" "$(cat <<EOF
total_ok=0; total_skip=0; total_fail=0
for ip in ${SELECTED_DB_IPS[*]}; do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${DB_USER}@\${ip} \
      "grep -q '^${DB_USER} ALL=(ALL) NOPASSWD: ALL$' '${DB_SUDOERS_FILE}' 2>/dev/null" 2>/dev/null; then
    echo "  ✔ \${ip} 已配置 NOPASSWD sudo，跳过"
    total_skip=\$((total_skip+1))
  else
        if printf '%s\n' "\${ECOPILOT_SECRET}" | \
          ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${DB_USER}@\${ip} \
          "sudo -S -p '' bash -c \"printf '%s\\n' '${DB_USER} ALL=(ALL) NOPASSWD: ALL' > '${DB_SUDOERS_FILE}' && chmod 440 '${DB_SUDOERS_FILE}' && visudo -cf '${DB_SUDOERS_FILE}'\"" 2>&1; then
      echo "  ✔ \${ip} sudo 已配置（权限 440）"
      total_ok=\$((total_ok+1))
    else
      echo "  ✘ \${ip} 配置失败" >&2
      total_fail=\$((total_fail+1))
    fi
  fi
done
echo "  → 完成：新增 \${total_ok}，跳过 \${total_skip}，失败 \${total_fail}"
[ "\${total_fail}" -eq 0 ] || exit 1
EOF
  )"
  ok "NOPASSWD sudo 配置完成"
}

# Step 6b: 设置 DB 服务器主机名 & 更新管理节点 /etc/hosts
step6b_configure_hosts() {
  info "6b" "设置 DB 服务器主机名 & 更新管理节点 /etc/hosts"

  # ── 1. 逐台设置主机名（SSH → sudo hostnamectl，幂等）──
  ssh_run "bash -s" <<EOF
set -euo pipefail
ips=(${SELECTED_DB_IPS[*]})
hostnames=(${SELECTED_DB_HOSTNAMES[*]})
total_ok=0; total_skip=0; total_fail=0
for i in "\${!ips[@]}"; do
  ip="\${ips[\$i]}"
  hn="\${hostnames[\$i]}"
  current=\$(ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 \\
               ${DB_USER}@\${ip} "hostname" 2>/dev/null || echo "")
  if [[ "\${current}" == "\${hn}" ]]; then
    echo "  ✔ \${ip} 主机名已是 \${hn}，跳过"
    total_skip=\$((total_skip+1))
  else
        if ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 \\
          ${DB_USER}@\${ip} "sudo -n hostnamectl set-hostname '\${hn}'" 2>&1; then
      echo "  ✔ \${ip} → \${hn}"
      total_ok=\$((total_ok+1))
    else
      echo "  ✘ \${ip} 主机名设置失败" >&2
      total_fail=\$((total_fail+1))
    fi
  fi
done
  echo "  → 完成：新增 \${total_ok}，跳过 \${total_skip}，失败 \${total_fail}"
[ "\${total_fail}" -eq 0 ] || exit 1

EOF
  sync_control_plane_blocks
  ok "DB 主机名和管理节点 /etc/hosts 配置完成"
}

component_ips() {
  local component="$1" role ips_var
  role=$(component_role_name "${component}")
  ips_var="${role}_IPS[@]"
  printf '%s\n' "${!ips_var}"
}

component_hostnames() {
  local component="$1" role hostnames_var
  role=$(component_role_name "${component}")
  hostnames_var="${role}_HOSTNAMES[@]"
  printf '%s\n' "${!hostnames_var}"
}

sync_control_plane_blocks() {
  local component index hosts_fragment inventory_fragment fragments_dir
  fragments_dir=$(mktemp -d "${TMPDIR:-/tmp}/ecopilot-control-plane.XXXXXX")
  chmod 700 "${fragments_dir}"
  for component in "${SELECTED_COMPONENTS[@]}"; do
    hosts_fragment="${fragments_dir}/hosts-${component}"
    inventory_fragment="${fragments_dir}/inventory-${component}"
    {
      printf '# BEGIN ECOPILOT_COMPONENT %s\n' "${component}"
      while IFS= read -r ip && IFS= read -r hostname <&3; do
        printf '%-16s %s\n' "${ip}" "${hostname}"
      done < <(component_ips "${component}") 3< <(component_hostnames "${component}")
      printf '# END ECOPILOT_COMPONENT %s\n' "${component}"
    } > "${hosts_fragment}"
    {
      printf '# BEGIN ECOPILOT_COMPONENT %s\n' "${component}"
      printf '[%s]\n' "${component}"
      component_ips "${component}"
      printf '# END ECOPILOT_COMPONENT %s\n' "${component}"
    } > "${inventory_fragment}"
  done
  ssh_run "rm -rf /tmp/ecopilot-control-plane"
  scp_run -r "${fragments_dir}" "${REMOTE}:/tmp/ecopilot-control-plane"
  rm -rf -- "${fragments_dir}"
  ssh_run "sudo -n bash -s -- '${SELECTED_COMPONENTS[*]}' '${#SELECTED_COMPONENTS[@]}'" <<'REMOTE'
set -euo pipefail
selected="$1"
selected_count="$2"
fragments_dir=/tmp/ecopilot-control-plane
components='redis rabbitmq mongodb mysql'
merge_blocks() {
  target="$1" kind="$2" candidate="$3"
  if grep -q '^# BEGIN DB_CLUSTER_HOSTS$' "$target" 2>/dev/null; then
    if [[ "$selected_count" -ne 4 ]]; then
      echo "检测到旧版全局受管 hosts 块；请使用完整四组件拓扑执行一次迁移，局部操作已停止" >&2
      exit 1
    fi
    awk '/^# BEGIN DB_CLUSTER_HOSTS$/ { skip=1; next } /^# END DB_CLUSTER_HOSTS$/ { skip=0; next } !skip { print }' "$target" > "$candidate"
  else
    cp "$target" "$candidate" 2>/dev/null || : > "$candidate"
  fi
  if [[ "$kind" == inventory ]] && grep -Eq '^\[(redis|rabbitmq|mongodb|mysql)\]$' "$target" 2>/dev/null && ! grep -q '^# BEGIN ECOPILOT_COMPONENT ' "$target"; then
    if [[ "$selected_count" -ne 4 ]]; then
      echo "检测到旧版未归属 inventory；请使用完整四组件拓扑执行一次迁移，局部操作已停止" >&2
      exit 1
    fi
    awk '
      /^\[(redis|rabbitmq|mongodb|mysql|db_all:children)\]$/ { skip=1; next }
      /^\[/ { skip=0 }
      !skip { print }
    ' "$target" > "$candidate"
  fi
  for component in $selected; do
    fragment="$fragments_dir/$kind-$component"
    next="$candidate.next"
    awk -v component="$component" -v fragment="$fragment" '
      $0 == "# BEGIN ECOPILOT_COMPONENT " component { while ((getline line < fragment) > 0) print line; close(fragment); skip=1; found=1; next }
      $0 == "# END ECOPILOT_COMPONENT " component { skip=0; next }
      !skip { print }
      END { if (!found) { while ((getline line < fragment) > 0) print line; close(fragment) } }
    ' "$candidate" > "$next"
    mv "$next" "$candidate"
  done
}
validate_markers() {
  file="$1"
  awk '
    /^# BEGIN ECOPILOT_COMPONENT (redis|rabbitmq|mongodb|mysql)$/ { component=$4; if (++begin[component] != 1) exit 1; open=component; next }
    /^# END ECOPILOT_COMPONENT (redis|rabbitmq|mongodb|mysql)$/ { if (open != $4) exit 1; end[$4]++; open="" }
    END { if (open != "") exit 1; for (component in begin) if (begin[component] != end[component]) exit 1 }
  ' "$file"
}
validate_hosts() {
  awk '
    /^# BEGIN ECOPILOT_COMPONENT / { inside=1; next }
    /^# END ECOPILOT_COMPONENT / { inside=0; next }
    inside && NF >= 2 { if (ip[$1]++ || hostname[$2]++) exit 1 }
  ' "$1"
}
merge_blocks /etc/hosts hosts /tmp/ecopilot-hosts.candidate
merge_blocks /etc/ansible/hosts inventory /tmp/ecopilot-inventory.candidate
validate_markers /tmp/ecopilot-hosts.candidate
validate_markers /tmp/ecopilot-inventory.candidate
validate_hosts /tmp/ecopilot-hosts.candidate
{
  printf '[db_all:children]\n'
  awk '/^# BEGIN ECOPILOT_COMPONENT / { print $4 }' /tmp/ecopilot-inventory.candidate
} > /tmp/ecopilot-inventory.groups
awk '/^\[db_all:children\]$/ { skip=1; next } !skip { print }' /tmp/ecopilot-inventory.candidate > /tmp/ecopilot-inventory.base
cat /tmp/ecopilot-inventory.base /tmp/ecopilot-inventory.groups > /tmp/ecopilot-inventory.final
ansible-inventory -i /tmp/ecopilot-inventory.final --graph >/dev/null
diff -u /etc/hosts /tmp/ecopilot-hosts.candidate || true
diff -u /etc/ansible/hosts /tmp/ecopilot-inventory.final || true
hosts_destination=$(mktemp /etc/.ecopilot-hosts.XXXXXX)
mkdir -p /etc/ansible
inventory_destination=$(mktemp /etc/ansible/.ecopilot-inventory.XXXXXX)
install -m 0644 -o root -g root /tmp/ecopilot-hosts.candidate "$hosts_destination"
mv -f "$hosts_destination" /etc/hosts
install -m 0644 -o root -g root /tmp/ecopilot-inventory.final "$inventory_destination"
mv -f "$inventory_destination" /etc/ansible/hosts
rm -rf "$fragments_dir" /tmp/ecopilot-hosts.candidate /tmp/ecopilot-inventory.candidate /tmp/ecopilot-inventory.groups /tmp/ecopilot-inventory.base /tmp/ecopilot-inventory.final
REMOTE
  ok "组件归属 hosts 与 Inventory 块已通过候选校验并原子更新"
}

# Step 7: hosts 与 Ansible Inventory 由 Step 6b 一并以组件块合并。
step7_inventory() {
  info "7" "复核组件归属 Ansible Inventory"
  ssh_run "ansible-inventory -i /etc/ansible/hosts --graph >/dev/null"
  ok "Inventory 解析通过"
}

# Step 7b: 将 group_vars 复制到 /etc/ansible/group_vars/（让子目录 playbook 也能加载变量）
step7b_group_vars() {
  info "7b" "同步 group_vars → /etc/ansible/group_vars"

  ssh_run "set -e
           sudo mkdir -p /etc/ansible/group_vars
           sudo cp '${REMOTE_PLAYBOOK_DIR}/group_vars/'*.yml /etc/ansible/group_vars/
           sudo chown root:${ANSIBLE_NODE_USER} /etc/ansible/group_vars/*.yml
           sudo chmod 0640 /etc/ansible/group_vars/*.yml
           source_files=\$(find '${REMOTE_PLAYBOOK_DIR}/group_vars' -maxdepth 1 -type f -name '*.yml' -exec basename {} \\; | sort)
           target_files=\$(sudo find /etc/ansible/group_vars -maxdepth 1 -type f -name '*.yml' -exec basename {} \\; | sort)
           test \"\${source_files}\" = \"\${target_files}\"
           test -z \"\$(sudo find /etc/ansible/group_vars -maxdepth 1 -type f \( ! -user root -o ! -group ${ANSIBLE_NODE_USER} \))\"
           test -z \"\$(sudo find /etc/ansible/group_vars -maxdepth 1 -type f -name '*.yml' ! -perm 0640)\""
  ok "group_vars 已同步并通过 root:${ANSIBLE_NODE_USER}/0640 权限校验"
}

# Step 8: 写入 ansible.cfg
step8_ansible_cfg() {
  info "8" "写入 /etc/ansible/ansible.cfg"

  ssh_run "bash -s" <<REMOTE
sudo bash -c 'printf "[defaults]\ninventory = /etc/ansible/hosts\nhost_key_checking = False\nremote_user = ${ANSIBLE_NODE_USER}\nprivate_key_file = /home/${ANSIBLE_NODE_USER}/.ssh/id_rsa\n\n[privilege_escalation]\nbecome = True\nbecome_method = sudo\nbecome_user = root\nbecome_ask_pass = False\n" > /etc/ansible/ansible.cfg && chown root:root /etc/ansible/ansible.cfg && chmod 0644 /etc/ansible/ansible.cfg'
REMOTE
  ok "ansible.cfg 已写入"
}

# Step 9: 连通性验证（ansible 选中组件 -m ping）
step9_ping() {
  info "9" "连通性验证（ansible ${SELECTED_HOST_PATTERN} -m ping）"

  local result
  result=$(ssh_run "ansible '${SELECTED_HOST_PATTERN}' -m ping 2>&1" || true)
  echo "${result}" | sed 's/^/  /'

  local success_count total
  success_count=$(echo "${result}" | grep -c '| SUCCESS' || true)
  total=${#SELECTED_DB_IPS[@]}

  if [[ "${success_count}" -eq "${total}" ]]; then
    ok "全部通过：${success_count}/${total} 台"
  else
    warn "部分失败：${success_count}/${total} 台通过，请检查以上输出"
    err "连通性验证未全部通过"
  fi
}

# Step -1: 配置模板门禁（必须在任何远程操作前执行）
validate_configuration() {
  local config_file="${CONFIG_FILE}"
  local group_vars_dir="${LOCAL_PLAYBOOK_DIR}/group_vars"
  local component role ips_var hostnames_var group_vars_file value

  [[ -f "${config_file}" ]] || err "配置文件不存在：${config_file}"
  [[ -d "${group_vars_dir}" ]] || err "group_vars 目录不存在：${group_vars_dir}"

  for value in "${ANSIBLE_NODE_IP}" "${ANSIBLE_NODE_USER}" "${ANSIBLE_NODE_PASS}" "${ANSIBLE_NODE_HOSTNAME}" "${DB_USER}" "${DB_PASS}"; do
    [[ -n "${value}" && "${value}" != *CHANGE_ME* ]] ||
      err "管理节点或数据库 SSH 配置仍包含 CHANGE_ME 或空值"
  done

  for component in "${SELECTED_COMPONENTS[@]}"; do
    role=$(component_role_name "${component}")
    ips_var="${role}_IPS[@]"
    hostnames_var="${role}_HOSTNAMES[@]"
    local -a ips=("${!ips_var}")
    local -a hostnames=("${!hostnames_var}")
    [[ "${#ips[@]}" -eq 3 && "${#hostnames[@]}" -eq 3 ]] ||
      err "${role} 必须配置 3 个 IP 和 3 个主机名，当前为 ${#ips[@]} 个 IP、${#hostnames[@]} 个主机名"
    for value in "${ips[@]}" "${hostnames[@]}"; do
      [[ -n "${value}" && "${value}" != *CHANGE_ME* ]] ||
        err "${role} 节点配置仍包含 CHANGE_ME 或空值"
    done
    group_vars_file="${group_vars_dir}/${component}.yml"
    [[ -f "${group_vars_file}" ]] || err "缺少 ${component} 组件变量文件：${group_vars_file}"
    ! grep -q 'CHANGE_ME' "${group_vars_file}" ||
      err "${component} 组件变量文件仍包含 CHANGE_ME：${group_vars_file}"
  done

  local duplicate_ip duplicate_hostname
  duplicate_ip=$(printf '%s\n' "${SELECTED_DB_IPS[@]}" | sort | uniq -d | head -n 1)
  [[ -z "${duplicate_ip}" ]] || err "数据库节点存在重复 IP：${duplicate_ip}"
  duplicate_hostname=$(printf '%s\n' "${SELECTED_DB_HOSTNAMES[@]}" | sort | uniq -d | head -n 1)
  [[ -z "${duplicate_hostname}" ]] || err "数据库节点存在重复主机名：${duplicate_hostname}"

  ok "配置门禁通过（${SELECTED_COMPONENTS_CSV}，${#SELECTED_DB_IPS[@]} 台节点）"
}

validate_delivery_assets() {
  [[ -f "${LOCAL_DELIVERY_VERIFIER}" ]] ||
    err "统一交付校验器不存在：${LOCAL_DELIVERY_VERIFIER}"
  DELIVERY_PLAYBOOK_DIR="${LOCAL_PLAYBOOK_DIR}" \
    /bin/bash "${LOCAL_DELIVERY_VERIFIER}" ||
    err "统一交付校验失败；未执行任何远程操作"
}

# ============================================================
# 主流程
# ============================================================
main() {
  refresh_selected_topology
  echo "=================================================="
  echo " Ansible 管理节点完整初始化"
  echo " 目标：${REMOTE}  (${ANSIBLE_NODE_HOSTNAME})"
  echo " DB 服务器：${#SELECTED_DB_IPS[@]} 台"
  echo "=================================================="

  validate_configuration
  validate_delivery_assets

  log "检查本机连接工具..."
  ensure_local_tools
  ok "连接工具就绪（ssh / sshpass / scp / rsync）"

  echo ""
  echo "── 安装阶段 ──────────────────────────────────────"
  step0_verify_offline_assets
  step1_set_hostname
  step2_upload
  step2b_upload_playbooks
  step2c_upload_db_packages
  step3_install
  step3b_nopasswd_ansible_node

  echo ""
  echo "── 配置阶段 ──────────────────────────────────────"
  step4_keygen
  step5_distribute_pubkey
  step6_nopasswd_sudo
  step6b_configure_hosts
  step7_inventory
  step8_ansible_cfg
  step9_ping

  echo ""
  echo "=================================================="
  echo " 全部完成！Ansible 已就绪。"
  echo " 后续：运行一键部署（含进度显示）："
  echo "   bash init_ansible.sh deploy"
  echo "=================================================="
}

# ============================================================
# 一键部署全流程（含实时进度显示）
# 用法：bash init_ansible.sh deploy
# ============================================================

# 在远程 Ansible 节点上执行 playbook；默认只显示任务级进度，--verbose 显示完整输出。
_run_playbook_stage() {
  local stage="$1"          # 阶段名称（用于显示）
  local tags="$2"           # --tags 参数，preflight 不传 tags 时留空
  local playbook="$3"       # 远程 playbook 路径

  local t0; t0=$(date +%s)
  echo ""
  echo "┌─────────────────────────────────────────────────"
  printf "│ ▶ 阶段：%-38s│\n" "${stage}"
  printf "│   开始：%-38s│\n" "$(date '+%H:%M:%S')"
  echo "└─────────────────────────────────────────────────"

  local cmd="ansible-playbook ${playbook} --limit '${SELECTED_LIMIT_PATTERN}' --extra-vars 'selected_components=${SELECTED_COMPONENTS_CSV}'"
  [[ -n "${tags}" ]] && cmd="${cmd} --tags ${tags}"

  mkdir -p "${DELIVERY_LOG_DIR}"
  chmod 700 "${DELIVERY_LOG_DIR}"

  # 日志从阶段开始就落盘，现场可在另一终端实时 tail -f 查看。
  local log_file="${DELIVERY_LOG_DIR}/deploy-$(date '+%Y%m%d-%H%M%S')-${stage//[^A-Za-z0-9._-]/_}.log"
  : > "${log_file}"
  chmod 600 "${log_file}"
  printf '  实时日志：%s\n' "${log_file}"

  # 远端命令后台执行；仅对 SSH 连接错误 255 重试，避免重跑已启动的 Playbook。
  (
    local attempt rc
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      if ! SSHPASS="${ANSIBLE_NODE_PASS}" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o LogLevel=ERROR \
        "${REMOTE}" true; then
        rc=255
      else
        SSHPASS="${ANSIBLE_NODE_PASS}" sshpass -e ssh \
          -o StrictHostKeyChecking=no \
          -o LogLevel=ERROR \
          "${REMOTE}" \
          "ANSIBLE_FORCE_COLOR=0 ${cmd}"
        rc=$?
      fi
      [[ "${rc}" -ne 255 ]] && exit "${rc}"
      [[ "${attempt}" -lt 10 ]] && sleep 5
    done
    exit "${rc}"
  ) >"${log_file}" 2>&1 &
  local ssh_pid=$!

  while kill -0 "${ssh_pid}" 2>/dev/null; do
    local elapsed_now=$(( $(date +%s) - t0 ))
    printf "\033[2m  … ${stage} 仍在执行，已耗时 %dm%02ds（最近输出持续写入中）\033[0m\n" \
      "$(( elapsed_now / 60 ))" "$(( elapsed_now % 60 ))"
    sleep 15
  done

  local rc=0
  wait "${ssh_pid}" || rc=$?
  local elapsed=$(( $(date +%s) - t0 ))
  local mm=$(( elapsed / 60 ))
  local ss=$(( elapsed % 60 ))

  if [[ ${rc} -eq 0 ]]; then
    LAST_SUCCESSFUL_STAGE="${stage}"
    LAST_SUCCESSFUL_LOG_FILE="${log_file}"
    if [[ "${VERBOSE}" -eq 1 ]]; then
      sed 's/^/  /' "${log_file}"
    else
      grep -E '^(PLAY |TASK |PLAY RECAP|fatal:|UNREACHABLE|.*failed:|.*failed=)' "${log_file}" || true
    fi
    echo ""
    ok "阶段完成：${stage}  耗时 ${mm}m${ss}s"
  else
    echo ""
    printf '\033[0;31m  ✘ 阶段失败：%s（exit=%s）\033[0m\n' "${stage}" "${rc}"
    printf '  完整日志：%s\n' "${log_file}"
    printf '  失败摘要：\n'
    grep -E 'fatal:|UNREACHABLE|failed:|PLAY RECAP' "${log_file}" | tail -n 12 || true
    return "${rc}"
  fi
}

deploy_all() {
  local TOTAL_T0; TOTAL_T0=$(date +%s)
  STATE_OPERATION="deploy"

  echo ""
  echo "=================================================="
  echo " 🚀 全流程自动化部署"
  echo "    目标节点：${REMOTE}"
  echo "    时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "=================================================="

  show_deployment_plan
  confirm_deployment_plan

  # Step 0-9: Ansible 管理节点初始化（幂等，已完成则秒过）
  echo ""
  echo "┌─────────────────────────────────────────────────"
  echo "│ ▶ 阶段：Ansible 管理节点初始化（Step 0-9）      │"
  echo "└─────────────────────────────────────────────────"
  local t0; t0=$(date +%s)
  main  # 调用初始化主流程（幂等）
  local elapsed=$(( $(date +%s) - t0 ))
  ok "初始化完成  耗时 $(( elapsed/60 ))m$(( elapsed%60 ))s"

  # Preflight
  _run_playbook_stage \
    "Preflight（服务器预检 + 初始化）" \
    "" \
    "~/playbooks/preflights/00_preflight.yml ~/playbooks/preflights/01_server_init.yml"

  if component_is_selected redis; then
    if _run_playbook_stage "Redis 8.2.8 主从 + Sentinel" "redis" "~/playbooks/site/site.yml"; then
      record_component_state redis verified
    else
      record_component_state redis failed
      return 1
    fi
  fi

  # RabbitMQ（目标载荷为 RabbitMQ 4.2.9 + Erlang 27.3.4.16）
  if component_is_selected rabbitmq; then
    echo ""
    warn "RabbitMQ 阶段：需安装 RabbitMQ 4.2.9 + Erlang 27.3.4.16，请耐心等待..."
    if _run_playbook_stage "RabbitMQ 4.2.9 集群" "rabbitmq" "~/playbooks/site/site.yml"; then
      record_component_state rabbitmq verified
    else
      record_component_state rabbitmq failed
      return 1
    fi
  fi

  if component_is_selected mongodb; then
    if _run_playbook_stage "MongoDB 8.2.12 副本集" "mongodb" "~/playbooks/site/site.yml"; then
      record_component_state mongodb verified
    else
      record_component_state mongodb failed
      return 1
    fi
  fi

  # MySQL（离线 .deb 安装 + 串行初始化）
  if component_is_selected mysql; then
    echo ""
    warn "MySQL 阶段：离线 .deb 安装并串行初始化数据目录，请耐心等待..."
    if _run_playbook_stage "MySQL 8.4.11 GTID 主从 + Keepalived VIP" "mysql" "~/playbooks/site/site.yml"; then
      record_component_state mysql verified
    else
      record_component_state mysql failed
      return 1
    fi
  fi

  _run_playbook_stage \
    "部署后终检（dpkg 审计）" \
    "" \
    "~/playbooks/preflights/02_postflight.yml"

  local total_elapsed=$(( $(date +%s) - TOTAL_T0 ))
  local tmm=$(( total_elapsed / 60 ))
  local tss=$(( total_elapsed % 60 ))

  echo ""
  echo "=================================================="
  echo " ✅ 全流程部署完成！"
  printf "    总耗时：%dm%ds\n" "${tmm}" "${tss}"
  echo "    时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "=================================================="
  echo " 快速验证命令："
  echo "   Redis   : ssh ${ANSIBLE_NODE_IP} 'ansible redis -m shell -a \"redis-cli info replication\"'"
  echo "   RabbitMQ: ssh ${ANSIBLE_NODE_IP} 'ansible rabbitmq -m shell -a \"rabbitmqctl cluster_status\"'"
  echo "   MongoDB : ssh ${ANSIBLE_NODE_IP} 'ansible mongodb -m shell -a \"mongosh --quiet --eval \\\"rs.status().ok\\\"\"'"
  echo "   MySQL   : ssh ${ANSIBLE_NODE_IP} 'ansible mysql -m shell -a \"mysql -uroot -e \\\"SHOW MASTER STATUS\\G\\\"\"'"
  echo "=================================================="
}

verify_selected_components() {
  local component
  STATE_OPERATION="verify"

  echo ""
  echo "=================================================="
  echo " 组件只读验证"
  printf "  组件：%s\n" "${SELECTED_COMPONENTS[*]}"
  echo "  不执行安装、配置、重建或数据清理"
  echo "=================================================="

  refresh_selected_topology
  validate_configuration
  validate_delivery_assets

  _run_playbook_stage \
    "Preflight（选中节点与离线载荷）" \
    "preflight" \
    "~/playbooks/preflights/00_preflight.yml"

  for component in "${SELECTED_COMPONENTS[@]}"; do
    if _run_playbook_stage "${component} 运行状态验证" "${component}-verify" "~/playbooks/site/site.yml"; then
      record_component_state "${component}" verified
    else
      record_component_state "${component}" failed
      return 1
    fi
  done

  _run_playbook_stage \
    "部署后终检（选中节点 dpkg 审计）" \
    "postflight" \
    "~/playbooks/preflights/02_postflight.yml"

  ok "所选组件的只读验证通过"
}

# ============================================================
# 入口路由
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
case "${1:-}" in
  deploy)
    # 加载配置后执行全流程部署
    shift
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --verbose) VERBOSE=1 ;;
        --yes) AUTO_APPROVE=1 ;;
        --components)
          [[ "$#" -ge 2 ]] || err "--components 缺少组件列表"
          set_selected_components "$2"
          shift
          ;;
        --from)
          [[ "$#" -ge 2 ]] || err "--from 缺少组件名称"
          set_components_from "$2"
          shift
          ;;
        *) err "未知 deploy 参数：$1（支持 --verbose、--yes、--components redis,mongodb、--from mongodb）" ;;
      esac
      shift
    done
    trap cleanup_deploy_sudoers EXIT
    deploy_all "$@"
    ;;
  verify)
    shift
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --verbose) VERBOSE=1 ;;
        --components)
          [[ "$#" -ge 2 ]] || err "--components 缺少组件列表"
          set_selected_components "$2"
          shift
          ;;
        *) err "未知 verify 参数：$1（支持 --verbose、--components redis,mongodb）" ;;
      esac
      shift
    done
    verify_selected_components "$@"
    ;;
  *)
    # 默认：仅初始化 Ansible 管理节点
    main "$@"
    ;;
esac
fi
