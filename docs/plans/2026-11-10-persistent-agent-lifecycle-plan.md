# 五种 Agent 的持久运行与统一生命周期

日期：2026-11-10
状态：实施计划；尚未实现。Pi 持久 RPC 原型通过，正式 bridge 已确认使用 Node。DSH 真实任务续跑及多 Host 隔离待验证；按用户最新补充，DSH 不要求与 Pi 相同的显式 finish。
涉及仓库：ashub、emacs-pi、emacs-dsh。

前置只读核对结果见 `docs/research/2026-11-10-persistence-prerequisites.md`：用户已确认随包 Node 标准库 bridge。DSH cancel 保留队列且不等待结束的发现仍有效，但用户随后确认 DSH C-c C-q 保持仅关闭界面，因此停止为统一 finish 而探索 Host companion plugin；未安装插件或更改 Desktop。

## 1. 已确认需求与纠正

用户直接按 F6 启动 emacs-pi / emacs-dsh，也必须获得与 ashub 入口相同的持久运行能力。不能仅改 ashub，也不能将 Pi 从 Emacs RPC 聊天界面替换成终端 TUI 来规避问题。

统一操作语义：

| 操作 | 语义 | 历史 |
|---|---|---|
| 普通 kill-buffer / 关闭界面 | 断开当前客户端；后台继续运行或等待交互 | 保留 |
| 正常退出 / 强制结束 Emacs | 同上；不依赖退出 hook 才能保活 | 保留 |
| 取消当前任务 | 停止当前执行，但仍可继续该 session；不等于结束实例 | 保留 |
| Pi / Claude / Codex / Hermes 的 C-c C-q | 用户明确确认结束当前运行实例；阻止队列继续执行，停止任务并释放专属资源 | 保留 |
| DSH 的 C-c C-q | 关闭当前 Emacs 聊天界面；继续使用原 Host/session，不停止任务或清空队列 | 保留 |
| 打开指定历史 | 先重连同一活跃实例；不存在时才启动并恢复指定历史 | 保留 |
| 新建 | 创建独立新 session，不能以 cwd 相同为由错误复用另一段历史 | 新建 |

用户最新补充：DSH 因 Desktop/共享 Host 模型特殊，C-c C-q 保留只关闭界面的行为；不再追求五种 Agent 按键语义完全相同。其他四种 Agent 的 C-c C-q 是“人为结束运行”，不是模型任务成功的判断。DSH managed 模式仍纳入持久化，不能静默降级为 Emacs 持有的临时 Host。

不要求五种 Agent 底层实现完全相同；要求入口无关、所有权清晰、生命周期语义一致。不承诺电脑重启、Host/bridge 崩溃或系统断电后原地继续执行；此时应报告运行实例丢失，提供历史恢复，不自动重发可能已执行的任务。

首个验证平台为当前 macOS；Unix socket / POSIX 进程实现不能直接宣称支持 Windows。正式引入平台依赖前检查三个仓库的支持声明；其他平台需等价机制与独立测试，或明确拒绝持久模式，不能静默提供较弱保证。

## 2. 当前证据与边界

### 当前代码

- ashub：`ashub-open.el` 用 ghostel 直接启动 Claude / Codex / Hermes；Pi、DSH 调用各客户端公开新建/恢复 API。当前进程表主要位于 Emacs 内存，不足以跨重启发现后台实例。
- Pi：`emacs-pi-rpc.el` 直接 make-process，使用 pipe 读写 stdio；关闭 RPC 会发送 EOF / 删除进程。`emacs-pi.el` 的新建与恢复 API、`emacs-pi-session.el`、`emacs-pi-ui.el` 的生命周期要一起检查，不能只修 F6 绑定。
- DSH：`emacs-dsh.el` 的 managed Host 由 Emacs 持有，`kill-emacs-hook` 调用 managed-stop。Desktop Host 则由桌面应用持有。公开 API 有 list/open/create/read；现有 `session/cancel` 明确保留 pending messages，因此不足以实现结束。

### Pi 最小验证通过的范围

真实 Pi RPC；独立 bridge 持有 stdin/stdout；实际 Emacs batch 客户端正常退出 / SIGKILL 后，同一个 Pi PID 完成受控 RPC bash 任务。无人连接期间每个任务输出约 1 MiB；Python 客户端重连后按序补回事件和成功响应，get_state/get_messages 验证 session 身份和完成内容。未调用模型，未使用真实用户会话。

这证明“进程所有权独立 + 持续消费 + 新客户端重连”的可行性，不证明现有 emacs-pi UI、模型流、审批、队列或 bridge 崩溃恢复已经实现。原型发现 asyncio 默认 64 KiB 单行上限会中断读取；正式实现必须明确记录大小、背压与存储策略。

