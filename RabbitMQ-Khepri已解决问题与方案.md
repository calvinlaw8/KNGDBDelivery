
# RabbitMQ Khepri 已解决问题与方案

本文件沉淀 RabbitMQ 4.2.9 + Khepri 离线高可用部署中已经完成代码处理或取得真实验证证据的问题。每完成一个问题，都按“问题、根因、解决方案、验证证据、边界与后续”追加记录。

## 当前范围

- 目标环境：Ubuntu 24.04 amd64，RabbitMQ 4.2.9，Erlang 27.3.4.16；控制端为 macOS。
- 本文件只记录已处理内容，不替代 [RabbitMQ-Khepri待处理问题清单.md](RabbitMQ-Khepri待处理问题清单.md)。
- “静态验证通过”只说明代码契约成立，不等同于远端真实部署通过。
- 当前已取得的真实基础证据是：RabbitMQ-only 显式重建和健康复用均完成三节点部署，三个服务均 active，Disc Nodes 为预期三节点，Management UI 返回 HTTP 200。
- 消息发布/消费闭环、健康幂等重跑和显式 Khepri 重建均已有真实证据；工作台失败指纹熔断/取消语义仍未完成，因此不扩展到 MongoDB/MySQL。

## RMQ-005/RMQ-013：健康 Khepri 集群复用启动时序

### 问题

健康集群复用时，单独启动种子节点或继续进入普通非种子 join 流程，会把已有 Khepri 集群误当作首次初始化路径，造成 leader 等待或不必要的成员校验失败。

### 根因

安装阶段会停止旧 RabbitMQ 服务，配置阶段无法仅依赖内存 fact 判断原集群是否可复用；即使保存健康判定，健康复用后的后续 join Play 仍可能缺少同一条件门控。

### 解决方案

- 在安装停服前持久化健康复用判定。
- 健康复用时并行恢复全部节点，并等待每个节点的 RabbitMQ App 可用。
- 由种子节点确认完整预期成员集合。
- 健康复用场景跳过 seed-first、非种子 `stop_app`、`reset`、`join_cluster` 和普通加入成员数 gate；只有显式重建或无健康既有集群时才进入 join Play。

### 验证证据

- 静态回归、Ansible syntax-check 和 `git diff --check` 通过。
- immutable generation `20260911T055845Z-c89097875e7ce2b2` 使用 `rabbitmq_rebuild_cluster: false` 真实部署成功。
- 日志显示三节点并行恢复、App readiness 和完整集群状态验证通过；非种子 join 相关任务均跳过。
- 三节点服务 active，Disc Nodes 精确为 `rabbit@rabbitmq01,rabbit@rabbitmq02,rabbit@rabbitmq03`，Management UI HTTP 200，Quorum Queue 发布、消费 ack、删除闭环通过；三节点 recap 均 `failed=0 unreachable=0`。

### 边界与后续

本证据覆盖 RabbitMQ-only 健康幂等重跑；工作台失败指纹熔断/取消语义仍属于独立问题，MongoDB/MySQL 仍未执行。

## RMQ-001：并行启动导致 Khepri 分裂初始化

### 问题

三个 RabbitMQ 节点同时启动，在旧状态不一致时可能分别形成单节点集群，种子节点又可能卡在 Khepri leader 初始化。

### 根因

Khepri 初始化和集群身份建立依赖稳定的启动顺序。并行启动会让多个节点同时尝试建立自己的状态，形成不同中间状态，后续不能靠增加重试次数可靠修复。

### 解决方案

- 将种子初始化和成员加入拆成明确阶段。
- 种子节点先完成服务启动、RabbitMQ App 可达和集群状态检查。
- 非种子节点使用 `serial: 1`，严格按顺序逐个加入种子节点。
- 健康集群重跑不再重复执行破坏性重建路径。

### 验证证据

