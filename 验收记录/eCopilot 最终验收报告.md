# eCopilot 数据库高可用部署最终验收报告

## 1. 验收结论

本报告作为 v5.0.4 的验收基线，继承 v5.0.3 的风险整改提交。eCopilot 数据库高可用部署已在 2026-09-04 完成隔离测试环境的快照恢复、SSH 门禁、离线载荷验证、首次部署、服务启动、四类组件静态健康检查、MySQL 终检和部署后 `dpkg` 审计。R-001 至 R-008、R-010 的代码、针对性验证、运行态和适用清理证据已完成；Redis、RabbitMQ、MongoDB 的真实故障切换与业务读写闭环按已批准范围延期至 v5.0.5，不作为本版本合并阻断。MySQL 仅验证固定 Primary 的可写性保护和人工恢复边界。本报告不将静态检查表述为完整 HA 故障验收；完成总体回归并履行发布审批后，可评估 v5.0.4 合并 `main`。

本报告记录的是已完成的测试环境实测结果。生产环境部署时必须替换为现场受控配置，并由授权人员确认网络、账号、密码、VIP 和故障演练窗口。

## 2. 验收范围

| 项目 | 实测结果 |
|---|---|
| 操作系统 | Ubuntu 24.04.4 LTS amd64 |
| 管理节点 | 测试环境 Ansible 管理节点，地址不在本报告重复展开 |
| 数据库节点 | 12 台，Redis/RabbitMQ/MongoDB/MySQL 各 3 台 |
| 安装方式 | 全部使用离线 `.deb` 载荷 |
| 正式包数量 | 46 个：Redis 2、RabbitMQ 19、MongoDB 9、MySQL/Keepalived 16 |
| SHA256 清单 | `sha256-packages.txt`，46 条记录 |
| Docker | 不使用 |
| 公网依赖 | 部署阶段不使用公网源或在线下载 |

## 3. 版本与载荷验收

| 组件 | 目标版本 | 实际部署版本 | 包数量 | 结果 |
|---|---|---|---:|---|
| Redis | 8.2.8 | 8.2.8 | 2 | 通过 |
| RabbitMQ | 4.2.9 | 4.2.9 | 19 | 通过 |
| Erlang | 27.3.4.16-1 | 27.3.4.16-1 | included | 通过 |
| MongoDB | 8.2.12 | 8.2.12 | 9 | 通过 |
| MySQL | 8.4.11 | 8.4.11 | included | 通过 |
| Keepalived | Ubuntu 24.04 package | 已安装并运行 | included | 通过 |

已完成以下载荷门禁：

- 正式目录所有文件均为预期 `.deb` 包；
- Debian 归档和控制元数据可在 Ubuntu 24.04 amd64 管理节点读取；
- 包版本、主包、架构和目录布局符合 eCopilot 部署要求；
- 离线 APT 模拟无未满足依赖、无包删除，且正式载荷已完成 SHA256 清单；
- 正式载荷使用 `Automation_Script/Deploy/validate_deb_payloads.sh` 校验返回 `RESULT: PASS`。

## 4. 自动化验收

| 检查项 | 结果 |
|---|---|
| 管理节点初始化 | 通过 |
| Ansible 连接数据库节点 | 12/12 `ping: pong` |
| 入口脚本 Bash 语法检查 | 通过 |
| Playbook syntax-check | 通过 |
| 正式载荷同步 | Redis 2、RabbitMQ 19、MongoDB 9、MySQL 16，全部成功 |
| 首次部署 | 通过 |
| 首次完整部署 | 通过；RabbitMQ 修复后专项重跑和后续完整流程复测通过 |
| Keepalived 幂等重跑 | `failed=0`，三节点 `changed=0` |
| `dpkg --audit` | 12 台数据库节点均为空 |
| 本轮隔离回归 | 13 台 VM 恢复并开机，12/12 Ansible ping，部署阶段和 Postflight 均 `unreachable=0 failed=0` |
| 本轮总耗时 | 22m44s，完成时间 2026-09-04 10:24:29 |

## 5. 高可用静态检查

### Redis

- 3 节点 Redis 8.2.8 服务运行正常；
- 主从复制和 Sentinel HA 配置完成；
- 服务状态和 Sentinel 验收通过。

### RabbitMQ

- 3 节点 RabbitMQ 4.2.9 集群运行正常；
- Erlang 版本统一为 27.3.4.16-1；
- Khepri 已启用；
- 集群成员为 3 个 Disk Nodes；
- Management Plugin 返回 HTTP 200；
- 无 alarm、无 network partition；
- 三节点 Erlang Cookie 哈希一致。

