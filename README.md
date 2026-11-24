# eCopilot 数据库高可用部署

## 1. 项目说明

本项目是面向客户内网环境的正式交付包，用于通过 Ansible 在 Ubuntu 24.04.x 服务器上离线部署四类数据库和中间件高可用组件。本包只包含正式部署资产，不包含历史包、真实配置或临时文件。项目要求版本和统一安装口径如下：

测试环境必须使用明确隔离的测试设备和受控测试流程；普通 `install.sh` 和 `init_ansible.sh deploy` 不会自动重置服务器。测试重置脚本和测试记录属于仓库内部材料，不纳入客户交付包。

| 服务器名称      | 操作系统         |       组件版本 | Docker 版本 |
| --------------- | ---------------- | -------------: | ----------- |
| Redis 服务器    | Ubuntu 24.04 LTS |    Redis 8.2.8 | 不使用      |
| RabbitMQ 服务器 | Ubuntu 24.04 LTS | RabbitMQ 4.2.9 | 不使用      |
| MongoDB 服务器  | Ubuntu 24.04 LTS | MongoDB 8.2.12 | 不使用      |
| MySQL 服务器    | Ubuntu 24.04 LTS |   MySQL 8.4.11 | 不使用      |

第三方组件统一采用 Ubuntu 24.04 amd64 `.deb` 系统软件包方式，由 Ansible 或部署脚本离线自动化安装。四类组件必须使用同一种方式，禁止混用；目标版本载荷、依赖闭包和 Ubuntu 24.04 LTS 兼容性仍须在正式准备阶段逐项验证。

部署架构保持为 Redis 主从 + Sentinel、RabbitMQ 三节点、MongoDB `rs0` 三节点副本集、MySQL GTID 异步主从 + Keepalived VIP。

> 当前正式离线载荷共 46 个包（Redis 2、RabbitMQ 19、MongoDB 9、MySQL/Keepalived 16）。四类组件均已完成测试环境真实安装、服务启动和静态健康检查；MySQL GTID 复制、Keepalived VIP、AppArmor 和 dpkg 终检通过；Keepalived 幂等重跑为 `changed=0`。Redis、RabbitMQ、MongoDB 的真实故障切换与业务读写闭环仍需独立演练，不能将本段表述为完整 HA 故障验收。

部署节点负责执行 Ansible，数据库节点位于客户内网。安装阶段不依赖公网软件源，所有安装包均从本交付包分发。

## Clone 后部署

本交付包已包含数据库运行时 `.deb`、管理节点 Ansible/Python 离线 wheel、`sshpass` 及全部 Playbook，clone 后不需要另外下载 Redis、RabbitMQ、MongoDB 或 MySQL 安装包。本包不包含真实 `config.env`，现场必须从模板创建并填写受控配置。

离线载荷通过 Git LFS 管理。请勿使用 GitHub 的“Download ZIP”下载本仓库；ZIP 下载通常只会保留若干 KB 的 LFS 指针文件。

克隆并还原离线载荷：

```bash
git clone <仓库地址>
cd <仓库目录>
git lfs install
git lfs pull
bash Automation_Script/Deploy/verify_delivery.sh
```

如果仓库已经克隆但首次没有安装 Git LFS，Windows 用户使用 PowerShell：

```powershell
cd <仓库目录>

# 已安装 Git for Windows 时可在此重启已打开的终端
git lfs install
git lfs pull origin main
git lfs checkout

git lfs status
git lfs fsck
Get-ChildItem -Recurse ".\离线安装包" -Filter "*.deb" |
  Measure-Object Length -Sum
```

如果 PowerShell 中的 `git lfs` 命令不存在，请先安装 Git LFS：

```powershell
winget install --id Git.GitLFS -e
```

安装完成后关闭并重新打开 PowerShell 或 Git Bash，再执行上述 `git lfs install`、`git lfs pull` 和 `git lfs checkout`。

macOS/Linux 用户若仓库已经克隆但载荷仍显示为几 KB 的指针：

```bash
cd <仓库目录>
git lfs install
git lfs pull origin main
git lfs checkout
git lfs fsck
```

若安装了 Git LFS 但仍看到“LFS 文件尚未还原为真实载荷”，先重新执行 `git lfs install && git lfs pull`，再运行交付校验。仓库克隆完成后，离线载荷目录中的每个包应为实际 `.deb`/归档文件，而不是以 `version https://git-lfs.github.com/spec/v1` 开头的文本指针。

### Windows 运行方式

当前正式入口仅支持 macOS Bash 和 Ubuntu 24.04 amd64，不支持在 Windows PowerShell、Git Bash、MSYS 或 Cygwin 中直接运行 `install.sh`。不要双击 `.sh` 文件，也不要使用“打开方式”选择文本编辑器。