### DSH 已验证的范围

独立 Emacs batch 客户端两次 session/list 成功；退出后 Desktop Host PID 与父子关系保持不变。尚未验证真实任务断连续跑、指定 session 的真实快照重连、待审批恢复与 session 结束资源释放。

历史参考：ai-memory `default/ashub:sessions/01a1c36d-45a5-7338-a359-4fdd32fe7bba.md`。历史摘要只用于定位；本轮用户确认及当前代码、原型证据优先。

## 3. 架构与仓库职责

```text
Claude / Codex / Hermes:
  ashub -> ghostel 连接层 -> tmux -> Agent CLI

Pi（ashub 与 F6 同路）:
  ashub -> emacs-pi 公共 API --+
  F6 -> emacs-pi 交互命令 ----+-> 可重连本地传输 -> 独立 RPC bridge -> Pi RPC

DSH（ashub 与原生入口同路）:
  ashub -> emacs-dsh 公共 API -+
  原生命令 -------------------+-> Desktop Host
                              或独立托管 managed dsh web Host
```

- ashub 不实现另一套 Pi supervisor，也不调用客户端私有状态判断已结束。
- emacs-pi 自己拥有进程发现、互斥、重连、状态重建与结束 API。原型 Python 不是正式运行时选型；用户已确认正式使用随包 Node 标准库 `.mjs` bridge，无 npm 依赖；独立 Node 路径预检、包资源部署与平台支持仍需实现验证，不因实验用了 Python 就添加用户环境依赖。
- emacs-dsh 自己拥有 Desktop/managed 发现、Host 身份隔离、断连重连与界面 detach；不再要求目标 session finish。managed Host 独立托管机制属于此仓库，不由 ashub 创建。
- 不引入新的跨仓库通用 supervisor 框架。统一操作契约，不强求三个仓库共享内部实现或一个 Emacs 专用守护进程。

## 4. 生命周期与身份契约

逻辑操作名称（不是已存在的 API）：ensure/create、attach/open、inspect、detach，以及 Pi/终端实例的 finish。保留现有 create/open 的调用形状及回调方式；Pi 添加公开 inspect/detach/finish，DSH 提供持久 Host 发现/inspect/重连与 detach，不要求补充 session finish。明确取消回调不等于取消任务或回滚已发送命令。

状态至少区分三个维度：

- 运行状态：starting / running / waiting / stopping / finished-by-user / exited / failed / unknown。
- 连接状态：attached / detached / reconnecting / disconnected。
- 历史：session 是否可恢复；不从运行状态反推历史删除、归档或任务成功。

终止超时/失联必须是 stopping 或 unknown，不能乐观显示 finished。运行实例退出、用户结束、任务自然 idle 是不同事件；idle 不自动关闭进程，因为同一 session 还可继续交互。进程自然退出应回收其专属 supervisor/tmux 空壳；保留退出摘要，不能当作用户确认完成。

身份：来源/profile + canonical storage root/path 或权威 session ID；每次运行有 generation。Pi 初建尚无 sessionFile 时使用临时 instance ID，确认实际文件后原子绑定，不能按 cwd 匹配。DSH 使用 Host profile 身份和 generation 校验；端口、nonce 可变化，不能仅以 session ID 跨 profile 误连。

并发：两个 Emacs 同时打开同一实例必须串行化；默认一个控制租约，另一个明确报告已占用，不偷接控制或另启 writer。只读 inspect 不取得控制权、不启动实例。旧连接的回调/请求不能影响新 generation。

成功返回必须携带已验证 session 与 instance 身份。写请求发送后断线、无法确认响应时标为 uncertain，不自动重发 prompt、审批、create、finish 等有副作用操作；通过查询/已记录响应进行对账。所有管理操作限定当前用户与明确所有权。

## 5. emacs-pi 实施范围

### 后台 bridge

- 独立启动，不继承 Emacs 的存活要求；持有 Pi stdio 并始终消费 stdout/stderr。客户端 EOF 仅释放连接，不关闭 Pi stdin。
- 本地私有 IPC、受限目录/文件权限、锁及实例发现记录；拒绝 symlink/不可信路径。记录配置指纹与版本，不记录凭据到公开元数据。避免 PID 复用误杀；校验 generation、握手与所有权。
- 独立请求 ID / generation，串行化写入，受控背压。stderr 不混入 JSONL 协议。严格 LF 分帧，支持合法 Unicode；大记录、畸形记录、磁盘满、连接断裂均有明确策略。
- 有界 replay journal 与单调序号，区分收到、应用、确认。快照与事件增量之间有水位线，避免重复或丢失。超出保留范围明确要求重新同步，不能静默跳过。日志包含会话内容，应私有保存、限制大小并在结束后清理或轮转。
- bridge 崩溃不保证 Pi 继续；需明确检测和失败状态。Pi 退出后 bridge 退出并清理 socket/锁；退出结果留在独立摘要。后续重开不靠常驻空 bridge 提供旧状态。

