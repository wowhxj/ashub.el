# 第一轮只读技术勘察

状态：本文为最初只读勘察的历史快照；用户随后已授权继续实现 ashub，部分客户端接口与 Hub 开发版已落地。本文记录当时的集成障碍，不代表最新实现状态，也不替代已确认需求或真实验收。当前进度见 `IMPLEMENTATION-STATUS.zh-CN.md`。

## 1. 检查范围与限制

- 检查实际 runtime 目录 `~/.emacs.d.default` 的配置和已安装客户端源码。
- 检查本机 agent 存储位置、部分日志格式、SQLite schema 和聚合数量。
- 仅运行 Claude Code 和 Codex 的帮助命令确认恢复参数，没有启动交互会话、恢复会话或发送消息。
- 没有加载用户整个 Emacs 配置，不能把源码配置等同于运行中 GUI 的实际状态。
- 未修改插件源码、客户端、用户配置或会话数据；本次只更新项目文档。
- 未读取凭据文件和认证 bridge，不在报告中复制聊天正文。
- DSH 指定源码位置在当前工具中不能作为普通目录访问，相关服务端语义未完成验证。

## 2. 实际 Emacs 环境

- shell 中 Emacs 是 `/opt/homebrew/bin/emacs`，报告 32.0.50 开发版；不等同于已确认 GUI 实例版本。
- `lisp/init-ai.el:281–292` 配置 emacs-pi 和 emacs-dsh，后者指定 desktop 连接模式。
- `lisp/init-completion.el:6–44` 配置 Vertico，在 after-init 启用；Hub 使用标准 completing-read 即可沿用，不应绑定 Vertico 私有接口。
- `lisp/init-shell.el:242–265` 配置 ghostel。
- 安装目录中同时存在 dsh-emacs 与 emacs-dsh；目标是用户指定的 emacs-dsh，不应因名字相近选错。

## 3. 客户端接口与已发现的冲突

### 3.1 ghostel：有合适的直接执行接口

源码：`~/.emacs.d.default/elpa/ghostel-20261013.1318/ghostel.el:5568–5607`。

`ghostel-exec(buffer, program, args, identity)`：

- program 与 args 分别传入 argv，不经 shell 解释。
- 返回生命周期 process，可用于检查存活状态。
- buffer 已有活跃进程时拒绝再次启动。
- 可附加 Hub 的完整会话身份；工作目录由 default-directory 提供。

建议采用此接口，不使用“启动 shell 后粘贴命令”的方式。实际原生模块加载与终端恢复尚未进行端到端验证。

### 3.2 emacs-pi：能恢复指定文件，但当前显示函数破坏布局

源码：`~/.emacs.d.default/elpa/emacs-pi/emacs-pi.el`。

- `emacs-pi--open(root, session-file)`：131–151，可直接恢复指定日志文件，但为私有接口。
- `emacs-pi--resume-record(record)`：215–234，按真实文件路径复用已有 buffer；仅判断 buffer 是否存在，未在此处确认底层连接健康。
- `emacs-pi-resume()`：255–261，没有直接传 session 的公开入口，进入自身 picker。
- `emacs-pi--show-chat(buffer)`：56–60，调用 delete-other-windows，与 Hub 保留布局的需求冲突。
- `emacs-pi-session.el:413–424` 有恢复持久化 session 的 restart；RPC 结构暴露 process，但具体存活检测与异步恢复成功信号仍需在实现设计中核实。

已有 history-list 不可直接当作 Hub 的完整元数据层：`emacs-pi-history.el:54–124` 最多读取日志前 4 MiB，使用文件修改时间排序，吞掉解析异常。这不满足已经确认的真实消息时间、准确空会话判断和错误可见性要求。

### 3.3 emacs-dsh：直接使用公开恢复命令会产生管理写入

源码：`~/.emacs.d.default/elpa/emacs-dsh/emacs-dsh.el`。

