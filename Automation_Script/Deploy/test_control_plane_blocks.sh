#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ANSIBLE_INVENTORY=${ANSIBLE_INVENTORY:-ansible-inventory}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ecopilot-control-plane-test.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  grep -Fqx "$2" "$1" || fail "缺少预期行：$2"
}

assert_not_contains() {
  ! grep -Fqx "$2" "$1" || fail "发现不应存在的行：$2"
}

merge_blocks() {
  local target="$1" kind="$2" candidate="$3" selected="$4" selected_count="$5"
  local component fragment next

  if grep -q '^# BEGIN DB_CLUSTER_HOSTS$' "$target" 2>/dev/null; then
    if [[ "$selected_count" -ne 4 ]]; then
      echo '检测到旧版全局受管 hosts 块；局部操作已停止' >&2
      return 1
    fi
    awk '/^# BEGIN DB_CLUSTER_HOSTS$/ { skip=1; next } /^# END DB_CLUSTER_HOSTS$/ { skip=0; next } !skip { print }' "$target" > "$candidate"
  else
    cp "$target" "$candidate" 2>/dev/null || : > "$candidate"
  fi

  if [[ "$kind" == inventory ]] && grep -Eq '^\[(redis|rabbitmq|mongodb|mysql)\]$' "$target" 2>/dev/null && ! grep -q '^# BEGIN ECOPILOT_COMPONENT ' "$target"; then
    if [[ "$selected_count" -ne 4 ]]; then
      echo '检测到旧版未归属 inventory；局部操作已停止' >&2
      return 1
    fi
    awk '
      /^\[(redis|rabbitmq|mongodb|mysql|db_all:children)\]$/ { skip=1; next }
      /^\[/ { skip=0 }
      !skip { print }
    ' "$target" > "$candidate"
  fi

  for component in $selected; do
    fragment="$WORK_DIR/fragments/$kind-$component"
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
  awk '
    /^# BEGIN ECOPILOT_COMPONENT (redis|rabbitmq|mongodb|mysql)$/ { component=$4; if (++begin[component] != 1) exit 1; open=component; next }
    /^# END ECOPILOT_COMPONENT (redis|rabbitmq|mongodb|mysql)$/ { if (open != $4) exit 1; end[$4]++; open="" }
    END { if (open != "") exit 1; for (component in begin) if (begin[component] != end[component]) exit 1 }
  ' "$1"
}

validate_hosts() {
  awk '
    /^# BEGIN ECOPILOT_COMPONENT / { inside=1; next }
    /^# END ECOPILOT_COMPONENT / { inside=0; next }
    inside && NF >= 2 { if (ip[$1]++ || hostname[$2]++) exit 1 }
  ' "$1"
}

rebuild_inventory() {
  local candidate="$1" base="$WORK_DIR/inventory.base" groups="$WORK_DIR/inventory.groups"
  {
    printf '[db_all:children]\n'
    awk '/^# BEGIN ECOPILOT_COMPONENT / { print $4 }' "$candidate"
  } > "$groups"
  awk '/^\[db_all:children\]$/ { skip=1; next } !skip { print }' "$candidate" > "$base"
  cat "$base" "$groups" > "$candidate.final"
}

mkdir -p "$WORK_DIR/fragments"
cat > "$WORK_DIR/fragments/hosts-redis" <<'EOF'
# BEGIN ECOPILOT_COMPONENT redis
10.20.14.41      redis-1
# END ECOPILOT_COMPONENT redis
EOF
cat > "$WORK_DIR/fragments/inventory-redis" <<'EOF'
# BEGIN ECOPILOT_COMPONENT redis
[redis]
10.20.14.41
# END ECOPILOT_COMPONENT redis
EOF
cat > "$WORK_DIR/fragments/hosts-mongodb" <<'EOF'
# BEGIN ECOPILOT_COMPONENT mongodb
10.20.14.47      mongodb-1
# END ECOPILOT_COMPONENT mongodb
EOF
cat > "$WORK_DIR/fragments/inventory-mongodb" <<'EOF'
# BEGIN ECOPILOT_COMPONENT mongodb
[mongodb]
10.20.14.47
# END ECOPILOT_COMPONENT mongodb
EOF

: > "$WORK_DIR/hosts"
: > "$WORK_DIR/inventory"
merge_blocks "$WORK_DIR/hosts" hosts "$WORK_DIR/hosts.candidate" redis 1
merge_blocks "$WORK_DIR/inventory" inventory "$WORK_DIR/inventory.candidate" redis 1
mv "$WORK_DIR/hosts.candidate" "$WORK_DIR/hosts"
mv "$WORK_DIR/inventory.candidate" "$WORK_DIR/inventory"
merge_blocks "$WORK_DIR/hosts" hosts "$WORK_DIR/hosts.candidate" mongodb 1
merge_blocks "$WORK_DIR/inventory" inventory "$WORK_DIR/inventory.candidate" mongodb 1
validate_markers "$WORK_DIR/hosts.candidate"
validate_markers "$WORK_DIR/inventory.candidate"
validate_hosts "$WORK_DIR/hosts.candidate"
rebuild_inventory "$WORK_DIR/inventory.candidate"
assert_contains "$WORK_DIR/hosts.candidate" '10.20.14.41      redis-1'
assert_contains "$WORK_DIR/hosts.candidate" '10.20.14.47      mongodb-1'
assert_contains "$WORK_DIR/inventory.candidate.final" 'redis'
assert_contains "$WORK_DIR/inventory.candidate.final" 'mongodb'
pass '增量合并保留既有组件并生成 db_all'

if command -v "$ANSIBLE_INVENTORY" >/dev/null 2>&1; then
  "$ANSIBLE_INVENTORY" -i "$WORK_DIR/inventory.candidate.final" --graph > "$WORK_DIR/inventory.graph"
  assert_contains "$WORK_DIR/inventory.graph" '  |--@db_all:'
  assert_contains "$WORK_DIR/inventory.graph" '  |  |--@redis:'
  assert_contains "$WORK_DIR/inventory.graph" '  |  |--@mongodb:'
  pass 'Ansible inventory 解析 db_all 聚合组'
else
  printf 'SKIP: 未找到 ansible-inventory，跳过解析检查\n' >&2
fi

cat > "$WORK_DIR/legacy-hosts" <<'EOF'
# BEGIN DB_CLUSTER_HOSTS
10.20.14.41 redis-1
# END DB_CLUSTER_HOSTS
EOF
if merge_blocks "$WORK_DIR/legacy-hosts" hosts "$WORK_DIR/legacy-hosts.candidate" redis 1; then
  fail '旧版全局 hosts 块未拒绝局部操作'
fi
pass '旧版全局 hosts 块拒绝局部操作'

cat > "$WORK_DIR/legacy-inventory" <<'EOF'
[redis]
10.20.14.41
[rabbitmq]
10.20.14.44
[mongodb]
10.20.14.47
[mysql]
10.20.14.50
[db_all:children]
redis
rabbitmq
mongodb
mysql
[monitoring]
10.20.14.60
EOF
if merge_blocks "$WORK_DIR/legacy-inventory" inventory "$WORK_DIR/legacy-inventory.candidate" redis 1; then
  fail '旧版 inventory 未拒绝局部操作'
fi
merge_blocks "$WORK_DIR/legacy-inventory" inventory "$WORK_DIR/legacy-inventory.candidate" 'redis rabbitmq mongodb mysql' 4
assert_contains "$WORK_DIR/legacy-inventory.candidate" '[monitoring]'
assert_contains "$WORK_DIR/legacy-inventory.candidate" '10.20.14.60'
assert_not_contains "$WORK_DIR/legacy-inventory.candidate" '[db_all:children]'
assert_not_contains "$WORK_DIR/legacy-inventory.candidate" '10.20.14.44'
assert_not_contains "$WORK_DIR/legacy-inventory.candidate" '10.20.14.50'
pass '旧版 inventory 全量迁移清除受管组并保留非受管组'

cat > "$WORK_DIR/duplicate-hosts" <<'EOF'
# BEGIN ECOPILOT_COMPONENT redis
10.20.14.41 redis-1
# END ECOPILOT_COMPONENT redis
# BEGIN ECOPILOT_COMPONENT mongodb
10.20.14.41 mongodb-1
# END ECOPILOT_COMPONENT mongodb
EOF
if validate_hosts "$WORK_DIR/duplicate-hosts"; then
  fail '重复 IP 映射未被拒绝'
fi
pass '重复 IP 映射被拒绝'

cat > "$WORK_DIR/duplicate-markers" <<'EOF'
# BEGIN ECOPILOT_COMPONENT redis
# END ECOPILOT_COMPONENT redis
# BEGIN ECOPILOT_COMPONENT redis
# END ECOPILOT_COMPONENT redis
EOF
if validate_markers "$WORK_DIR/duplicate-markers"; then
  fail '重复组件标记未被拒绝'
fi
pass '重复组件标记被拒绝'

printf 'CONTROL_PLANE_TESTS=PASS (%s)\n' "$pass_count"