# WorkBuddy 意见：RabbitMQ 部署故障诊断与整改建议

| 项 | 内容 |
| --- | --- |
| 出具时间 | 2026-09-10 17:10 |
| 诊断对象 | `Automation_Script/Deploy` 离线部署链路 — RabbitMQ 组件 |
| 诊断方式 | 只读。仅查阅本机工作副本、`.runtime` 产物与 git 历史，**未修改任何文件、未连接目标服务器** |
| 结论性质 | 部署脚本缺陷，**非 RabbitMQ 集群故障** |
| 置信度 | 根因判定：高（有日志、git 历史、渲染产物三方证据） |

---

## 一、结论摘要

RabbitMQ 部署在「非种子节点加入集群」阶段失败并中止，导致第三个节点从未加入。

失败的直接触发点是 `playbooks/site/rabbitmq/02_configure.yml:361` 的「验证集群成员数（应 >= 2）」任务在 `10.20.14.45` 上重试 12 次后判定失败。但**集群本身是健康的**——失败时刻集群已有 `rabbit@rabbitmq01`、`rabbit@rabbitmq02` 两个节点，只是不完整。

根因是**两个缺陷叠加**，且均为今天（2026-09-10）引入的未提交改动：

1. 校验所依赖的变量 `rabbitmq_cluster_hostnames` 在渲染产物中恒为空列表，导致期望值恒为空字符串，任何非空结果都判失败；
2. 新增的 `serial: 1` 分批加入机制，与「每批加入后校验全量节点列表」的判定条件自相矛盾——第一个非种子节点加入后集群只有 2 个节点，永远不可能等于 3 个。

---

## 二、故障现象

| 项 | 观察值 |
| --- | --- |
| 失败组件 | RabbitMQ 4.2.9（3 节点：44 种子 / 45 / 46） |
| 状态文件 | `.runtime/state/rabbitmq.deploy.failed`，记录时间 16:53:08 |
| 最后成功阶段 | Preflight（服务器预检 + 初始化） |
| 重试记录 | 16:48:53 一次、17:00:21 一次，均失败 |
| 其他组件 | mongodb、redis：`deploy.verified`；mysql：`deploy.failed`（2026-09-09 15:43，另案） |

失败任务原文（`.runtime/logs/deploy-20260910-164853-RabbitMQ_4.2.9_______.log:599`）：

```
fatal: [10.20.14.45]: FAILED! => {
  "attempts": 12,
  "cmd": "rabbitmqctl cluster_status 2>/dev/null | sed -n '/Disk Nodes/,/Running Nodes/p' | grep '^rabbit@' | sort | paste -sd ',' -",
  "stdout": "rabbit@rabbitmq01,rabbit@rabbitmq02",
  "failed_when_result": true
}
```

注意 `stdout` 有值且为 2 个节点，但仍判定失败——这是识别本次故障性质的关键信号：**判定条件出了问题，而不是集群出了问题**。

---

## 三、根因判定

### 缺陷 1：期望值恒为空字符串（致命）

当前工作副本的判定逻辑（`02_configure.yml:361-375`）：

```yaml
- name: 验证集群成员数（应 >= 2）
  vars:
    expected_cluster_nodes: "{{ rabbitmq_cluster_hostnames | map('regex_replace', '^', 'rabbit@') | sort | join(',') }}"
  until: cluster_members.stdout | trim == expected_cluster_nodes
  failed_when: cluster_members.stdout | trim != expected_cluster_nodes
```

- `git diff configurator/render.py` 显示，`"rabbitmq_cluster_hostnames": [...]` 这一行是本次新增（`+` 号）。
- 但部署实际使用的渲染产物 `.runtime/current` → `20260910T085903Z-b96c4d38939cc5be`，生成于 08:59，**早于该渲染逻辑的加入时间**，其中：

  ```yaml
  rabbitmq_seed_node_ip: "10.20.14.44"      # 已渲染
  rabbitmq_seed_hostname: "rabbitmq01"      # 已渲染
  rabbitmq_cluster_hostnames: []            # 未渲染，仍是模板占位
  ```

