#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLAYBOOK="$SCRIPT_DIR/playbooks/site/rabbitmq/02_configure.yml"
INSTALL_PLAYBOOK="$SCRIPT_DIR/playbooks/site/rabbitmq/01_install.yml"

grep -Fq '探测种子节点现有 RabbitMQ 集群状态' "$PLAYBOOK"
grep -Fq 'rabbitmq_existing_cluster' "$PLAYBOOK"
grep -Fq 'rabbitmq_seed_persisted_node' "$PLAYBOOK"
grep -Fq 'RabbitMQ 健康复用 - 并行恢复全部节点' "$PLAYBOOK"
grep -Fq '等待健康复用节点 RabbitMQ App 可用' "$PLAYBOOK"
grep -Fq '连续两次确认种子节点 RabbitMQ 稳定可用' "$PLAYBOOK"
grep -Fq 'RMQ_READINESS_CATEGORY=stable_two_samples' "$PLAYBOOK"
grep -Fq 'RMQ_READINESS_CATEGORY=systemd_not_active' "$PLAYBOOK"
grep -Fq 'RMQ_READINESS_CATEGORY=rabbit_app_not_running' "$PLAYBOOK"
grep -Fq 'RMQ_READINESS_CATEGORY=erlang_node_unreachable' "$PLAYBOOK"
grep -Fq 'RMQ_READINESS_CATEGORY=khepri_leader_timeout' "$PLAYBOOK"
grep -Fq 'sleep 2' "$PLAYBOOK"
grep -Fq 'RabbitMQ 健康复用 - 验证完整集群状态' "$PLAYBOOK"
grep -Fq 'rabbitmq_reuse_app' "$PLAYBOOK"
grep -Fq 'rabbitmq_reuse_cluster_health' "$PLAYBOOK"
grep -Fq 'not (hostvars[rabbitmq_seed_node_ip].rabbitmq_existing_cluster | default(false) | bool)' "$PLAYBOOK"
grep -Fq '采集显式重建前 RabbitMQ 只读状态快照' "$PLAYBOOK"
grep -Fq 'rabbitmq_rebuild_state_snapshot' "$PLAYBOOK"
grep -Fq 'timeout 10s epmd -names' "$PLAYBOOK"
grep -Fq 'timeout 10s rabbitmq-diagnostics -q ping' "$PLAYBOOK"
grep -Fq "stat -c 'path=%n mode=%a owner=%U group=%G type=%F' /var/lib/rabbitmq/mnesia" "$PLAYBOOK"
grep -Fq '停止 RabbitMQ 服务以建立受控集群启动顺序' "$PLAYBOOK"
grep -Fq '等待 RabbitMQ 服务停止' "$PLAYBOOK"
grep -Fq 'rabbitmq_rebuild_cluster | bool' "$PLAYBOOK"
grep -Fq 'ansible.builtin.archive:' "$PLAYBOOK"
grep -Fq '校验 RabbitMQ 状态备份文件（仅显式重建时执行）' "$PLAYBOOK"
grep -Fq "rabbitmq_backup_file.stat.mode != '0600'" "$PLAYBOOK"
grep -Fq '校验 RabbitMQ 状态备份内容（仅显式重建时执行）' "$PLAYBOOK"
grep -A8 -Fq '校验 RabbitMQ 状态备份内容（仅显式重建时执行）' "$PLAYBOOK"
grep -Fq 'RabbitMQ 显式重建 - 隔离全部节点旧状态' "$PLAYBOOK"
grep -Fq '确认 RabbitMQ 服务已停止后再隔离状态' "$PLAYBOOK"
grep -Fq '获取 RabbitMQ 旧状态隔离目录时间戳' "$PLAYBOOK"
grep -Fq 'test -d /var/lib/rabbitmq/mnesia' "$PLAYBOOK"
grep -Fq 'test ! -L /var/lib/rabbitmq/mnesia' "$PLAYBOOK"
grep -Fq 'test ! -e "/var/lib/rabbitmq/mnesia-isolated-' "$PLAYBOOK"
grep -Fq 'ansible.builtin.command:' "$PLAYBOOK"
grep -Fq '          - mv' "$PLAYBOOK"
grep -Fq '创建干净 RabbitMQ Mnesia 目录' "$PLAYBOOK"
grep -Fq 'rabbitmq_rebuild_stage: state_isolated' "$PLAYBOOK"
grep -Fq 'RabbitMQ 配置 - 种子节点启动' "$PLAYBOOK"
grep -Fq '停止 App 后再加入集群' "$PLAYBOOK"
grep -Fq 'when: rabbitmq_rebuild_cluster | bool or not (rabbitmq_existing_cluster | default(false) | bool)' "$PLAYBOOK"
grep -Fq 'rabbitmqctl join_cluster rabbit@{{ rabbitmq_seed_hostname }}' "$PLAYBOOK"
grep -Fq '采集种子节点启动失败后的只读诊断' "$PLAYBOOK"
grep -Fq 'RabbitMQ seed startup diagnostics:' "$PLAYBOOK"
grep -Fq 'journalctl -u rabbitmq-server -n 80 --no-pager -o cat' "$PLAYBOOK"
grep -Fq '禁止自动恢复' "$PLAYBOOK"
grep -Fq '禁止自动恢复' "$PLAYBOOK"
grep -Fq '初始化 RabbitMQ 显式重建阶段 checkpoint' "$PLAYBOOK"
grep -Fq 'rabbitmq_rebuild_stage: backup_verified' "$PLAYBOOK"
grep -Fq 'rabbitmq_rebuild_stage: seed_started' "$PLAYBOOK"
grep -A12 -Fq '启动种子节点 rabbitmq-server 并设为开机自启' "$PLAYBOOK"
grep -A8 -Fq '备份 RabbitMQ 持久化状态（仅显式重建时执行）' "$PLAYBOOK"
grep -Fq 'current_cluster_node: "rabbit@{{ inventory_hostname }}"' "$SCRIPT_DIR/playbooks/site/rabbitmq/02_configure.yml"
grep -Fq 'seed_cluster_node: "rabbit@{{ rabbitmq_seed_hostname }}"' "$SCRIPT_DIR/playbooks/site/rabbitmq/02_configure.yml"
grep -Fq 'timeout 30s rabbitmqctl join_cluster rabbit@{{ rabbitmq_seed_hostname }}' "$SCRIPT_DIR/playbooks/site/rabbitmq/02_configure.yml"
grep -Fq 'rabbitmq_join_cluster_result.rc == 124' "$SCRIPT_DIR/playbooks/site/rabbitmq/02_configure.yml"
grep -Fq 'timeout 30s rabbitmqctl stop_app' "$SCRIPT_DIR/playbooks/site/rabbitmq/02_configure.yml"
grep -Fq 'timeout 30s rabbitmqctl start_app' "$SCRIPT_DIR/playbooks/site/rabbitmq/02_configure.yml"
grep -Fq 'rabbitmq_stop_app_result.rc == 124' "$SCRIPT_DIR/playbooks/site/rabbitmq/02_configure.yml"
grep -Fq 'rabbitmq_start_app_result.rc == 124' "$SCRIPT_DIR/playbooks/site/rabbitmq/02_configure.yml"
grep -Fq '安装停服前探测 RabbitMQ 健康复用集群' "$INSTALL_PLAYBOOK"
grep -Fq 'rabbitmq_existing_cluster_before_install' "$INSTALL_PLAYBOOK"
grep -Fq '持久化安装前 RabbitMQ 健康复用判定' "$INSTALL_PLAYBOOK"
grep -Fq '.ecopilot-existing-cluster-health' "$INSTALL_PLAYBOOK"
grep -Fq '读取安装前 RabbitMQ 健康复用判定' "$PLAYBOOK"
grep -Fq "rabbitmq_persisted_cluster_health.stdout | trim == 'true'" "$PLAYBOOK"
reuse_play=$(awk '
	/^- name: RabbitMQ 健康复用 - 并行恢复全部节点$/ { in_play = 1 }
	/^- name: RabbitMQ 健康复用 - 验证完整集群状态$/ { in_play = 0 }
	in_play { print }
' "$PLAYBOOK")
if grep -Fq 'serial:' <<<"$reuse_play"; then
	printf 'FAIL: 健康复用节点恢复不得串行启动\n' >&2
	exit 1
fi
preinstall_probe_line=$(grep -n -m1 '安装停服前探测 RabbitMQ 健康复用集群' "$INSTALL_PLAYBOOK" | cut -d: -f1)
stop_old_service_line=$(grep -n -m1 '请求停止旧 RabbitMQ 服务（保留节点持久化状态）' "$INSTALL_PLAYBOOK" | cut -d: -f1)
if [[ -z "$preinstall_probe_line" || -z "$stop_old_service_line" || "$preinstall_probe_line" -ge "$stop_old_service_line" ]]; then
	printf 'FAIL: 健康复用探测必须先于安装阶段停止 RabbitMQ 服务\n' >&2
	exit 1
fi
grep -Fq "cluster_members.stdout | trim | split(',') | length >= 2" "$SCRIPT_DIR/playbooks/site/rabbitmq/02_configure.yml"
grep -Fq 'expected_cluster_nodes: "{{ rabbitmq_cluster_hostnames' "$SCRIPT_DIR/playbooks/site/rabbitmq/03_verify.yml"
grep -Fq "final_cluster.stdout | trim != expected_cluster_nodes" "$SCRIPT_DIR/playbooks/site/rabbitmq/03_verify.yml"
grep -Fq "final_cluster.stdout | trim).split(',') | length" "$SCRIPT_DIR/playbooks/site/rabbitmq/03_verify.yml"
grep -Fq '执行临时队列消息发布与消费闭环' "$SCRIPT_DIR/playbooks/site/rabbitmq/03_verify.yml"
grep -Fq 'ackmode: ack_requeue_false' "$SCRIPT_DIR/playbooks/site/rabbitmq/03_verify.yml"
grep -Fq 'x-queue-type: quorum' "$SCRIPT_DIR/playbooks/site/rabbitmq/03_verify.yml"
grep -Fq '删除临时验证队列' "$SCRIPT_DIR/playbooks/site/rabbitmq/03_verify.yml"
grep -Fq 'timeout: 10' "$SCRIPT_DIR/playbooks/site/rabbitmq/03_verify.yml"
grep -Fq 'no_log: true' "$SCRIPT_DIR/playbooks/site/rabbitmq/03_verify.yml"
if grep -Fq 'grep -c "{{ rabbitmq_node_prefix }}"' "$SCRIPT_DIR/playbooks/site/rabbitmq/03_verify.yml"; then
	printf 'FAIL: RabbitMQ 最终验收不得使用模糊节点前缀计数\n' >&2
	exit 1
fi

rebuild_play=$(awk '
	/^- name: RabbitMQ 配置 - Erlang Cookie 和服务启动$/ { in_play = 1 }
	/^- name: RabbitMQ 集群 - 非种子节点加入集群$/ { in_play = 0 }
	in_play { print }
' "$PLAYBOOK")
if ! grep -Fq 'serial: 1' <<<"$rebuild_play"; then
	printf 'FAIL: 破坏性 RabbitMQ 重建 Play 必须串行执行\n' >&2
	exit 1
fi

snapshot_to_stop=$(awk '
	/采集显式重建前 RabbitMQ 只读状态快照/ { found_snapshot = 1 }
	/停止 RabbitMQ 服务以建立受控集群启动顺序/ { found_stop = 1 }
	found_snapshot && found_stop { print "ok"; exit }
' "$PLAYBOOK")
if [[ "$snapshot_to_stop" != "ok" ]]; then
	printf 'FAIL: 重建前只读状态快照必须先于停止服务\n' >&2
	exit 1
fi

if grep -Fq 'rabbitmqctl force_reset' "$PLAYBOOK"; then
	printf 'FAIL: Khepri 不支持 force_reset\n' >&2
	exit 1
fi

if sed -n '/停止 RabbitMQ 服务以建立受控集群启动顺序/,/写入统一 Erlang Cookie/p' "$PLAYBOOK" | grep -Fq 'when:'; then
	:
else
	printf 'FAIL: 全节点停止未受条件门控\n' >&2
	exit 1
fi

if grep -Fq 'rabbitmqctl force_boot' "$PLAYBOOK"; then
	printf 'FAIL: 不应再使用已失效的 force_boot 恢复路径\n' >&2
	exit 1
fi

isolation_line=$(grep -n -m1 'RabbitMQ 显式重建 - 隔离全部节点旧状态' "$PLAYBOOK" | cut -d: -f1)
seed_line=$(grep -n -m1 'RabbitMQ 配置 - 种子节点启动' "$PLAYBOOK" | cut -d: -f1)
if [[ -z "$isolation_line" || -z "$seed_line" || "$isolation_line" -ge "$seed_line" ]]; then
	printf 'FAIL: 旧状态隔离必须先于种子节点启动\n' >&2
	exit 1
fi

isolation_block=$(sed -n "${isolation_line},${seed_line}p" "$PLAYBOOK")
if ! grep -Fq 'rabbitmq_rebuild_cluster | bool' <<<"$isolation_block" ||
	! grep -Fq '          - mv' <<<"$isolation_block" ||
	! grep -Fq 'state: directory' <<<"$isolation_block"; then
	printf 'FAIL: 显式重建必须先校验并原子隔离旧状态，再创建干净目录\n' >&2
	exit 1
fi

join_line=$(grep -n -m1 '加入种子节点' "$PLAYBOOK" | cut -d: -f1)
stop_app_line=$(grep -n -m1 '停止 App 后再加入集群' "$PLAYBOOK" | cut -d: -f1)
if [[ -z "$stop_app_line" || -z "$join_line" || "$stop_app_line" -ge "$join_line" ]]; then
	printf 'FAIL: 非种子节点必须先停止 App 再 join_cluster\n' >&2
	exit 1
fi

printf 'PASS: RabbitMQ 健康集群可重入，重建受显式开关门控，并串行加入成员\n'