### 原生客户端

- create/open/F6、历史恢复、fork、restart 等入口统一经 bridge；保留现有 Emacs 聊天界面和 session 校验。
- buffer cleanup 与 RPC transport detach 分离；用户 C-c C-q 调用显式 finish。断开不清空服务端队列、不发送 EOF、不 abort 模型。
- 重连读取权威 get_state/get_messages 及必要队列/运行信息，合并水位线后的事件；保留 draft，避免重复渲染/重复提交。审核 emacs-pi 队列哪些仅存在 Emacs 内存：已承诺可自动执行的队列必须托管到持久层；不能以 UI 队列丢失假装续跑完成。
- 无客户端时审批/extension UI 等待重连；不默认同意，不假装回答。恢复时区分原始请求仍有效与已取消/超时。
- finish 阻止新任务与队列启动，按协议停止执行并等待受控退出；超时后只有用户明确选择才强制终止。结束一个实例不杀其他 Pi。验证执行子进程清理，不只确认顶层 PID 消失。
- 结束不删 JSONL。之后可从历史再次启动新 generation；跨旧 cwd 的恢复/fork 策略不得回退。

## 6. emacs-dsh 实施范围

### Desktop 与 managed

- Desktop 保留现有 bridge；关闭 Emacs 不停止 Desktop、不删除 Desktop bridge 文件。
- managed dsh web 由独立生命周期托管，生成/保存受限实例发现信息，启动时握手，Emacs 重启后重新认证/重连；不以“端口可连”作为身份验证。
- 移除 kill-emacs 对持久 managed Host 的自动停止；保留单独、明确的 Host shutdown 操作，并在有其他 session 使用时拒绝隐式关闭。
- 修正当前全局 cookie/socket/events 架构对多 Host 的隔离缺口；至少显式拒绝同时跨 Host 的不安全操作，不能复用错误凭据或关闭别的 profile 资源。

### DSH C-c C-q 与重连

按用户最新补充，保留 DSH C-c C-q 的界面关闭行为：只释放当前客户端连接及界面资源，保留 Host/session/队列；不自动 cancel、archive、delete 或卸载 Agent。重新打开复用原 Host 与精确 session 身份，不另启重复 Host 或 writer。

不为与 Pi 按键一致而安装 Host companion plugin。此前关于 cancel/finish 的只读研究保留为限制说明，不再作为实施阻塞。独立的“取消当前任务”仍沿用 Host 真实协议，不混同于结束实例。

managed Host 空闲回收只允许在能权威确认没有其他运行/等待/队列任务及外部客户端依赖时启用；否则保留共享基础服务并可显式 shutdown。专属运行资源与共享 Host 基础资源必须在文档/状态中区分，不把共享服务还在运行称为 session 未结束。

## 7. ashub 实施范围

- Claude/Codex/Hermes 使用来源限定的稳定 instance key/tmux 名称，并保存完整来源/CLI/env 身份；env 的敏感值不放入展示元数据。
- tmux create/attach 与 session identity 校验在一次受锁操作内完成；跨 Emacs 重启可发现。既不能 attach 同名但非本项目管理的 session，也不能恢复时再次启动同一 writer。
- ghostel 只持有 tmux 客户端；kill-buffer/Emacs 退出仅断开该客户端。C-c C-q 由 Emacs 侧拦截并结束已验证归属的目标 tmux session，不转发 Agent。
- Agent 自然退出后按退出清理策略回收空壳，不保留永久 idle pane；Agent 等待下一条消息不属于自然退出。
- Pi 经客户端公开 API 查询/打开/结束；DSH 查询/打开/断开，保留其 C-c C-q 特例。不走私有变量，也不自己维护第二份权威运行状态。
- Hub 显示正在运行/等待/已断开/停止中/用户已结束/异常退出/未知；不要把 idle、finished-by-user、模型成功合为一列“完成”。用户结束摘要跨 Emacs 重启可读，由所属运行管理层负责原子保存；仅存来源/实例/代次/时间/原因等必要字段，不改用户历史。
- 重开已结束历史是新的运行实例；显示清楚其 generation。tmux 不存在与未知/不可达不是同义词，查询失败不能触发盲目重启。