- 因此 `expected_cluster_nodes` 求值为空字符串 `""`，而实际输出为 `"rabbit@rabbitmq01,rabbit@rabbitmq02"` → 恒不相等 → 重试 12 次后失败。

**判定：新增渲染逻辑后没有重新生成渲染产物，部署仍在消费旧的 group_vars。**

### 缺陷 2：分批加入与全量校验自相矛盾（致命）

- 本次改动给「非种子节点加入集群」PLAY 增加了 `serial: 1`（`02_configure.yml:304`），节点逐个加入；
- 但每个批次结束后执行的却是**全量节点列表**比对（要求等于 3 个）；
- 结果：第一个非种子节点（45）加入成功后集群只有 2 个节点 → 永远不满足 → 失败 → `any_errors_fatal: true` 中止整个 play → **第三个节点 10.20.14.46 从未执行加入**。

日志佐证：同名 PLAY 出现两次（`529` / `555` 行），第一次全部为 `skipping: [10.20.14.44]`（种子节点被 `when` 跳过），第二次才真正处理 45；PLAY RECAP 中 `10.20.14.46 : ok=26 changed=7 failed=0`，其 changed 全部来自安装阶段，配置阶段未执行。

**提交版（HEAD）对照**——旧判定用数量比较，不含此缺陷：

```yaml
until: cluster_members.stdout | int >= 2
failed_when: cluster_members.stdout | int < 2
```

### 附带缺陷 3：节点名前缀正则失效（中风险）

`configurator/render.py:79`：

```python
def _rabbitmq_prefix(hostname: str) -> str:
    return re.sub(r"[-_]\d+$", "", hostname)
```

对 `"rabbitmq01"` 不匹配（无 `-` 或 `_` 分隔符），渲染结果 `rabbitmq_node_prefix: "rabbitmq01"`，而非预期的 `rabbitmq`。旧校验 `grep -c "{{ rabbitmq_node_prefix }}"` 依赖此变量，实际只会匹配到 1 个节点名，逻辑上同样是脆弱的。

---

## 四、证据链

| # | 证据 | 位置 | 说明 |
| --- | --- | --- | --- |
| 1 | `rabbitmq.deploy.failed`，last_stage=Preflight | `.runtime/state/` | 安装阶段无问题，失败发生在配置阶段 |
| 2 | PLAY RECAP：44 ok=32 / 45 failed=1 / 46 ok=26 | 日志 602-604 行 | 46 未执行加入动作 |
| 3 | 同名 PLAY 出现两次，首轮仅 44 skipping | 日志 529、555 行 | `serial: 1` 的批次划分证据 |
| 4 | `stdout` 有 2 个节点仍判失败 | 日志 599 行 | 判定条件异常的直接证据 |
| 5 | `git show HEAD:...02_configure.yml` 判定为 `int >= 2` | git 历史 | 判定逻辑本次被改写 |
| 6 | 三代渲染产物中该变量均为 `[]` | `.runtime/generations/*/secrets/playbooks/group_vars/rabbitmq.yml` | 变量从未渲染出值 |
| 7 | `deployment-plan.json` 中 rabbitmq.nodes 含 3 个节点 | `.runtime/generations/20260910T085903Z-.../config/` | 配置源正确，问题在渲染产物过期 |
| 8 | `render.py` 新增该变量行为 `+` | `git diff` | 代码已改、产物未同步 |

---

## 五、影响范围

- **受影响**：RabbitMQ 组件部署流程（配置阶段中止）
- **未受影响**：mongodb、redis（均已 verified）
- **业务影响**：取决于 RabbitMQ 是否已承载生产流量。
  - 若为新部署环境：集群停留在 2 节点、无镜像策略状态，尚未完成交付；
  - 若为存量环境重跑：集群状态为 `rabbit@rabbitmq01` + `rabbit@rabbitmq02`，**第三个节点处于未加入状态**，需确认队列镜像/仲裁副本配置是否因此不满足高可用要求。
- **数据风险**：低。失败发生在加入集群阶段，未触发删除或重置动作；`rabbitmq_rebuild_cluster: false`，未走破坏性重建路径。

---

## 六、整改建议