Windows 用户应使用 WSL2 安装 Ubuntu 24.04，并在 WSL2 内完成克隆、Git LFS 拉取和部署：

```powershell
wsl --install -d Ubuntu-24.04
```

进入 WSL2 Ubuntu 后：

```bash
sudo apt-get update
sudo apt-get install -y git git-lfs bash python3 rsync sshpass openssh-client
git lfs install

git clone <仓库地址>
cd <仓库目录>
git lfs pull origin main
bash Automation_Script/Deploy/verify_delivery.sh
bash Automation_Script/Deploy/install.sh
```

如果在 Windows Git Bash 中执行 `install.sh`，脚本会明确拒绝并提示切换到 WSL2 Ubuntu 24.04，不会将其误用为受支持的部署环境。

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

推荐使用一键部署入口。它会在本机启动仅回环监听的网页配置工作台，并自动打开浏览器；管理节点、12 台数据库节点、组件密码、RabbitMQ Cookie 和 MySQL VIP 均在网页中填写，终端不再逐项要求输入：

```bash
bash Automation_Script/Deploy/install.sh
```

启动时会首先显示 SSH 主机指纹风险提示：首次连接目标主机时不人工验证指纹，该方式仅适用于受控部署网络，不建议在不可信网络中执行。终端会显示仅本机可访问的 URL 与一次性配对码；在浏览器输入配对码后，依次填写配置、执行连接预检、生成配置，并在页面的最终确认框中启动部署。网页内可用三节点拓扑生成器批量填写同网段 IP 与主机名；不同组件组可以使用不同网段，但 Redis、RabbitMQ、MongoDB 跨三层网络时必须具备双向路由、主机名解析和组件端口连通性；MySQL Keepalived VIP 使用 VRRP，三个 MySQL 节点与 VIP 原则上应位于同一二层广播域。部署执行状态显示在网页中，完整输出按阶段保存到 `.runtime/logs/`。

整组录入节点时会先连续录入 3 个节点 IP，再设置主机名前缀。普通前缀例如 `redis-node`，节点输入 `1`、`2`、`3` 会生成 `redis-node1`、`redis-node2`、`redis-node3`；以数字结尾的前缀例如 `T-Redis-0`，节点输入 `1`、`2`、`3` 会生成 `T-Redis-01`、`T-Redis-02`、`T-Redis-03`。节点主机名输入项也可以直接输入完整主机名；留空前缀则逐台输入完整主机名。所有节点主机名必须唯一。

向导运行过程中按提示完成信息采集即可，不需要另外编辑 `config.env`。当前测试环境需要输入 1 台 Ansible 管理节点、Redis/RabbitMQ/MongoDB/MySQL 各 3 台节点、数据库服务器上的 Linux 系统登录账号和密码（用于 SSH 登录服务器、上传文件及执行部署，不是 MySQL/MongoDB/Redis/RabbitMQ 数据库账号），以及各组件运行密码、MySQL VIP 和独立的 MySQL VIP 验证账号密码；密码通过隐藏输入并要求二次确认。VIP 验证 SQL 在 Primary 节点经 VIP 执行，因此验证账号仅允许 Primary 精确 IP 来源访问，不复用 root 密码；管理节点仅负责 VIP 网络可达性检查。全部参数输入完成后会显示一次总览，并在部署前校验 IP、主机名、重复节点和 VIP 冲突。确认阶段输入 `n` 可进入修改菜单：选择数据库节点组后，还可以只修改节点 1/2/3 或整组重录；修改节点时显示原值，直接回车保留原值。管理节点、数据库服务器 SSH 登录信息和四类组件凭据也可以分别修改，输入 `0` 可取消部署。完成所选修改后会自动返回总览，只有输入 `y` 或直接回车确认后才会生成运行时配置并开始部署；输入 `q` 可在最终确认阶段取消。

