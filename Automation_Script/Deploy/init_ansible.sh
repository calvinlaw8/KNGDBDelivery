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
LOCAL_DELIVERY_VERIFIER="${SCRIPT_DIR}/verify_delivery.sh"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
REMOTE="${ANSIBLE_NODE_USER}@${ANSIBLE_NODE_IP}"

# 所有本地→管理节点的 SSH/SCP 均通过此函数，密码用环境变量传递（不暴露在进程列表）
ssh_run() {
  SSHPASS="${ANSIBLE_NODE_PASS}" sshpass -e \
    ssh ${SSH_OPTS} "${REMOTE}" "$@"
}

# 将 sudo 密码通过 SSH 标准输入传递，避免出现在远端命令参数中。
sudo_run() {
  local command="$1"
  printf '%s\n' "${ANSIBLE_NODE_PASS}" | \
    ssh_run "sudo -S -p '' bash -c $(printf '%q' "${command}")"
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
  SSHPASS="${ANSIBLE_NODE_PASS}" sshpass -e \
    scp ${SSH_OPTS} -r "${LOCAL_PLAYBOOK_DIR}/." \
    "${REMOTE}:${REMOTE_PLAYBOOK_DIR}/"
  SSHPASS="${ANSIBLE_NODE_PASS}" sshpass -e \
    scp ${SSH_OPTS} "${LOCAL_PAYLOAD_VALIDATOR}" \
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
    ssh_run "printf '%s\n' '${ANSIBLE_NODE_PASS}' | sudo -S mkdir -p /etc/ansible/group_vars && \
             printf '%s\n' '${ANSIBLE_NODE_PASS}' | sudo -S cp '${REMOTE_PLAYBOOK_DIR}/group_vars/'*.yml /etc/ansible/group_vars/ && \
             printf '%s\n' '${ANSIBLE_NODE_PASS}' | sudo -S chown root:root /etc/ansible/group_vars/*.yml && \
             printf '%s\n' '${ANSIBLE_NODE_PASS}' | sudo -S chmod 0644 /etc/ansible/group_vars/*.yml"
    ok "group_vars → /etc/ansible/group_vars/ 同步完成"
  fi
}