- `emacs-dsh-resume()`：2240–2251，没有 session ID 参数。
- 恢复命令在 picker 前调用 `emacs-dsh--archive-empty-sessions`，2253–2289 对符合条件的空会话调用 workspace/archiveSession；不能用于只读 Hub 枚举。
- `emacs-dsh--show(id, root)`：2053–2074 是直接打开指定会话的私有入口，但总会 delete-other-windows；不存在的 cwd 会静默退回当前项目，均与 Hub 原则不符。
- session/list 和 session/projections 是可研究的元数据接口；后者客户端注释说明无需激活 agent，但尚未从服务端源码验证无副作用。
- 客户端消费 sessionId、cwd、blank、running、updatedAt、createdAt，以及 projections.values.turnOutline 的首项 prompt；不能据此证明 prompt 就是未经改写的原始首条用户消息。
- 客户端按 updatedAt 排序；它只证明会话更新时间，不证明是最后用户／assistant 消息时间。
- 多 profile 的认证与 buffer 注册表按来源隔离仍需核查，不能假定 session ID 全局唯一。

建议：不要用全局 advice 禁用 delete-other-windows，也不要复制整套客户端。若后续获批，优先给两种原生客户端增加最小公开 resume-by-id/file 接口和可配置显示入口；具体改动必须另行征得用户同意。目前未修改。

## 4. 五种 agent 的数据与恢复能力

### Claude Code

- 默认会话目录存在：`~/.claude/projects`。
- 部分项目有 sessions-index.json，实际字段包含 sessionId、fullPath、firstPrompt、projectPath、created、modified、messageCount、isSidechain。
- 部分已读索引指向的 JSONL 在对应目录不存在，说明索引不能作为唯一权威，更不能将索引条目直接视为可恢复日志。
- 应枚举真实会话文件，再把索引当作提示信息；最终首条用户消息、最新交互和工具结果排除需要从实际 JSONL 取证。
- 帮助命令已确认：`claude --resume SESSION_ID`；不得使用 --fork-session 代替继续原会话，不附加绕过权限参数。
- CLAUDE_CONFIG_DIR 与额外数据源恢复映射、当前版本 JSONL 的注入／子会话标识和归档语义仍未充分验证。

### Codex

- `~/.codex/state_5.sqlite` 存在 threads 表，包含 id、rollout_path、cwd、source、first_user_message、has_user_event、archived、updated_at[_ms]、recency_at[_ms]、history_mode 等。
- 聚合查询观察到 75 条 thread：cli 4、exec 3、unknown 2、vscode 53（其中归档 10）、显式 subagent source 13。数量只是检查时快照，不等于最终可展示会话数量。
- 全部 75 条 history_mode 为 paginated。仅扫描 sessions 下 JSONL 会漏掉数据库中的历史，不能作为唯一发现方式。
- `thread_history_1.sqlite` 有 thread_items 和 thread_turns 等表，可进一步研究原始 userMessage 与 agent 消息时间。普通只读打开失败；仅为查 schema 使用 immutable 只读打开成功。
- immutable 方式不读取变化中的 WAL，不可直接当作活跃数据库的通用读取策略；实现需选择可一致读取的只读连接或经过验证的原生元数据接口。
- 帮助命令已确认：`codex resume SESSION_ID`，以及 `--cd DIR`。profile 与 CODEX_HOME 必须随数据源固定，不能只采用当前 shell 的默认配置。
- 首条消息和更新时间存在现成索引字段，但仍需验证原文完整性与时间来源；不使用 title 充当首句。
- 跨 Desktop／CLI 版本恢复 paginated 历史的实际兼容性尚未验证。

### Pi

- 默认 `~/.pi/agent/sessions`；还需支持 PI_CODING_AGENT_SESSION_DIR、PI_CODING_AGENT_DIR 与客户端 session-directory 配置。
- 已安装版本位于 `@earendil-works/pi-coding-agent`，不能把旧 npm 包名写死。
- `dist/core/session-manager.js:480–560` 验证：session header 有 id、cwd、timestamp、parentSession；message 有 role/content，最近交互可按用户／assistant 消息时间计算。
- `parentSession` 也用于用户主动 fork，不能仅凭该字段隐藏为内部 subagent。
- 本地目录除主日志外还有内部 run session 与 observation ledger，不应将所有 *.jsonl 无差别当作用户会话。
- `dist/cli/args.js:302–306` 支持 --session path|id；原生客户端已能传 session-file。
- 不能把“第一条用户消息没有文本”误当作没有用户输入，也不能跳过图片首句后冒充后来的文本为首句。
- 当前客户端预览读取限制、错误吞掉及 mtime 排序需要 Hub 自己规避。

### DeepSeek Harness

