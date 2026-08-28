# 交付五：离线数据库高可用自动化部署

## 1. 项目说明

交付五是面向客户内网环境的正式交付包，用于通过 Ansible 在 Ubuntu 24.04.x 服务器上离线部署四类数据库和中间件高可用组件。本包只包含正式部署资产，不包含历史包、真实配置或临时文件。项目要求版本和统一安装口径如下：

| 服务器名称 | 操作系统 | 组件版本 | Docker 版本 |
|---|---|---:|---|
| Redis 服务器 | Ubuntu 24.04 LTS | Redis 8.2.8 | 不使用 |
| RabbitMQ 服务器 | Ubuntu 24.04 LTS | RabbitMQ 4.2.9 | 不使用 |
| MongoDB 服务器 | Ubuntu 24.04 LTS | MongoDB 8.2.12 | 不使用 |
| MySQL 服务器 | Ubuntu 24.04 LTS | MySQL 8.4.11 | 不使用 |

第三方组件统一采用 Ubuntu 24.04 amd64 `.deb` 系统软件包方式，由 Ansible 或部署脚本离线自动化安装。四类组件必须使用同一种方式，禁止混用；目标版本载荷、依赖闭包和 Ubuntu 24.04 LTS 兼容性仍须在正式准备阶段逐项验证。

部署架构保持为 Redis 主从 + Sentinel、RabbitMQ 三节点、MongoDB `rs0` 三节点副本集、MySQL GTID 异步主从 + Keepalived VIP。

> 当前交付五沿用已完成验收的正式离线载荷：正式目录共 46 个包（Redis 2、RabbitMQ 19、MongoDB 9、MySQL/Keepalived 16）。四类组件均已完成真实安装和 HA 验收；MySQL GTID 复制、Keepalived VIP、AppArmor 和 dpkg 终检通过；Keepalived 幂等重跑为 `changed=0`。完整结论见 `验收记录/交付五最终验收报告.md`。

部署节点负责执行 Ansible，数据库节点位于客户内网。安装阶段不依赖公网软件源，所有安装包均从本交付包分发。

## Clone 后部署

本交付包已包含数据库运行时 `.deb`、管理节点 Ansible/Python 离线 wheel、`sshpass` 及全部 Playbook，clone 后不需要另外下载 Redis、RabbitMQ、MongoDB 或 MySQL 安装包。本包不包含真实 `config.env`，现场必须从模板创建并填写受控配置。

```bash
cd Automation_Script/Deploy
cp config.env.example config.env
# 编辑 config.env，填写现场管理节点、12 台数据库服务器及账号信息
bash init_ansible.sh deploy
```

`config.env` 只保存现场配置，已被 Git 忽略；真实密码不得提交到仓库。部署目标必须满足 Ubuntu 24.04 amd64/x86_64，且执行主机需要预先具备 `ssh`、`sshpass`、`scp` 和 `rsync`。

## 2. 目录结构

```text
仓库根目录/
├── Automation_Script/Deploy/
│   ├── config.env.example                 # 现场部署配置模板（复制为 config.env 后填写）
│   ├── init_ansible.sh                    # 初始化、分发和部署入口
│   └── playbooks/
│       ├── group_vars/                    # 组件版本、拓扑和凭据模板
│       ├── preflights/                    # 前置检查和服务器初始化
│       └── site/                          # Redis/RabbitMQ/MongoDB/MySQL Playbook
├── 离线安装包/                             # 统一安装方式对应的离线载荷
├── 验收记录/                               # 部署验收记录模板
├── 机密配置模板/                           # 凭据管理说明
├── 版本清单与SHA256.md                     # 版本和完整性校验说明
└── 操作日志.md                             # 本交付包操作记录
```

## 3. 部署前提

部署前必须确认：

1. 控制节点可以通过 SSH 访问全部数据库节点，并具备免密 sudo 权限。
2. 控制节点和数据库节点均为 Ubuntu 24.04.x，架构、磁盘和内存满足现场规格要求。
3. 数据库节点之间的主机名解析、SSH、组件端口和集群通信端口已放通。
4. 现场已确认节点 IP、主机名、网卡名、VIP、账号和密码，并由授权人员保管。
5. 已确认统一安装方式，并准备好四类组件对应的完整离线载荷、依赖闭包和 SHA256 校验值；当前正式载荷共 46 个包，清单见 `sha256-packages.txt`。
6. 已安排断网条件下的首次部署、重复执行和故障演练窗口；正式测试环境的首次部署、服务启动、HA 验收和幂等重跑已完成，生产环境仍须替换为现场受控配置后执行。

## 4. 现场配置

交付包中的 `CHANGE_ME` 只是占位符，不能直接用于生产部署。部署前按以下顺序完成配置：