# Step 2c: 上传 DB 离线包（redis / rabbitmq / mongodb / mysql）
step2c_upload_db_packages() {
  info "2c" "上传 DB 离线包 → ${ANSIBLE_NODE_IP}:${REMOTE_PKG_DIR}"

  [[ -d "${LOCAL_DB_PKG_DIR}" ]] || \
    err "DB 离线包目录不存在：${LOCAL_DB_PKG_DIR}"

  local sshpass_file="$(mktemp "${TMPDIR:-/tmp}/delivery5-sshpass.XXXXXX")"
  chmod 600 "${sshpass_file}"
  printf '%s\n' "${ANSIBLE_NODE_PASS}" > "${sshpass_file}"
  trap 'rm -f -- "${sshpass_file:-}"' RETURN

  for db in redis rabbitmq mongodb mysql; do
    local src="${LOCAL_DB_PKG_DIR}/${db}"
    local dst="${REMOTE_PKG_DIR}/${db}"

    [[ -d "${src}" ]] || err "本地 ${db} 正式包目录不存在：${src}"

    ssh_run "mkdir -p '${dst}'"
    rsync -a --delete \
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

  # <<EOF 内：${REMOTE_PKG_DIR} / ${ANSIBLE_NODE_PASS} 在本地展开，\$() 在远端执行
  # 注意：不做"已安装跳过"的幂等检查。
  # 原因：pip "Requirement already satisfied" 会跳过写操作（含 console_scripts），
  # 若 Python 包已在 dist-packages 但 /usr/local/bin/ansible 不存在，
  # pip 不报错也不重建 binary，导致后续所有步骤失败。
  # 解决：始终带 --force-reinstall --no-deps，强制重建 console_scripts。
  ssh_run "bash -s" <<EOF
# 安装 sshpass（幂等）
if ! command -v sshpass &>/dev/null; then
  printf '%s\n' '${ANSIBLE_NODE_PASS}' | sudo -S dpkg -i ${REMOTE_PKG_DIR}/sshpass/sshpass_*.deb
fi

# 安装 Ansible（借用 pip whl 内置 pip，pip 本身不装到系统）。
# 已有可用命令时跳过重装，避免重复卸载管理节点上正在工作的 Ansible。
if ! command -v ansible-playbook &>/dev/null; then
  PIP_WHL=\$(ls ${REMOTE_PKG_DIR}/pip/pip-*.whl | head -1)
  printf '%s\n' '${ANSIBLE_NODE_PASS}' | sudo -S python3 "\${PIP_WHL}/pip" install \
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

  ssh_run "bash -s" <<EOF
if printf '%s\n' '${ANSIBLE_NODE_PASS}' | sudo -S grep -q NOPASSWD /etc/sudoers.d/sysadmin 2>/dev/null; then
  echo "  ✔ 已配置，跳过"
else
  printf '%s\n' '${ANSIBLE_NODE_PASS}' | sudo -S sh -c \\
    "echo 'sysadmin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/sysadmin && chmod 440 /etc/sudoers.d/sysadmin"
  echo "  ✔ 配置完成（权限 440）"
fi
EOF
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

# Step 5: 分发公钥到 12 台 DB 服务器（建立免密 SSH）
step5_distribute_pubkey() {
  info "5" "分发公钥到 DB 服务器（${#DB_IPS[@]} 台）"

  # ${DB_IPS[*]} / ${DB_USER} / ${DB_PASS} 在本地展开，\${ip} 在管理节点执行
  ssh_run "bash -s" <<EOF
total_ok=0; total_skip=0; total_fail=0
for ip in ${DB_IPS[*]}; do
  if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
       ${DB_USER}@\${ip} true 2>/dev/null; then
    echo "  ✔ \${ip} 已有免密 SSH，跳过"
    total_skip=\$((total_skip+1))
  else
    if SSHPASS='${DB_PASS}' sshpass -e \
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
  ok "公钥分发完成（免密 SSH 已建立）"
}

# Step 6: 配置 DB 服务器 NOPASSWD sudo
step6_nopasswd_sudo() {
  info "6" "配置 DB 服务器 NOPASSWD sudo（${#DB_IPS[@]} 台）"

  ssh_run "bash -s" <<EOF
total_ok=0; total_skip=0; total_fail=0
for ip in ${DB_IPS[*]}; do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${DB_USER}@\${ip} \
       "grep -q 'NOPASSWD' /etc/sudoers.d/sysadmin 2>/dev/null" 2>/dev/null; then
    echo "  ✔ \${ip} 已配置 NOPASSWD sudo，跳过"
    total_skip=\$((total_skip+1))
  else
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${DB_USER}@\${ip} \
         "printf '%s\n' '${DB_PASS}' | sudo -S bash -c \
          \"echo 'sysadmin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/sysadmin && \
            chmod 440 /etc/sudoers.d/sysadmin\"" 2>&1; then
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
  ok "NOPASSWD sudo 配置完成"
}

# Step 6b: 设置 DB 服务器主机名 & 更新管理节点 /etc/hosts
step6b_configure_hosts() {
  info "6b" "设置 DB 服务器主机名 & 更新管理节点 /etc/hosts"

  # ── 1. 逐台设置主机名（SSH → sudo hostnamectl，幂等）──
  ssh_run "bash -s" <<EOF
ips=(${DB_IPS[*]})
hostnames=(${DB_HOSTNAMES[*]})
total_ok=0; total_skip=0; total_fail=0
for i in "\${!ips[@]}"; do
  ip="\${ips[\$i]}"
  hn="\${hostnames[\$i]}"
  current=\$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \\
               ${DB_USER}@\${ip} "hostname" 2>/dev/null || echo "")
  if [[ "\${current}" == "\${hn}" ]]; then
    echo "  ✔ \${ip} 主机名已是 \${hn}，跳过"
    total_skip=\$((total_skip+1))
  else
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \\
           ${DB_USER}@\${ip} "sudo hostnamectl set-hostname '\${hn}'" 2>&1; then
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

  # ── 2. 向管理节点 /etc/hosts 追加 IP→主机名 映射（幂等）──
  if ssh_run "grep -q '${DB_IPS[0]}.*${DB_HOSTNAMES[0]}' /etc/hosts 2>/dev/null"; then
    ok "/etc/hosts DB 条目已存在，跳过"
  else
    {
      printf '# BEGIN DB_CLUSTER_HOSTS\n'
      for i in "${!DB_IPS[@]}"; do
        printf '%-16s %s\n' "${DB_IPS[$i]}" "${DB_HOSTNAMES[$i]}"
      done
      printf '# END DB_CLUSTER_HOSTS\n'
    } | ssh_run "sudo tee -a /etc/hosts > /dev/null"
    ok "/etc/hosts 已追加 ${#DB_IPS[@]} 条 IP→主机名 映射"
  fi
}