向导生成的运行时配置和安装摘要位于 `Automation_Script/Deploy/.runtime/`，目录权限为 `700`，敏感文件权限为 `600`，已被 Git 忽略。默认流程不会生成额外的明文凭据清单；如确需导出，必须在向导中明确选择并输入 `EXPORT` 二次确认，生成的 `credentials.txt` 会包含管理节点 SSH、数据库服务器 SSH、所选组件服务凭据、RabbitMQ Cookie、MySQL Keepalived 认证、节点 IP/主机名和 VIP。MongoDB keyFile 由 Playbook 自动生成并分发到各节点，不需要手工输入。终端不会显示明文凭据；导出后仅由授权人员在受控终端查看：`less Automation_Script/Deploy/.runtime/credentials.txt`。不得复制到终端、现场记录或 Git；移交客户密码管理器后，应清理本地 `.runtime/` 并轮换已交付凭据。

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
├── 版本清单与SHA256.md                     # 版本和完整性校验说明
└── sha256-packages.txt                     # 离线载荷 SHA256 校验清单
```

## 3. 部署前提

部署前必须确认：

1. 控制节点可以通过 SSH 访问全部数据库节点；控制节点自身以及全部数据库节点都必须满足以下条件之一：允许 `root` 通过 SSH 登录，或普通管理用户登录后可以免密提权到 `root`。当前默认管理用户为 `sysadmin`，必须通过 `sudo -n true` 验证成功；仅能输入 sudo 密码或仅能使用 SSH 密码登录，均不满足部署硬要求。
2. 控制节点和数据库节点均为 Ubuntu 24.04.x，架构、磁盘和内存满足现场规格要求。
3. 数据库节点之间的主机名解析、SSH、组件端口和集群通信端口已放通。
4. 现场已确认节点 IP、主机名、网卡名、VIP、账号和密码，并由授权人员保管。
5. 已确认统一安装方式，并准备好四类组件对应的完整离线载荷、依赖闭包和 SHA256 校验值；当前正式载荷共 46 个包，清单见 `sha256-packages.txt`。
6. 已安排断网条件下的首次部署、重复执行和故障演练窗口；当前正式测试环境的首次部署、服务启动和 RabbitMQ 修复后的专项/完整流程验证已完成，Redis、RabbitMQ、MongoDB 真实故障演练仍待完成，生产环境仍须替换为现场受控配置后执行。

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
3. 真实密码不得写入 README、现场记录、命令行参数或 Git；应使用现场受控配置或受控终端输入。
4. 检查每个 `CHANGE_ME` 均已替换，并确认没有重复 IP、重复主机名或 VIP 与节点地址冲突。
5. 在统一安装方式、依赖和自动化安装流程完成离线验证前，不得执行生产部署。

凭据配置要求详见 `Automation_Script/Deploy/config.env.example` 和 `README.md` 中的安全要求。

## 5. 部署流程

### 5.1 上传交付包

将本仓库根目录的全部内容上传到 Ansible 控制节点的工作目录，并确认 `Automation_Script/Deploy/` 与 `离线安装包/` 处于同一目录层级。

### 5.2 执行入口脚本

在控制节点执行：

```bash
cd /path/to/ecopilot-deployment
bash Automation_Script/Deploy/init_ansible.sh
```

完成初始化和前置检查后，再执行完整部署：

```bash
bash Automation_Script/Deploy/init_ansible.sh deploy
```

`deploy` 会在任何 SSH、软件安装或远端配置变更前展示组件、目标节点、选中组件离线载荷版本、控制面写入范围和数据保护边界，并要求明确输入 `y` 才继续。受控自动化需显式传入 `--yes`，例如 `bash Automation_Script/Deploy/init_ansible.sh deploy --components mongodb --yes`；未传入 `--yes` 的非交互执行会安全退出。`verify` 属于非变更验证，不要求该确认。

如果现场需要分阶段执行，应按照 `Automation_Script/Deploy/playbooks/site/` 下各组件的操作说明执行 preflight、安装、配置和验证 Playbook，不要跳过前置检查或直接执行组件配置。

控制面文件按组件归属块维护：局部部署只更新所选组件对应的 `/etc/hosts` 映射和 Ansible inventory 组，保留其他组件块，并在写入前检查标记配对、地址和主机名唯一性、inventory 解析及候选差异。若管理节点仍有旧版全局受管块，必须先用完整四组件拓扑完成一次迁移；局部部署会安全停止。

### 5.3 选择组件与失败后继续

正式入口支持选择需要执行的组件；未选组件不会执行对应安装、配置或验证 Playbook，也不会被自动卸载、重装或回退：

```bash
# 仅部署 MongoDB
bash Automation_Script/Deploy/init_ansible.sh deploy --components mongodb

# 从 MongoDB 开始继续，依次执行 MongoDB 与 MySQL
bash Automation_Script/Deploy/init_ansible.sh deploy --from mongodb