1. 编辑 `Automation_Script/Deploy/config.env`，填写控制节点、目标节点和网络参数。
2. 编辑 `Automation_Script/Deploy/playbooks/group_vars/` 下的组件变量文件，填写拓扑、版本和凭据。
3. 真实密码不得写入 README、操作日志、命令行参数或 Git；应使用现场受控配置或受控终端输入。
4. 检查每个 `CHANGE_ME` 均已替换，并确认没有重复 IP、重复主机名或 VIP 与节点地址冲突。
5. 不要直接修改 `已测试——交付三/`；交付三是测试基线，交付五是独立交付目录。
6. 在统一安装方式、依赖和自动化安装流程完成离线验证前，不得执行生产部署。

凭据配置要求详见 `Automation_Script/Deploy/config.env.example` 和 `README.md` 中的安全要求。

## 5. 部署流程

### 5.1 上传交付包

将本仓库根目录的全部内容上传到 Ansible 控制节点的工作目录，并确认 `Automation_Script/Deploy/` 与 `离线安装包/` 处于同一目录层级。

### 5.2 执行入口脚本

在控制节点执行：

```bash
cd /path/to/KNG-POS-DB-Delivery-Five
bash Automation_Script/Deploy/init_ansible.sh
```

完成初始化和前置检查后，再执行完整部署：

```bash
bash Automation_Script/Deploy/init_ansible.sh deploy
```

如果现场需要分阶段执行，应按照 `Automation_Script/Deploy/playbooks/site/` 下各组件的操作说明执行 preflight、安装、配置和验证 Playbook，不要跳过前置检查或直接执行组件配置。

### 5.3 重复执行检查

首次部署完成后，在不改变配置的情况下再次执行相关 Playbook，确认：

- 不重复创建用户、目录或服务配置；
- 不覆盖现场已确认的机密配置；
- 服务保持正常运行；
- Ansible 输出不存在新的非预期变更。

## 6. 验收要求

验收记录和最终实测结果见 `验收记录/`，至少包括：

- 四类组件版本和服务状态；
- Redis 主从状态、Sentinel 状态和故障切换结果；
- RabbitMQ 3 节点集群状态、Disk Node 数量和 Management Plugin 状态；
- MongoDB `rs.status().ok`、Primary/Secondary 角色和 keyFile 权限；
- MySQL GTID、复制线程、`read_only` 状态和 Keepalived VIP 归属；
- 断网部署结果、重复执行结果、故障演练结果和遗留问题。

当前正式测试验收结论：四类组件部署成功，服务与 HA 状态正常；正式包校验、三节点数据库/中间件验收、MySQL/AppArmor/dpkg 终检均通过。MySQL 为异步 GTID 主从，Keepalived 只负责 VIP 漂移，不自动提升 Replica，属于已知运行边界。

验收时不得把真实密码写入验收报告；命令输出中如包含凭据或敏感地址，应在归档前脱敏。

## 7. 高可用边界

本交付包实现的是组件级高可用，不等于任意灾难场景下的零中断：

- 2 AZ 部署 3 节点时，不能保证任意单 AZ 故障后仍保有多数节点和仲裁能力。
- Redis Sentinel 需要多数 Sentinel 参与故障判断和切换。
- RabbitMQ Quorum Queue 需要保有多数副本才能继续提供正常能力。
- MongoDB 副本集写入和选举需要多数成员。
- MySQL Keepalived 只负责 VIP 漂移，不负责自动提升 Replica 为可写 Primary。
- MySQL 使用异步复制，存在 RPO 大于 0 的可能；故障提升必须由 DBA 按恢复手册人工确认和执行。

详细限制、切换条件和恢复命令以本 README 第 7 节及各组件 Playbook 的操作说明为准。

## 8. 安全要求

- 数据库安装阶段禁止使用公网下载或在线安装命令。
- 不得在脚本、Playbook、README 或 Git 中提交生产密码、私钥、Cookie 或 API Key。
- 交付包复制、解压和执行过程中应限制目录权限，部署完成后清理临时凭据和安装包副本。
- 生产执行前后保留操作日志，但日志内容必须脱敏。
- 任何破坏性操作、数据清理或故障提升操作必须由现场授权人员确认。

## 9. 版本与完整性

固定版本和 SHA256 生成方式见 `版本清单与SHA256.md`。正式交付前执行并核对：

```bash
cd /path/to/KNG-POS-DB-Delivery-Five
find Automation_Script -type f -print0 | sort -z | xargs -0 shasum -a 256 > sha256-automation.txt
find 离线安装包 -type f -print0 | sort -z | xargs -0 shasum -a 256 > sha256-packages.txt
```

接收方部署前必须重新计算并比对校验值；校验失败时停止部署并核对交付来源。

## 10. 相关文档

- [版本清单与SHA256.md](版本清单与SHA256.md)
- [验收记录/交付五验收记录模板.md](验收记录/交付五验收记录模板.md)
- [验收记录/交付五最终验收报告.md](验收记录/交付五最终验收报告.md)