# Step 7: 写入 Ansible Inventory（/etc/ansible/hosts）
step7_inventory() {
  info "7" "写入 /etc/ansible/hosts"

  if ssh_run "sudo grep -q 'db_all:children' /etc/ansible/hosts 2>/dev/null"; then
    ok "/etc/ansible/hosts 已存在，跳过"
    return
  fi

  # 本地构建 inventory 内容（变量在本地展开），通过管道 tee 写入远端
  {
    printf '[redis]\n'
    printf '%s\n' "${REDIS_IPS[@]}"
    printf '\n[rabbitmq]\n'
    printf '%s\n' "${RABBITMQ_IPS[@]}"
    printf '\n[mongodb]\n'
    printf '%s\n' "${MONGODB_IPS[@]}"
    printf '\n[mysql]\n'
    printf '%s\n' "${MYSQL_IPS[@]}"
    printf '\n[db_all:children]\nredis\nrabbitmq\nmongodb\nmysql\n'
  } | ssh_run "sudo mkdir -p /etc/ansible && sudo tee /etc/ansible/hosts > /dev/null"

  ok "Inventory 已写入"
}

# Step 7b: 将 group_vars 复制到 /etc/ansible/group_vars/（让子目录 playbook 也能加载变量）
step7b_group_vars() {
  info "7b" "同步 group_vars → /etc/ansible/group_vars"

  ssh_run "sudo mkdir -p /etc/ansible/group_vars && \
           sudo cp ${REMOTE_PLAYBOOK_DIR}/group_vars/*.yml /etc/ansible/group_vars/ 2>/dev/null && \
           sudo chown root:root /etc/ansible/group_vars/*.yml && \
           sudo chmod 0644 /etc/ansible/group_vars/*.yml && echo DONE || echo SKIP"
  ok "group_vars 已同步"
}

# Step 8: 写入 ansible.cfg
step8_ansible_cfg() {
  info "8" "写入 /etc/ansible/ansible.cfg"

  if ssh_run "sudo grep -q 'become_ask_pass' /etc/ansible/ansible.cfg 2>/dev/null"; then
    ok "/etc/ansible/ansible.cfg 已存在，跳过"
    return
  fi

  ssh_run "bash -s" <<'REMOTE'
sudo bash -c 'printf "[defaults]\ninventory = /etc/ansible/hosts\nhost_key_checking = False\nremote_user = sysadmin\n\n[privilege_escalation]\nbecome = True\nbecome_method = sudo\nbecome_user = root\nbecome_ask_pass = False\n" > /etc/ansible/ansible.cfg'
REMOTE
  ok "ansible.cfg 已写入"
}