- `test_rabbitmq_khepri_bootstrap.sh` 检查种子先启动、成员串行加入和破坏性阶段串行边界。
- 2026-09-10 批次 `20260910T010724Z-a4e8aeb03b63492b` 的真实部署中，`rabbitmq01` 先启动，随后 `rabbitmq02`、`rabbitmq03` 依次加入。
- 三节点 Disc Nodes 最终为 `rabbit@rabbitmq01`、`rabbit@rabbitmq02`、`rabbit@rabbitmq03`。

### 边界与后续

首次初始化和健康集群加入已有真实证据；显式 Khepri 重建路径仍需单独的破坏性验收，不能由本次首次部署替代。

## RMQ-002：RabbitMQ 启动状态判断过于粗糙

### 问题

仅根据一次 systemd 或 RabbitMQ CLI 检查判断启动完成，可能把 `activating`、Erlang node 未建立或 RabbitMQ App 未运行误判为可用。

### 根因

systemd unit active、Erlang node 可达、RabbitMQ App 可用和 `cluster_status` 成功是不同层次的状态，不能用单一检查替代。

### 解决方案

- 启动后分层检查 systemd 服务状态、Erlang node ping、RabbitMQ App ping 和集群状态。
- 只有服务为 active 且 RabbitMQ App 可达后，才记录 `seed_started` checkpoint 并进入成员加入阶段。
- 对种子节点使用有限重试；不通过时保留失败诊断，不自动切换破坏性恢复命令。

### 验证证据

- RabbitMQ Playbook syntax-check 通过。
- 静态回归检查 `seed_started` 位于 systemd active 和 Rabbit App ping 成功之后。
- 2026-09-10 首次部署三节点服务均为 active，后置集群验证成功。

### 边界与后续

当前真实证据覆盖首次部署状态；连续两次稳定检查和显式重建后的状态分类仍需专项验收。

## RMQ-003：RabbitMQ CLI 长时间无界等待

### 问题

`stop_app`、`reset` 等命令在节点状态异常时可能长时间等待，导致工作台无法及时记录明确失败阶段。

### 根因

CLI 的默认等待时间不能作为部署控制面的超时策略；Khepri leader 超时、节点未运行或命令不支持等错误也不应被盲目重试。

### 解决方案

- 对显式重建中的 `rabbitmqctl stop_app` 和 `rabbitmqctl reset` 增加 30 秒硬超时。
- 使用 `block/rescue/always` 保留失败阶段、节点和只读诊断。
- 失败后不自动执行另一套恢复命令。

### 验证证据

- `test_rabbitmq_khepri_bootstrap.sh` 检查 30 秒 timeout、rescue、always、checkpoint 和失败诊断。
- RabbitMQ Playbook syntax-check 和静态回归通过。

### 边界与后续

`join_cluster` 的超时和更细错误分类仍列在待处理清单 RMQ-003 中。

## RMQ-004：无效或不适用于 Khepri 的强制命令

### 问题

历史路径使用过 `force_boot` 和 `force_reset`，前者在实际环境返回 `enoent`，后者不适用于当前 Khepri 重建策略。

### 根因

旧命令语义来自传统 Mnesia 恢复路径，不能直接套用于 RabbitMQ 4.2.9 + Khepri；失败后继续尝试强制命令会扩大破坏性操作范围。

### 解决方案

- 从可执行 Playbook 路径移除 `force_boot` 和 `force_reset`。
- 显式重建仅保留受控的 stop/reset 路径，并要求配置开关和网页确认。
- 正常健康重跑禁止进入显式重建路径。

### 验证证据

- 静态回归明确扫描禁止命令和直接删除 Mnesia/Khepri 目录的路径。
- 2026-09-09 操作日志记录了 `force_boot` 的真实 `rc=69/enoent` 失败及移除结果。
- 当前可执行 Playbook 不含上述强制命令。

### 边界与后续

显式重建尚未完成远端真实验收；在新 generation 和完整门禁前，不执行远端 reset。

