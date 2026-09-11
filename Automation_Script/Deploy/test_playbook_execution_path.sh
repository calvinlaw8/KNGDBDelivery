#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/init_ansible.sh"

grep -Fq 'LOCAL_PLAYBOOK_DIR="${DELIVERY_PLAYBOOK_DIR:-${LOCAL_PLAYBOOK_DIR}}"' "$SCRIPT"
grep -Fq 'extra_vars="-e @${REMOTE_PLAYBOOK_DIR}/group_vars/all.yml"' "$SCRIPT"
grep -Fq 'extra_vars="${extra_vars} -e @${REMOTE_PLAYBOOK_DIR}/group_vars/${tags}.yml"' "$SCRIPT"
grep -Fq '"${REMOTE_PLAYBOOK_DIR}/preflights/00_preflight.yml ${REMOTE_PLAYBOOK_DIR}/preflights/01_server_init.yml"' "$SCRIPT"
grep -Fq '"${REMOTE_PLAYBOOK_DIR}/site/site.yml"' "$SCRIPT"
grep -Fq '"${REMOTE_PLAYBOOK_DIR}/preflights/02_postflight.yml"' "$SCRIPT"
! grep -Fq '"~/playbooks/' "$SCRIPT"

printf 'PASS: 工作台 generation 剧本优先，并且所有 Ansible 阶段执行已上传剧本\n'