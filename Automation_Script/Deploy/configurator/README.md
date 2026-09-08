# 统一配置核心

此目录保存 v5.0.5 的版本化纯数据配置模型。`schema.py` 是字段、类型、枚举和敏感属性的唯一权威定义；`schema/config-v1.json` 仅为生成产物，不得独立修改。

运行要求为 Python 3.9 或更高版本，仅使用标准库。生成并验证 Schema：

```bash
cd Automation_Script/Deploy/configurator
python3 generate_schema.py
python3 -m unittest discover -v -p 'test_*.py'
```

对配置文件运行结构和语义校验：

```bash
cd Automation_Script/Deploy
python3 -m configurator validate configurator/examples/config-v1.redis.json --format text
cat config.json | python3 -m configurator validate --format json
python3 -m configurator render config.json --output /tmp/ecopilot-staging --project-root "$PWD/../.."
```

启动本地离线配置工作台：

```bash
cd Automation_Script/Deploy
python3 -m configurator workbench
```

服务仅监听终端显示的 `http://127.0.0.1:<随机端口>/`。在浏览器页面输入终端显示的一次性配对码后，可分区录入管理节点、SSH、所选组件、三节点拓扑、服务参数、组件凭据和 MySQL VIP；“高级 JSON”可用于精确审阅 v1 配置。草稿仅驻留当前 Python 进程内，不写入 URL、浏览器存储或普通日志。点击“关闭”或在终端按 `Ctrl-C` 会停止服务并释放监听；关闭前需要发布的配置仍须经过后续受控生成流程。

浏览器中的提示不作为信任边界。校验和保存均由服务端共享校验器重新检查；服务拒绝非回环 Host/Origin、未配对请求、非 JSON 请求和过大请求体。配对 Cookie 为短期 `HttpOnly`、`SameSite=Strict` Cookie，不得将配对码写入 URL。

退出码 `0` 表示没有 error，退出码 `2` 表示配置无效；warning 会显示但不阻止后续处理。诊断只包含稳定错误码、JSON Pointer 路径、级别和不含秘密值的消息。静态校验不连接网络，VIP 路由和 VRRP 二层条件必须在后续网络预检中确认。

`render` 只接受一个不存在的 staging 目录，生成 `config.env`、`playbooks/group_vars/*.yml`、脱敏摘要、部署计划、配置 SHA-256 和 `managed-resources.json`。资源清单只声明本次 generation 计划新建的非敏感资源，不代表已远端核验的实际状态，不能作为清理或删除的授权依据。目录权限为 `0700`，文件权限为 `0600`；本命令不发布为当前配置，原子发布由代次管理流程负责。

正式 Bash 向导通过 NUL 分隔的标准输入调用同一渲染器，不把秘密放入命令行参数：

```bash
cd Automation_Script/Deploy
python3 -m configurator render-wizard \
	--output /tmp/ecopilot-staging \
	--project-root "$PWD/../.." \
	--runtime-playbook-dir "$PWD/.runtime/generations/<generation-id>/secrets/playbooks"
```

`render-wizard` 的字段顺序由 `legacy_input.py` 管理，仅供 `install.sh` 兼容桥调用，不作为人工输入接口。渲染失败时向导删除 staging 并保留既有 current generation。

正式向导在摘要和兼容凭据清单全部写入 staging 后，调用代次 CLI 完成发布：

```bash
generation_id=$(python3 -m configurator new-generation-id)
python3 -m configurator publish-generation \
	--runtime-dir "$PWD/.runtime" \
	--staging /tmp/ecopilot-staging \
	--generation-id "$generation_id"
python3 -m configurator current-generation --runtime-dir "$PWD/.runtime"
```

发布后的 layout 为：

```text
.runtime/
├── current                         # 0600；仅含 generation ID
├── generations/<generation-id>/   # 发布后不可变
│   ├── config/                     # 脱敏摘要、计划、资源声明、摘要哈希、安装摘要
│   └── secrets/                    # config.env、playbooks、兼容凭据清单
├── logs/                           # 跨 generation 共享
└── state/                          # 跨 generation 共享 checkpoint
```

发布器先完成权限收紧和持久化，再以 `os.replace()` 原子切换 `current`。运行中的部署只解析一次 current 并固定绝对 generation 路径，因此后续发布不会改变该次部署使用的配置。CLI 仅输出 generation ID 或路径，不输出配置和凭据内容。

当 `.runtime/current` 不存在而旧 `.runtime/config.env` 存在时，正式向导通过纯文本解析器识别旧文件，绝不 `source` 或执行其内容。解析器只接受历史生成器已知的赋值和数组语法；命令替换、变量展开、重定向、未知字段、重复赋值及不完整数组均失败停止。可单独执行脱敏检查：

```bash
python3 -m configurator inspect-legacy "$PWD/.runtime/config.env"
```

识别成功后，向导按源文件 SHA-256 在 `.runtime/legacy-backups/` 创建幂等的 `0400` 只读备份。旧格式不足以还原完整 JSON v1 配置，因此不会猜测或自动发布新 generation；用户必须通过向导重新录入。失败和重录过程均不覆盖旧文件，CLI 输出只包含摘要、组件名和重录状态，不包含秘密值。

示例中的地址来自文档保留网段，密码均为无效占位值，不可用于部署。