# Step 9: 连通性验证（ansible db_all -m ping）
step9_ping() {
  info "9" "连通性验证（ansible db_all -m ping）"

  local result
  result=$(ssh_run "ansible db_all -m ping 2>&1" || true)
  echo "${result}" | sed 's/^/  /'

  local success_count total
  success_count=$(echo "${result}" | grep -c '| SUCCESS' || true)
  total=${#DB_IPS[@]}

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
  local placeholder_count

  [[ -f "${config_file}" ]] || err "配置文件不存在：${config_file}"
  [[ -d "${group_vars_dir}" ]] || err "group_vars 目录不存在：${group_vars_dir}"

  placeholder_count=$(grep -R -h -o 'CHANGE_ME' "${config_file}" "${group_vars_dir}"/*.yml 2>/dev/null || true)
  if [[ -n "${placeholder_count}" ]]; then
    placeholder_count=$(printf '%s\n' "${placeholder_count}" | wc -l | tr -d ' ')
  else
    placeholder_count=0
  fi
  [[ "${placeholder_count}" -eq 0 ]] ||
    err "配置仍包含 ${placeholder_count} 个 CHANGE_ME 占位符；请在受控终端填写 config.env 和 group_vars/*.yml 后重试"

  local role
  for role in REDIS RABBITMQ MONGODB MYSQL; do
    local ips_var="${role}_IPS[@]"
    local hostnames_var="${role}_HOSTNAMES[@]"
    local -a ips=("${!ips_var}")
    local -a hostnames=("${!hostnames_var}")
    [[ "${#ips[@]}" -eq 3 && "${#hostnames[@]}" -eq 3 ]] ||
      err "${role} 必须配置 3 个 IP 和 3 个主机名，当前为 ${#ips[@]} 个 IP、${#hostnames[@]} 个主机名"
  done

  [[ "${#DB_IPS[@]}" -eq 12 && "${#DB_HOSTNAMES[@]}" -eq 12 ]] ||
    err "DB 汇总拓扑必须包含 12 台服务器，当前为 ${#DB_IPS[@]} 个 IP、${#DB_HOSTNAMES[@]} 个主机名"

  local duplicate_ip duplicate_hostname
  duplicate_ip=$(printf '%s\n' "${DB_IPS[@]}" | sort | uniq -d | head -n 1)
  [[ -z "${duplicate_ip}" ]] || err "数据库节点存在重复 IP：${duplicate_ip}"
  duplicate_hostname=$(printf '%s\n' "${DB_HOSTNAMES[@]}" | sort | uniq -d | head -n 1)
  [[ -z "${duplicate_hostname}" ]] || err "数据库节点存在重复主机名：${duplicate_hostname}"

  ok "配置门禁通过（无 CHANGE_ME，四组拓扑均为 3 节点）"
}

validate_delivery_assets() {
  [[ -f "${LOCAL_DELIVERY_VERIFIER}" ]] ||
    err "统一交付校验器不存在：${LOCAL_DELIVERY_VERIFIER}"
  /bin/bash "${LOCAL_DELIVERY_VERIFIER}" --configured ||
    err "统一交付校验失败；未执行任何远程操作"
}

# ============================================================
# 主流程
# ============================================================
main() {
  echo "=================================================="
  echo " Ansible 管理节点完整初始化"
  echo " 目标：${REMOTE}  (${ANSIBLE_NODE_HOSTNAME})"
  echo " DB 服务器：${#DB_IPS[@]} 台"
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
  step7b_group_vars
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

# 在远程 Ansible 节点上实时执行 playbook，并为本地终端流式输出带时间戳的进度行
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

  local cmd="ansible-playbook ${playbook}"
  [[ -n "${tags}" ]] && cmd="${cmd} --tags ${tags}"

  # 远端命令后台执行，本地持续读取输出并提供心跳；避免 dpkg/数据库初始化长时间无输出时像卡死。
  local output_file; output_file=$(mktemp "${TMPDIR:-/tmp}/delivery5-playbook.XXXXXX")
  SSHPASS="${ANSIBLE_NODE_PASS}" sshpass -e ssh \
    -o StrictHostKeyChecking=no \
    -o LogLevel=ERROR \
    "${REMOTE}" \
    "ANSIBLE_FORCE_COLOR=0 ${cmd}" >"${output_file}" 2>&1 &
  local ssh_pid=$!

  # tail -f 保证 Ansible 每完成一行就显示；心跳保证无输出期间仍可判断进程存活。
  tail -f "${output_file}" 2>/dev/null | while IFS= read -r line; do
    if   [[ "${line}" == PLAY* ]];         then printf "\033[1;36m  %s\033[0m\n" "${line}"
    elif [[ "${line}" == TASK* ]];         then printf "\033[0;33m  %s\033[0m\n" "${line}"
    elif [[ "${line}" == *"ok:"* ]];       then printf "\033[0;32m  %s\033[0m\n" "${line}"
    elif [[ "${line}" == *"changed:"* ]];  then printf "\033[1;33m  %s\033[0m\n" "${line}"
    elif [[ "${line}" == *"failed:"* && "${line}" != *"failed=0"* ]]; then
                                                printf "\033[0;31m  %s\033[0m\n" "${line}"
    elif [[ "${line}" == "PLAY RECAP"* ]]; then printf "\033[1;35m  %s\033[0m\n" "${line}"
    else printf "  %s\n" "${line}"
    fi
  done &
  local tail_pid=$!

  while kill -0 "${ssh_pid}" 2>/dev/null; do
    local elapsed_now=$(( $(date +%s) - t0 ))
    printf "\033[2m  … ${stage} 仍在执行，已耗时 %dm%02ds（最近输出持续写入中）\033[0m\n" \
      "$(( elapsed_now / 60 ))" "$(( elapsed_now % 60 ))"
    sleep 15
  done

  local rc=0
  wait "${ssh_pid}" || rc=$?
  sleep 1
  kill "${tail_pid}" 2>/dev/null || true
  wait "${tail_pid}" 2>/dev/null || true
  /bin/rm -f "${output_file}"
  local elapsed=$(( $(date +%s) - t0 ))
  local mm=$(( elapsed / 60 ))
  local ss=$(( elapsed % 60 ))

  if [[ ${rc} -eq 0 ]]; then
    echo ""
    ok "阶段完成：${stage}  耗时 ${mm}m${ss}s"
  else
    echo ""
    err "阶段失败：${stage}（exit=${rc}）请查看上方输出排查原因"
  fi
}

deploy_all() {
  local TOTAL_T0; TOTAL_T0=$(date +%s)

  echo ""
  echo "=================================================="
  echo " 🚀 全流程自动化部署"
  echo "    目标节点：${REMOTE}"
  echo "    时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "=================================================="

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

  # Redis
  _run_playbook_stage \
    "Redis 8.2.8 主从 + Sentinel" \
    "redis" \
    "~/playbooks/site/site.yml"

  # RabbitMQ（目标载荷为 RabbitMQ 4.2.9 + Erlang 27.3.4.16）
  echo ""
  warn "RabbitMQ 阶段：需安装 RabbitMQ 4.2.9 + Erlang 27.3.4.16，请耐心等待..."
  _run_playbook_stage \
    "RabbitMQ 4.2.9 集群" \
    "rabbitmq" \
    "~/playbooks/site/site.yml"

  # MongoDB
  _run_playbook_stage \
    "MongoDB 8.2.12 副本集" \
    "mongodb" \
    "~/playbooks/site/site.yml"

  # MySQL（离线 .deb 安装 + 串行初始化）
  echo ""
  warn "MySQL 阶段：离线 .deb 安装并串行初始化数据目录，请耐心等待..."
  _run_playbook_stage \
    "MySQL 8.4.11 GTID 主从 + Keepalived VIP" \
    "mysql" \
    "~/playbooks/site/site.yml"

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

# ============================================================
# 入口路由
# ============================================================
case "${1:-}" in
  deploy)
    # 加载配置后执行全流程部署
    shift
    deploy_all "$@"
    ;;
  *)
    # 默认：仅初始化 Ansible 管理节点
    main "$@"
    ;;
esac