## RMQ-005：重建前缺少可恢复备份和状态快照

### 问题

破坏性操作前若没有完整快照、备份权限检查和可读性验证，失败后无法判断影响范围或保留恢复材料。

### 根因

重建会影响 RabbitMQ 节点身份、用户、vhost、Management 元数据和持久化消息；仅记录命令输出不足以构成恢复边界。

### 解决方案

- 在显式重建前采集 systemd、epmd、RabbitMQ App、`cluster_status`、Mnesia 元数据和 journal 等只读状态。
- 备份必须是普通文件、权限 `0600`，并通过 `tar -tzf` 完整性检查。
- 备份失败立即停止，不执行后续破坏性命令。
- 失败时保留 checkpoint 和只读诊断。

### 验证证据

- 静态回归覆盖快照、备份文件类型、权限、tar 可读性、checkpoint 和 rescue/always。
- Playbook syntax-check 和 `git diff --check` 通过。

### 边界与后续

备份与快照代码已完成静态保护；干净环境下的显式 Khepri 重建和旧状态恢复演练仍未通过。

## RMQ-006：集群成员验收使用模糊计数

### 问题

旧验收通过 `grep -c "{{ rabbitmq_node_prefix }}` 判断节点数量，匹配范围过宽，实际三节点集群可能显示为“节点数: 10”，也可能漏掉缺失或额外节点。

### 根因

`rabbitmq_node_prefix` 只是由种子主机名推导出的粗略前缀，不是预期节点集合；统计匹配行数也不是集合验证。

### 解决方案

- 从 Ansible `groups['rabbitmq']` 生成预期的 `rabbit@主机名` 集合。
- 解析 `rabbitmqctl cluster_status` 的 `Disk Nodes` 区块，提取节点、排序并与预期集合逐字比较。
- 验收摘要使用集合拆分后的实际长度，并同时输出节点集合。
- 在配置阶段和最终验证阶段采用相同判定规则。

### 验证证据

- 修改 [02_configure.yml](Automation_Script/Deploy/playbooks/site/rabbitmq/02_configure.yml) 和 [03_verify.yml](Automation_Script/Deploy/playbooks/site/rabbitmq/03_verify.yml)。
- `test_rabbitmq_khepri_bootstrap.sh` 增加禁止模糊节点计数的回归断言。
- RabbitMQ 静态回归、两个 Playbook syntax-check 和 `git diff --check` 均通过。

### 边界与后续

精确集合代码和首次三节点真实结果已完成；消息闭环、健康幂等重跑和显式重建仍是独立验收项。

## RMQ-007：RabbitMQ-only 配置桥接误引用未选组件

### 问题

RabbitMQ-only 批次在远端部署前因 Bash `set -u` 展开未初始化的 `REDIS_IPS[@]` 退出。

### 根因

配置渲染器和旧配置迁移器默认假设四组件数组始终存在，未适配合法的组件子集。

### 解决方案

- 渲染 `DB_IPS` 和 `DB_HOSTNAMES` 时只汇总已选组件。
- 迁移器允许合法、非空、固定顺序、不重复的组件子集，并对未知组件和错误字段 fail-closed。
- 增加 RabbitMQ-only 与 Bash `set -u` 回归测试。

### 验证证据

- 配置器全量测试 80 项通过。
- 工作台执行路径、RabbitMQ 静态回归、Bash/Ansible 语法检查和差异检查通过。
- 后续 immutable generation `20260910T010724Z-a4e8aeb03b63492b` 已完成 RabbitMQ-only 首次真实部署。

### 边界与后续

RabbitMQ-only 桥接问题已解决；其他组件的真实部署和整体 HA 验收不由本条替代。

## RMQ-009：最终验收缺少消息发布/消费闭环

### 问题

最终验收只验证服务状态、节点集合和 Management UI，不能证明 RabbitMQ 真的能够完成消息路由、消费和确认。