- 当前客户端配置为 desktop 连接模式。
- 指定 `/Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/` 在普通文件工具下报 ENOTDIR；app.asar 是归档，不能假称已读到该路径下源码。
- 通过路径发现 `~/.dsh/sessions` 下压缩日志 session.v4.jsonl.zstd、旧 session.jsonl.zstd，以及 storages/session_projcache.json。
- 这些目录尚未证明属于当前 Desktop Host 的实际 profile；不建议未经 schema/profile 验证直接抓缓存或解压日志拼接 Hub。
- 建议优先验证原生只读元数据 API；主子会话、归档、原始首句和最后消息时间仍需确认服务端契约。

### Hermes

- 默认数据库 `~/.hermes/state.db`；命名 profile 位于 profiles/<name>/state.db。
- 当前 active_profile 为 taizi，裸 hermes 会跟随 sticky profile；只设置根 HERMES_HOME 并不足以保证进入默认 profile。
- 源码确认恢复方式：`hermes -p default --resume SESSION_ID` 或显式命名 profile；`--in DIR` 固定启动目录，避免恢复时又换回历史 cwd。
- `hermes_cli/main.py:587–642` 解析 profile；1536–1563 处理 --in；1586–1633 处理恢复。
- sessions 表有 id、nullable cwd、parent_session_id、source、model_config、archived、hidden 等；messages 表有 role、content、timestamp、active、compacted、_compressed_summary、display_kind 等。
- 默认库 2 条 session；taizi 36 条，其中 subagent 32、telegram 3、desktop 1；其他三个发现的 profile 当前为 0。所有已观察 session 的 cwd 均缺失。
- 不能从数据库目录猜项目目录，也不能静默以主目录恢复，缺失 cwd 是尚未覆盖的产品决策。
- parent_session_id 不等于 subagent：压缩延续、用户分支、reset 也用该字段。应识别 _delegate_from 等明确标识，压缩链的展示身份也需处理。
- 第一条 role=user 不一定是真人消息：自动委派结果、压缩摘要也可能使用 user role，且多模态内容有编码；需要排除可确认注入。
- 时间需从合适的用户／assistant 消息计算；last_activity_at 和 ended_at 均不等于准确的最后对话时间。
- 实际库有 schema 差异，不得仅按 checkout 最新 DDL 查询所有 profile。
- 不应实例化写入型 SessionDB 来枚举，它的构造可能迁移／修复数据库；只读 SQL 或经验证无副作用接口更合适。

## 5. 建议实现方向（未批准）

1. 统一会话记录：agent、数据源身份、原始完整 ID、恢复定位符、cwd、首条用户消息、时间及其来源、状态与诊断。
2. 每个 agent 单独负责发现和元数据解析，启动入口与元数据读取分离。
3. UI 使用 Emacs 原生只读列表与 completing-read；分组、过滤、选中保持均基于完整身份，不基于显示文本。
4. 三种终端 agent 通过 ghostel-exec 直接 argv 启动；Pi、DSH 优先等待明确、布局安全的客户端接口。
5. 读库必须显式只读；JSONL 处理部分写入与损坏记录时保留诊断。不得把截断扫描当作准确空会话判定。
6. 大批扫描不能简单在主线程一次性全读；异步工作方式与额外运行依赖尚未决定，不承诺现阶段纯 Elisp 即可覆盖所有格式。
7. 先做合成数据测试和只读真实数据校验；实际恢复及发送消息等写入测试，按已确认原则单独选择测试会话并征得确认。

## 6. 优先待决策与后续验证

1. 原始 cwd 完全缺失时，是否显示“未知”，首次恢复时让用户选目录；选定目录是否仅内存按来源身份记忆。
2. 是否批准为 emacs-pi、emacs-dsh 提供最小公开恢复／显示接口；先提交具体最小改动方案再决策。
3. DSH 服务端契约需要可读且版本匹配的源码或文档；目前不能宣称已具备完整支持。
4. 核实 Claude 新日志、Codex paginated history、Pi 内部 run 的精确分类规则。
5. 数据源的存储根与启动 profile 不能混为一谈；需要明确配置和验证。
6. package 名称、额外依赖、异步方式、具体显示及性能指标仍需后续确认。

结论：Hub 方向可继续推进，但目前不能直接进入“把几个 resume 命令接起来就完成”的实现。客户端窗口副作用、DSH 枚举前自动归档、Codex 分页历史以及 Hermes 缺少项目目录，都是真实存在的适配问题。