# 仅检查 MongoDB 运行状态与相关节点 dpkg 状态，不执行安装或配置
bash Automation_Script/Deploy/init_ansible.sh verify --components mongodb
```

组件顺序固定为 Redis、RabbitMQ、MongoDB、MySQL。某一组件失败时，入口停止后续组件，并按操作类型在 `.runtime/state/` 写入 `组件.deploy.failed` 或 `组件.verify.failed`；组件验证成功后写入对应的 `.verified`。状态文件仅保存操作类型、阶段、日志路径、选中组件的节点拓扑摘要、离线载荷清单摘要和入口脚本摘要，不保存凭据或完整配置哈希。状态仅用于定位和继续部署，不会使入口自动跳过实际预检或服务验证；配置、载荷或脚本摘要变化时，既有记录只可作为排障线索，不能作为续装判断依据。使用向导时，如本机已有 `.runtime/`，启动菜单可选择“使用既有配置继续部署”。

`verify --components` 只执行选中节点的 Preflight、组件运行状态验证和 `dpkg` 审计，不执行安装、配置、重建或数据清理；该入口会受控写入本地日志和 checkpoint，因此属于非变更验证而非绝对只读。首次交互向导支持选择一个或多个组件，只要求录入本次所选组件的完整有效拓扑；未选组件无需填写占位 IP 或主机名。后续使用既有运行时配置追加组件时，向导会保留已部署组件的控制面记录，并将本次新增组件增量合并到管理节点的 hosts 和 inventory。若选择重跑既有组件或从失败组件继续，仍会执行实际预检和验证，不会因 checkpoint 自动跳过。

选择组件后，部署入口只向所选组件节点分发公钥、配置临时 sudo、设置主机名并执行连通性检查；离线包同步、Preflight 和组件 Playbook 也只处理所选组件。管理节点的 `/etc/hosts` 与 Ansible inventory 仍维护现场已配置的完整拓扑，避免后续从失败组件继续时移除已部署组件的控制面映射；执行 Playbook 时通过 Ansible `--limit` 确保未选节点不被连接或修改。

### 5.4 重复执行检查

首次部署完成后，在不改变配置的情况下再次执行相关 Playbook，确认：

- 不重复创建用户、目录或服务配置；
- 不覆盖现场已确认的机密配置；
- 服务保持正常运行；
- Ansible 输出不存在新的非预期变更。

### 5.5 生产环境回退与重装边界

本交付包提供失败停止、阶段日志、组件级安全重试和显式继续部署；不提供跨组件事务回滚，也不会自动恢复服务器到安装前状态。临时 sudo 授权、临时脚本和敏感临时文件会在流程退出时清理，但已安装软件包、受管配置、系统用户、服务状态和数据库集群状态不会被自动撤销。

生产恢复必须区分以下操作：

| 操作 | 当前支持 | 默认数据策略 |
| --- | --- | --- |
| 从失败组件继续 | 支持 `--from` 或向导续装 | 保留数据 |
| 指定组件重跑 | 支持 `--components` | 保留数据 |
| 卸载但保留数据 | 尚未自动化 | 必须人工授权 |
| 清空数据并重建 | 尚未自动化 | 必须人工授权 |
| 恢复到安装前完整状态 | 不由本交付包自动提供 | 依赖现场快照或备份 |

MongoDB 副本集、RabbitMQ Mnesia、MySQL GTID 与数据目录均不是可由普通包卸载无损还原的状态。生产变更前应由现场创建 VM 或磁盘快照，并确认数据库备份及恢复责任人；现场没有快照能力时，只能按受管配置和显式恢复手册尽力恢复，不能承诺回到安装前状态。

MySQL 初始化前会检查数据目录：已存在 `mysql` 系统库时保留数据；目录不存在或为空时才可初始化；目录非空但未识别为已初始化时会失败停止，绝不自动删除失败残留或既有数据。该场景必须由授权人员确认后按重建流程处理。

## 6. 验收要求

部署完成后应由现场按自身变更管理流程记录四类组件版本、服务状态、复制状态、VIP 归属和遗留问题。MySQL 为异步 GTID 主从，Keepalived 只负责 VIP 漂移，不自动提升 Replica，属于已知运行边界。

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
- 生产执行前后由客户按变更管理要求保留脱敏现场记录。
- 任何破坏性操作、数据清理或故障提升操作必须由现场授权人员确认。

## 9. 版本与完整性

固定版本和 SHA256 生成方式见 `版本清单与SHA256.md`。正式交付前执行并核对：

```bash
cd /path/to/ecopilot-deployment
find Automation_Script -type f -print0 | sort -z | xargs -0 shasum -a 256 > sha256-automation.txt
find 离线安装包 -type f -print0 | sort -z | xargs -0 shasum -a 256 > sha256-packages.txt
```

接收方部署前必须重新计算并比对校验值；校验失败时停止部署并核对交付来源。

## 10. 相关文档

- [版本清单与SHA256.md](版本清单与SHA256.md)