### 根因

验收剧本没有定义独立的测试队列、消息标记、发布结果、消费确认和测试资源清理边界；因此三节点 active 只能证明进程和管理接口可用，不能证明业务消息闭环。

### 解决方案

- 在最终 RabbitMQ 验收中通过 Ansible `uri` 调用 Management API，避免依赖目标机额外安装 `curl` 或客户端库。
- 使用随机名称的持久 Quorum Queue 和随机消息标记，避免碰撞生产队列和历史测试数据。
- 检查发布返回的 `routed=true`，再以 `ack_requeue_false` 消费并确认消息内容。
- 将删除临时队列放入 `always`，并对认证参数和消息响应启用 `no_log`。

### 验证证据

- `test_rabbitmq_khepri_bootstrap.sh` 已覆盖消息闭环任务、Quorum Queue、消费确认、清理任务和凭据日志保护。
- RabbitMQ `03_verify.yml` syntax-check、编辑器诊断和 `git diff --check` 通过。
- 当前仅完成代码和静态验证；尚未发布新 immutable generation 或取得真实远端消息闭环结果。

### 边界与后续

真实消息闭环必须在新 immutable generation 中通过工作台执行；随后仍需单独验证健康幂等重跑不触发 stop/reset/重建。显式 Khepri 重建和 MongoDB/MySQL 不由本条替代。

## RMQ-013：健康复用时孤立启动种子节点导致 Khepri leader 超时

### 问题

RabbitMQ-only 批次在离线安装完成后进入健康复用路径，但种子节点单独启动持续 `activating`，最终在 Khepri 初始化中报 `timeout_waiting_for_leader`；两个成员节点保持停止，批次在种子健康等待任务失败。

### 根因

原控制流在种子节点探测结果不可靠或服务尚未完全可用时，将已有持久化集群误判为需要首次初始化，随后停止服务并只启动种子。旧 Khepri 状态需要原有集群成员共同恢复，孤立种子无法完成 leader 初始化。

### 解决方案

- 增加对 `/var/lib/rabbitmq/mnesia` 下 `rabbit@*` 持久化节点身份的只读探测，作为健康复用判据补充。
- 健康复用且未启用显式重建时，每个 RabbitMQ 节点先执行受控的 `enable/reset-failed/start --no-block`，不执行普通路径的全节点停止。
- 原 seed-first 启动任务仅适用于首次初始化或显式重建；显式重建开关仍优先排除健康复用判据。

### 验证证据

- `test_rabbitmq_khepri_bootstrap.sh` 通过，覆盖持久化身份探测、健康复用全部节点恢复和显式重建门控。
- `git diff --check` 通过。
- 真实失败批次 `20260910T030630Z-58944a87dbf62da5` 的日志确认种子等待 72 次后失败；节点 journal 明确报 `rabbit_khepri:setup/1` 的 `timeout_waiting_for_leader`。该证据用于验证根因，不作为成功证据。

### 边界与后续

修复尚未发布到 immutable generation，也尚未取得真实健康幂等重跑和消息闭环证据。下一步必须经工作台刷新 generation、预检和部署确认后重新执行 RabbitMQ-only；MongoDB/MySQL 继续禁止推进。

## 记录规则

后续每解决一个问题，追加以下结构，并同步更新待处理清单和 [操作日志.md](操作日志.md)：

```markdown
## RMQ-xxx：问题标题

### 问题
具体现象和影响。

### 根因
已由代码、日志或实验确认的根因。

### 解决方案
实际修改和操作门禁。

### 验证证据
测试命令、Playbook 检查或真实批次证据。

### 边界与后续
尚未证明的内容、剩余风险和下一步。
```

新增记录必须遵守：不写入密码、Cookie、私钥、运行时配置原文或绝对开发机路径；静态测试、局部成功和真实远端验收必须分别表述；破坏性操作必须保留明确门禁和停止条件。