### 必修项

**R1 — 让分批校验只校验「本节点已入集群」**

`02_configure.yml:361` 属于分批中间态校验，不应要求全量相等。建议改为判断本节点（或至少种子节点）已出现在集群成员列表中，全量校验统一交给 `03_verify.yml:45`（该任务位于所有节点加入之后，位置正确）。

改动前需先确认非种子节点如何取得自身主机名：当前 `group_vars/rabbitmq.yml` 只有 `rabbitmq_seed_hostname`，沒有每个节点各自的 hostname 变量。可选做法（按推荐顺序）：

1. 在渲染阶段为 group_vars 增加 `rabbitmq_node_hostname`（每节点各自值），校验时 `until: ("rabbit@" + rabbitmq_node_hostname) in cluster_members.stdout`；
2. 不改变量，批次内退化为 `cluster_members.stdout | split(',') | length >= 2`（与提交版口径一致，最小改动）；
3. 打开 `gather_facts` 用 `ansible_hostname`（注意会改变现有 play 的变量假设，需回归）。

**R2 — 重新生成渲染产物**

新增渲染逻辑后必须重新生成 group_vars，或在部署入口增加「配置变更检测 → 强制重渲染 → 校验 SHA256」的门禁。当前 `.runtime/current` 指向 08:59 的产物，与代码状态不一致，这是本次故障的直接成因，也是会被反复踩到的坑。

### 建议项

**R3 — 修正节点名前缀正则**

`render.py:79` 正则改为 `r"\d+$"`，使 `rabbitmq01` → `rabbitmq`。改后需回归所有引用 `rabbitmq_node_prefix` 的位置。

**R4 — 校正任务命名**

`02_configure.yml:361` 任务名为「验证集群成员数（应 >= 2）」，实际判定是全量相等。命名与判定不一致会误导后续排查，改名或改判定二者必居其一。

**R5 — 为渲染产物增加一致性校验**

在部署前置检查中校验 group_vars 里是否存在 `CHANGE_ME` 或空列表残留，发现即中止。本次 `rabbitmq_cluster_hostnames: []` 若能被前置拦截，就不会走到 60 秒超时才暴露。

### 观察项

**O1 — RabbitMQ 4.2.9 的 cluster_status 输出格式**

当前解析依赖 `sed -n '/Disk Nodes/,/Running Nodes/p'`，本次实际能取到节点名，说明格式兼容。但 4.x 引入 Khepri 元数据存储后，该输出在不同配置下可能变化，建议后续用 `rabbitmqctl cluster_status --formatter=json`（若版本支持）替代文本解析，消除脆弱性。

**O2 — mysql 部署失败另案处理**

`.runtime/state/mysql.deploy.failed`（2026-09-09 15:43）与本次 RabbitMQ 故障无因果关系，建议单独排查。

---

## 七、待确认事项

1. **环境性质**：44/45/46 是测试环境还是已投产？决定整改的窗口与变更审批要求。
2. **集群当前真实状态**：建议在 Ansible-01 上对三个节点各执行一次 `rabbitmqctl cluster_status`，确认是否只有 2 个节点在线、46 是否处于 standalone。本次诊断未连接服务器，该结论为日志推断。
3. **重渲染是否会重置其他组件**：`mongodb`、`redis` 当前为 verified，重渲染后若 SHA256 变化可能触发重新部署，需评估影响面。
4. **队列高可用策略**：如果当前已有生产队列，2 节点状态下镜像/仲裁副本是否满足要求，需在整改前确认。

---

## 八、未验证项

以下内容本次未验证，标注以免误导：

- 未连接目标服务器，未实际执行 `rabbitmqctl` 命令；集群节点数的判断来自部署日志的 `stdout`。
- 未验证 `rabbitmq_cluster_hostnames` 重新渲染后是否能正确写入（已用当前模板与 3 节点配置做过替换逻辑的离线模拟，输出正确，但未跑完整渲染流程）。
- 未验证 RabbitMQ 4.2.9 在 Khepri 模式下的 `cluster_status` 输出是否与当前解析完全兼容。
- 未排查 mysql 部署失败，不在本次范围内。
