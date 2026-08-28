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

### 交付包自检

执行部署前，先在交付包根目录运行统一自检：

```bash
bash Automation_Script/Deploy/verify_delivery.sh
```

该检查会验证离线包 SHA256、Git LFS 指针、包目录布局、零字节文件、Shell 语法，以及模板配置中的占位符。macOS 因不提供 `dpkg-deb` 只能跳过 Debian 控制元数据检查；正式的版本、架构和依赖闭包检查必须在 Ubuntu 24.04 amd64 准备环境执行：

```bash
bash Automation_Script/Deploy/validate_deb_payloads.sh
```

使用一键向导时不需要手工创建或填写仓库根目录的 `config.env`；向导会根据交互输入生成权限为 `600` 的 `Automation_Script/Deploy/.runtime/config.env` 及运行时 `group_vars`，并在远程变更前执行配置门禁。只有采用旧的手工/自动化入口时，才需要复制 `config.env.example` 并完成 `group_vars` 配置；其中仍存在 `CHANGE_ME`、重复节点地址或重复主机名时会终止执行。

推荐使用交互式一键部署向导。它会询问管理节点、12 台数据库节点、组件密码、RabbitMQ Cookie 和 MySQL VIP，生成本机 `.runtime/` 配置后自动调用现有 Ansible 流程：

```bash
bash Automation_Script/Deploy/install.sh
```

启动时会先显示简短前置条件和变更范围，详细说明见 `Automation_Script/Deploy/部署向导说明.md`。每个组件组先输入网段前三段（例如 `10.20.14`），每个节点输入最后一段主机号（例如 `21`），也可以输入完整 IP；修改单节点时支持保留原值。部署阶段默认只显示阶段和当前 Ansible 任务，完整输出按阶段保存到 `.runtime/logs/`，需要现场排查时可使用 `bash Automation_Script/Deploy/init_ansible.sh deploy --verbose`。

向导运行过程中按提示完成信息采集即可，不需要另外编辑 `config.env`。当前测试环境需要输入 1 台 Ansible 管理节点、Redis/RabbitMQ/MongoDB/MySQL 各 3 台节点、数据库服务器上的 Linux 系统登录账号和密码（用于 SSH 登录服务器、上传文件及执行部署，不是 MySQL/MongoDB/Redis/RabbitMQ 数据库账号），以及各组件运行密码和 MySQL VIP；密码通过隐藏输入并要求二次确认。全部参数输入完成后会显示一次总览，并在部署前校验 IP、主机名、重复节点和 VIP 冲突。确认阶段输入 `n` 可进入修改菜单：选择数据库节点组后，还可以只修改节点 1/2/3 或整组重录；修改节点时显示原值，直接回车保留原值。管理节点、数据库服务器 SSH 登录信息和四类组件凭据也可以分别修改，输入 `0` 可取消部署。完成所选修改后会自动返回总览，只有输入 `y` 或直接回车确认后才会生成运行时配置并开始部署；输入 `q` 可在最终确认阶段取消。

向导生成的运行时配置、凭据摘要和密码文件位于 `Automation_Script/Deploy/.runtime/`，目录权限为 `700`，敏感文件权限为 `600`，已被 Git 忽略。MongoDB keyFile 由 Playbook 自动生成并分发到各节点，不需要手工输入。安装结束后，终端会显示安装摘要和敏感凭据文件位置；请由授权人员妥善保管，不要把该目录上传或写入验收报告。

需要自动化或已有受控配置时，仍可使用原入口：

```bash
cd Automation_Script/Deploy
cp config.env.example config.env
# 编辑 config.env 和 playbooks/group_vars/*.yml
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
├── 版本清单与SHA256.md                     # 版本和完整性校验说明
└── 操作日志.md                             # 本交付包操作记录
```

## 3. 部署前提

部署前必须确认：

1. 控制节点可以通过 SSH 访问全部数据库节点；控制节点自身以及全部数据库节点都必须满足以下条件之一：允许 `root` 通过 SSH 登录，或普通管理用户登录后可以免密提权到 `root`。当前默认管理用户为 `sysadmin`，必须通过 `sudo -n true` 验证成功；仅能输入 sudo 密码或仅能使用 SSH 密码登录，均不满足部署硬要求。
2. 控制节点和数据库节点均为 Ubuntu 24.04.x，架构、磁盘和内存满足现场规格要求。
3. 数据库节点之间的主机名解析、SSH、组件端口和集群通信端口已放通。
4. 现场已确认节点 IP、主机名、网卡名、VIP、账号和密码，并由授权人员保管。
5. 已确认统一安装方式，并准备好四类组件对应的完整离线载荷、依赖闭包和 SHA256 校验值；当前正式载荷共 46 个包，清单见 `sha256-packages.txt`。
6. 已安排断网条件下的首次部署、重复执行和故障演练窗口；正式测试环境的首次部署、服务启动、HA 验收和幂等重跑已完成，生产环境仍须替换为现场受控配置后执行。

### 权限硬要求验证

在执行初始化或部署前，逐台使用部署账号验证免密提权：

```bash
ssh sysadmin@<节点IP> 'sudo -n true && id -u'
```

命令必须成功并返回 `0`。如果现场使用 `root` 直接 SSH，则应验证：

```bash
ssh root@<节点IP> 'id -u'
```

应返回 `0`。控制节点和 12 台数据库节点均验证通过后，才允许继续执行 `init_ansible.sh`；该要求适用于首次部署、断点重跑和故障恢复。

## 4. 现场配置

交付包中的 `CHANGE_ME` 只是占位符，不能直接用于生产部署。部署前按以下顺序完成配置：

1. 编辑 `Automation_Script/Deploy/config.env`，填写控制节点、目标节点和网络参数。
2. 编辑 `Automation_Script/Deploy/playbooks/group_vars/` 下的组件变量文件，填写拓扑、版本和凭据。
3. 真实密码不得写入 README、操作日志、命令行参数或 Git；应使用现场受控配置或受控终端输入。
4. 检查每个 `CHANGE_ME` 均已替换，并确认没有重复 IP、重复主机名或 VIP 与节点地址冲突。
5. 在统一安装方式、依赖和自动化安装流程完成离线验证前，不得执行生产部署。

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