## 8. 实施顺序与依赖

- [ ] P0：保存原型与证据；确定正式 bridge 运行时、支持平台和 IPC/部署位置；核对现有三仓库安装/打包方式。
- [ ] P1：隔离验证 DSH 真实任务在断连后续跑与精确 session 重连；不再探索统一 finish 的 Host plugin。优先独立测试 profile，使用受控无模型任务。若必须使用现有会话、收费模型或改变 Desktop 数据，先说明并取得许可。未知 Host 接口必须停下查证。
- [ ] P2：实现 emacs-pi 持久 bridge、身份锁、只读 inspect、detach/finish 和 fake peer 回归；接入所有原生入口，完成真实 Emacs 重连测试。
- [ ] P3：实现 emacs-dsh managed 独立托管、Host 隔离和重连接口；C-c C-q 保持关闭界面。完成 Desktop/managed 两模式验收，不将 partial 标为完成。
- [ ] P4：ashub 集成公开客户端 API 与 Claude/Codex/Hermes tmux；保留现有来源、精确恢复、cwd/fork 与历史缓存行为。
- [ ] P5：五 Agent 跨入口验收、更新三个仓库 README/公共 API/按键迁移说明及 ashub REQUIREMENTS/ACCEPTANCE/IMPLEMENTATION-STATUS；按各仓库测试通过后交付。

三仓库可以分别提交，但集成必须核对 API 版本；旧客户端不支持持久化时显式报错，不悄悄改用非持久路径。现有非持久进程不可无损转移 stdio：提示用户先完成/明确停止再迁移，不默认关闭或重复打开正在执行的会话。

## 9. 验收矩阵

每个 Agent 测试新建与指定历史恢复；Pi/DSH 必须同时覆盖 ashub 和原生入口。DSH 覆盖 Desktop/managed。

| 场景 | 必须断言 |
|---|---|
| 普通关闭 buffer | 任务继续；运行实例未被标记用户结束 |
| 正常退出 Emacs | 同一后台实例持续；新 Emacs 重连同一身份 |
| SIGKILL Emacs | 无退出 hook 仍可续跑和重连 |
| 中途重连与结束后重连 | 不重复任务；输出与运行状态一致；断线期间结果可见 |
| 大量输出且无客户端 | 不因 pipe 阻塞或内存无限增长挂起；超过 replay 限额有显式恢复流程 |
| 审批/问题等待期间断开 | 不自动批准；重连后正确恢复或说明失效 |
| Pi/终端 Agent 运行、idle、有队列时 C-c C-q | 目标运行停止且队列不再启动；专属资源释放；历史仍可再次恢复 |
| DSH 运行、idle、有队列时 C-c C-q | 仅客户端断开；Host 与任务/队列保留，重连不重复启动 |
| finish 超时/Host 失联 | 显示 stopping/unknown，不宣称已完成，不误杀其他实例 |
| 两 Emacs 并发打开 | 只有一个 writer/控制租约；第二个不隐式抢占 |
| 两 session 共用 DSH Host | 关闭 A 的界面不干扰 B；不误停共享 Host |
| bridge/Host 异常退出 | 可判别失败；不盲目重发任务；明确区分历史重启与原进程重连 |
| 进程自然退出 | 回收专属空壳；保留退出原因；不是用户确认成功 |
| 同 ID 不同来源/profile | 不误连；凭据、请求、状态互相隔离 |
| 旧 cwd 缺失、迁移/fork | 保留现有精确恢复与历史保护规则 |
| C-c C-q 模式键冲突 | 聊天主模式及队列编辑/复制等局部键图审核，避免按键悄悄变成别的动作 |

已有回归入口：ashub `test/`；emacs-pi `test/emacs-pi-test.el`、`test/public-api-test.el`、`test/fake-pi.py`；emacs-dsh `tests.el`、`public-api-tests.el`、`ashub-compat-tests.el`。新增确定性 fake peer/supervisor 故障测试和受控真实 smoke。Elisp 修改须结构检查、字节编译与 ERT；不能因 checker 返回 OK 就忽略缺失 elisp-lint。

## 10. 交付边界

本文件是计划，不是全部方案已经验证的声明。Pi bridge 运行时已确认 Node，接下来验证随包部署及正式持久传输。DSH session finish 不再是前置关卡；其待验收项是任务续跑、精确重连、managed Host 独立托管与身份隔离。Pi 原型足以支持继续实现设计；不足以直接搬进正式代码。不得自动提交、推送、安装新依赖，或在用户真实活跃 session 上验证取消/关闭。