### MongoDB

- 3 节点 MongoDB 8.2.12 副本集 `rs0` 运行正常；
- `rs.status().ok = 1`；
- 3 个成员 `health=1`；
- Primary/Secondary 角色正常；
- keyFile 权限为 `0400`，属主为 `mongodb:mongodb`；
- 27017 端口均处于监听状态。

### MySQL

- 3 节点 MySQL 8.4.11 服务均 active；
- GTID 异步复制配置完成；
- 两台 Replica 的 `Replica_IO_Running=Yes`；
- 两台 Replica 的 `Replica_SQL_Running=Yes`；
- `Seconds_Behind_Source=0`；
- 三节点 3306 均处于监听状态；
- Keepalived 服务均 active/enabled；
- VIP `10.20.14.59` 仅绑定 Primary，Replica 不持有 VIP；
- MySQL 8.4 复制使用 `caching_sha2_password` 和 `GET_SOURCE_PUBLIC_KEY=1`；
- GTID 验收使用 `SELECT @@gtid_executed`，兼容 MySQL 8.4。

本轮 MySQL 证据还包括：两台 Replica 的 `IO=Yes`、`SQL=Yes`，
`Seconds_Behind_Source=0`，VIP `10.20.14.59` 可达且 VIP SQL 查询确认 Primary。

## 6. 安全与系统终检

- MySQL AppArmor profile 在三台节点均为 `enforce`；
- MySQL 初始化和运行期间未产生新的 `mysqld` AppArmor `DENIED` 记录；
- 12 台数据库节点 `dpkg --audit` 均为空；
- 交付包文档不包含现场密码、私钥、Erlang Cookie 或数据库认证密钥；
- 测试环境敏感配置保留在被 Git 忽略的受控文件中，不纳入正式 release；
- 生产部署仍须在现场受控终端填充凭据，不得将真实凭据写入 Git。
- 本轮测试未读取、回显或写入报告任何密码、Cookie、keyFile 或 `.runtime/config.env`
	内容；本轮运行态审计的严格敏感模式、私钥标记和 `command not found` 文件计数均为 0，敏感文件为 `600`、`.runtime` 目录为 `700`；当前正式入口进程 argv 未发现敏感参数，R-003/R-008 真实管理节点失败传播与隔离临时目录清理证据已闭环。管理节点既有 `/var/log/bootstrap.log` 保留一条通用关键词观察项，不等同于凭据泄露，且不是当前入口生成日志。
- 历史测试过程曾出现测试凭据暴露；本报告不重新调查历史工具处理链。本版本无生产环境，不执行生产凭据轮换；正式生产部署时仍须在现场受控终端填充并管理凭据。

## 7. 已知运行边界

- Redis Sentinel、MongoDB 副本集和 RabbitMQ 集群均依赖多数成员维持完整仲裁能力；
- 2 AZ 三节点部署无法保证任意单 AZ 故障后仍保有多数节点；
- MySQL 使用异步 GTID 复制，存在 RPO 大于 0 的可能；
- Keepalived 只负责 VIP 漂移，不自动将 Replica 提升为可写 Primary；
- MySQL 主库故障后的角色提升必须由 DBA 按现场故障恢复手册人工确认和执行；
- 本报告中的 Redis、RabbitMQ、MongoDB 结果仅证明部署后的服务、角色和集群静态状态正常，未证明真实故障后的业务读写、消息持久性或恢复重建；相关故障演练延期至 v5.0.5；
- 本报告证明测试环境交付包和自动化流程已验收，不替代生产环境上线前的现场配置核对和授权故障演练。
- 2026-09-04 的完整流程复测记录显示，RabbitMQ 修复后的成员收敛检查已通过，且全流程退出码为 `0`、总耗时 `22m44s`；该结果仍不等于 Redis Sentinel、RabbitMQ Quorum Queue 或 MongoDB majority 写入的真实故障恢复验收。

## 8. 交付文件

- `README.md`
- `Automation_Script/Deploy/init_ansible.sh`
- `Automation_Script/Deploy/validate_deb_payloads.sh`
- `Automation_Script/Deploy/playbooks/`
- `离线安装包/`
- `sha256-packages.txt`
- `版本清单与SHA256.md`
- `Automation_Script/Deploy/部署向导说明.md`
- `验收记录/eCopilot 验收记录模板.md`
- `验收记录/eCopilot 最终验收报告.md`
