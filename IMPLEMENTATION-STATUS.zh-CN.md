# ashub 实现状态

状态：Hub 开发版已实现。用户进一步授权“修复并启用正常手动使用”；独立窗口已解除只读准备限制，五类历史均已加载。五种 agent 的真实恢复/继续消息验收尚未执行，不能宣称全部需求已最终验收。

## 已实现

- `ashub-core.el`：统一记录、canonical 数据源身份、profile 区分、三态过滤、全文字面搜索、真实交互时间排序、冲突 ID 前缀。
- `ashub-sources.el`：五类异步适配器；Pi/DSH 只调用客户端 API，其余使用独立后台扫描进程。包含取消、超时、部分错误与迟到回调保护。
- `ashub-scan.py`：Python 标准库只读扫描 Claude JSONL、Codex state/完整 Desktop history/rollout、Hermes SQLite。保留未知字段，区分非文本输入、内部派生会话与压缩摘要。
- `ashub.el`：`M-x ashub`、`*ashub*`、`ashub-mode`，单行列表、实时搜索、agent/项目筛选、分组折叠、全文预览、详情、复制、异步刷新、旧数据标记与诊断。
- `ashub-open.el`：指定会话恢复、来源环境绑定、直接 argv、缺 cwd 显式选择、Hub 所属活实例复用/死实例重启、native 依客户端回调验证就绪。不删除其他窗口，不自动发送消息。
- `Makefile`：可复现的括号检查、warning-as-error 编译、Python 与 ERT 测试。
- `dev/readonly-init.el`：独立 Emacs 的只读准备入口，显式加载开发客户端、禁用恢复/终端启动并跳过真实 DSH Host；仅在用户授权的专用实例中使用。
- `README.md`：加载、按键、来源/profile 配置、依赖、错误语义、扩展契约与限制。
- `ACCEPTANCE.zh-CN.md`：已验证证据与必须由用户授权的五类真实验收清单。

全部结果缓存、目录选择与实例映射均仅在内存中。未实现也不需要 Hub 删除、归档、重命名或统一聊天阅读器等需求外功能。

## 客户端状态与本轮边界

用户通过 DeepSeek Harness 完成的公开接口：

- `emacs-pi-list-sessions`
- `emacs-pi-open-session`
- `emacs-dsh-list-sessions`
- `emacs-dsh-open-session`

最初仅使用源码项目中的这些接口；后来在用户的日常安装包中确认均未发布，导致 Pi/DSH 不显示。用户已另行授权审查并发布已有 API 改动：emacs-pi `07c01fc`、emacs-dsh `c7b70a9` 已推送各自 `main`。未替换已安装副本或修改日常 Emacs 配置；用户需升级三个 VC 包后安全重启。

完整客户端回归另行通过：Pi 54 项；DSH 144 项通过、1 项平台测试跳过。两客户端改动文件严格编译通过。验证使用 `load-prefer-newer`，开发目录在已安装依赖之前；API 文档中的真实验收边界仍保留。

## 验证结果

- `make clean check`：项目括号检查、四个 Lisp 模块严格编译通过；19 项 Python + 52 项 ERT，共 71 项项目测试全部通过。
- Python 测试覆盖合成 JSONL、当前 Codex history schema、多页顺序、Hermes bookkeeping/compaction、损坏与非文本输入、SQL 只读与缺失 WAL index。
- ERT 覆盖模型、过滤、分组、预览、旧数据、generation/cancel/timeout、四个 API 分派、Host 来源保护、argv/profile 环境、实例复用、缺依赖及缺 cwd。额外确认调用 ghostel 时禁用模块自动安装，且不改变用户原有策略。
- 初次四类扫描：Claude 35 条、Codex 75 条、Hermes 2 条、Pi 151 条；保留 263 条、默认显示 239 条，当时刻意跳过 DSH。
- 获得正常手动使用授权后，DSH 通过客户端 API 加载 65 条；本次业务 RPC 仅 `session/list`，未启动 Host。合计保留 328 条、默认显示 304 条。DSH 的 65 条均无显式首条原文/可信交互时间，保持未知并提示部分结果。
- 修复空 agent 补全误设筛选；增加 `C` 清除全部过滤。两项新回归先红后绿；独立窗口实测 304→0→304，清除不重扫。
- 按用户新要求默认项目分组，`n`/`p` 移动条目、`o` 筛项目，`1`–`5` 筛选/定位各 agent；缺 API 的错误显示真实库路径及升级提示，并在列表内展示来源失败原因。新增 8 项测试均先红后绿。
- 后续修复悬停跨行：之前条目 overlay 仍包含换行；现每物理行独立且不含换行。加强平面行尾测试、增加展开/空行测试，两个边界先红后绿。
- 独立窗口已加载修复，四处只读拦截解除、标题改为手动使用；检查时 Hub 终端实例数和待恢复数仍为零。未自动恢复或发送消息。
- 通用 `elisp-checker.sh` 的括号/编译阶段已执行；默认 lint 规则对开发目录的发布头信息、模块命名和行宽有额外要求，不能称默认全项通过。另用 README 记录的开发 lint 策略检查，四个模块均通过。

## 最终验收清单

1. 已完成：建立独立 Emacs GUI、核对源码加载路径。最初启用只读保护；用户随后授权正常手动使用，已解除保护并核对无自动恢复。没有修改日常 Emacs 配置。
2. 五种 agent 逐一由用户选择明确测试会话，验证恢复 ID、实际 cwd、客户端生命周期与继续消息。继续消息会写真实历史，必须另行确认。
3. DSH 已完成现有 Desktop Host 列表枚举；原始首条输入及真实交互时间缺失，真实 follow 快照字段仍待验证。静态核对列表未走恢复路径，但服务端文件级无写入及跨版本保证尚未完成审计。
4. Pi 的权威执行 cwd、open 取消，以及源文件原地替换时的 expected-id 竞态仍属于客户端契约边界。Hub 不另写 Pi 日志解析器解决它们。
5. native 额外 profile 需要可靠的连接/恢复函数；默认不伪造多 Host/profile 支持。
6. Emacs 29.1、Linux、实际 GUI 交互未验证；目标支持不能写成已实测支持。
7. 用户已指定开发版仓库 `https://github.com/wowhxj/ashub.el`，授权初始化并直接推送 `main`，在现有真实 Emacs 中自行验证。README 提供 `use-package :vc` 配置；许可证尚未决定。

开发验证未启动或恢复真实 agent、未发送真实消息。用户后续明确授权以 `~/sandbox/emacs-pi` 为准对齐 runtime：已私有备份旧树和配置，Org/生成 Lisp 均改为本地源码加载；canonical 与安装副本的 9 个源码/自动加载文件、8 个重编译字节码散列一致。canonical 严格编译与 54 项测试通过，独立进程按真实修改后配置只读枚举得到 151 条、48 条诊断。

真实 Emacs 仍有 1 个存活 Pi 会话，用户选择保留至重启；函数身份和进程保持不变，不热卸载、不替换当前 Pi 内存代码。必须重启后再核对 canonical 路径及真实 Hub 列表，不能提前宣布活动 runtime 已切换。

用户最新要求以默认项目分组替代最初默认全局混排要求；`n`/`p` 已实现，项目键改为 `o`。仍保留 `c` 切组；原文档中的 `G`、`j` 尚未实现，不因发布标为完成。
