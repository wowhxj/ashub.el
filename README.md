# ashub — Agent Session Hub

Emacs 中的历史会话目录与恢复入口。支持 Claude Code、Codex、Pi、DeepSeek Harness、Hermes；不接管外部终端进程，不统一实现聊天协议。

**当前是开发版，不是已完成五类真实会话验收的发布版。** Hub 与隔离测试已实现；用户可手动选择会话恢复，自动代为恢复或发送测试消息仍须明确授权。客户端及 Host 的已知缺口见下文与 [验收清单](ACCEPTANCE.zh-CN.md)。

## 依赖与加载

- Emacs 29.1+ 为目标基线；目前实际测试环境为 macOS、Emacs 32.0.50。尚未实测 Emacs 29.1 或 Linux。
- Claude/Codex/Hermes 枚举需要 Python 3.9+，只用标准库，无需 pip 包。
- 这三类恢复使用 `ghostel-exec` 及对应可执行程序。
- Pi、DSH 分别需要提供四个公开 API 的 emacs-pi/emacs-dsh 开发版本。缺少某个客户端只影响该 agent。
- 不会安装依赖、自动修改 Emacs 配置或更新已安装 package。

### 使用 use-package / :vc

以下配置需要 Emacs 30+ 内置的 `use-package` / `:vc` 支持，从 `main` 安装开发版：

```elisp
(use-package ashub
  :vc (:url "https://github.com/wowhxj/ashub.el"
       :branch "main"
       :rev :newest)
  :commands ashub
  :bind ("C-c h" . ashub))
```

保留现有 emacs-pi、emacs-dsh 和 ghostel 配置。Hub 不代为安装这些可选依赖。若 DSH 使用已启动的 Desktop Host，而不是 Emacs 管理的 Host：

```elisp
(setq emacs-dsh-connection-mode 'desktop)
```

`C-c h` 或 `M-x ashub` 打开列表；会话行上 `RET` 恢复，`C` 清除过滤，`!` 查看诊断。Hub 不发送探测消息。

已有 Emacs 实例首次加载 Hub 无需重启；若已加载旧版 Hub/客户端，请先结束相关活动操作再自行重启 Emacs，不要强制卸载活动聊天库。可用 `C-h f emacs-pi-list-sessions` / `C-h f emacs-dsh-list-sessions` 核对当前版本是否提供枚举接口。不要在正常实例加载下文的 `dev/readonly-init.el`。

### 从本地源码加载

将本目录加入 `load-path`，然后运行 `M-x ashub`：

```elisp
(add-to-list 'load-path (expand-file-name "~/sandbox/ashub"))
(require 'ashub)
```

Pi/DSH 的开发源码目录需要在各自客户端首次加载**之前**加入 `load-path`。注意旧 `.elc` 可能遮蔽新 `.el`；开发验证可使用 `load-prefer-newer`。不要在有活动聊天的 Emacs 中强行卸载客户端。推荐另开干净 Emacs 验证，确认后再自行更新配置。

`ashub` 不调用 `delete-other-windows`。打开 Hub、搜索、过滤、查看详情或刷新均不会恢复聊天。

## 按键

| 按键 | 操作 |
| --- | --- |
| `RET` | 恢复当前指定会话，不发送任何消息 |
| `/` | 实时全文字面搜索；`C-g` 恢复原搜索 |
| `a` | Agent 补全筛选，空输入或“全部”清除 |
| `p` | 项目路径补全或路径片段筛选 |
| `c` | 按 agent / 按项目分组 |
| `TAB` | 折叠或展开当前分组 |
| `g` | 取消旧扫描并异步刷新，保留过滤条件 |
| `e` | 展开/收起完整首条用户消息 |
| `d` | 详情，包括完整 ID、来源、项目、时间出处与状态 |
| `w` / `W` | 复制完整 session ID / 记录的项目路径 |
| `!` | 各数据源诊断 |
| `C` / `C-c C-k` | 清除搜索与两种筛选，不重新扫描 |
| `q` | 取消扫描并退出 Hub，不关闭聊天进程 |

默认隐藏可靠识别的内部子会话、空会话、归档会话。未知状态保留，不猜测。可设置：

```elisp
(setq ashub-show-empty t
      ashub-show-archived t)
```

已归档会话可以浏览，但 Hub 不自动取消归档，因此拒绝直接恢复它们。请在原客户端处理后刷新。

搜索匹配 agent、**完整** ID、**完整**项目路径和**完整**首条用户消息，忽略大小写。空格分隔的词均须命中，按字面匹配而非正则表达式。搜索与 agent/项目筛选取交集；折叠不改变匹配结果。

每个分组按最近真实交互时间降序排列；分组顺序取组内最新时间。未知时间排最后。不用文件 mtime、生成标题或索引 updatedAt 冒充消息内容/交互时间。列表缩短 ID，发生前缀冲突时加长；跨来源完全同名 ID 仍是独立记录，详情中显示来源根目录。

## 数据源与 profile

默认只读取以下已知根，不扫描整个磁盘：

| Agent | 默认存储根 | 枚举方式 | 恢复方式 |
| --- | --- | --- | --- |
| Claude | `$CLAUDE_CONFIG_DIR` 或 `~/.claude` | `projects/*/*.jsonl` | `claude --resume ID` |
| Codex | `$CODEX_HOME` 或 `~/.codex` | `state_N.sqlite`、完整 `thread_history_N.sqlite`、可用的 rollout | `codex resume ID --cd DIRECTORY` |
| Pi | `$PI_CODING_AGENT_DIR/sessions` 或 `~/.pi/agent/sessions` | `emacs-pi-list-sessions` | `emacs-pi-open-session FILE` |
| DSH | emacs-dsh 当前配置的 Host | `emacs-dsh-list-sessions` | `emacs-dsh-open-session ID` |
| Hermes | `$HERMES_HOME` 或 `~/.hermes` | `state.db` | `hermes --resume ID --in DIRECTORY` |

`ashub-sources` 非 nil 时替换默认源；`ashub-extra-sources` 追加源。例如：

```elisp
(setq ashub-extra-sources
      '((:agent claude :root "~/agent-data/claude-work" :label "Claude work")
        (:agent codex :root "~/agent-data/codex-work" :label "Codex work")
        (:agent pi :root "~/agent-data/pi-sessions" :label "Pi extra history")
        (:agent hermes :root "~/.hermes/profiles/work" :profile "work")))
```

- `:root` 是上述表格中的存储 home；**只有 Pi 的 root 直接指向 sessions 目录**。
- Claude/Codex/Hermes 恢复分别强制绑定 `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `HERMES_HOME` 到该记录的 root。Hermes 的 profile 根目录通过 `HERMES_HOME` 映射，不再次用 `--profile` 重新解析为其他目录。
- `:profile` 是身份区分标签，不是通用 CLI 参数。不能把标签当成已实现的 native 多 profile 连接管理。
- Pi 的默认适配器只映射会话存储，调用 API 的 `:session-directory`。独立 runtime 配置的 Pi profile 必须提供 `:open-function`。
- DSH 默认只支持客户端已配置的一个 Host。额外 Host/profile 必须同时提供 `:scan-function` 和 `:open-function`；不修改客户端全局配置去伪造隔离。
- 相同 agent、canonical root、profile 组成数据源身份。完全相同的目录别名去重；同一身份的冲突恢复配置报错。DSH 的会话身份还包含枚举时的 authenticated Host generation。
- 可选 `:program`、`:args`（字符串列表）、`:environment`（`"NAME=VALUE"` 列表）用于显式配置终端入口。环境设置不得把来源绑定的 home 改为别处。

如果选择的会话没有可用本地 cwd，恢复前会要求用户选择现有本地目录。选择只保存在内存，不修改历史记录，不用日志所在目录猜项目。源目录消失时不创建替代 profile。TRAMP 恢复不在当前范围内。

### 扩展函数契约

- `:scan-function`：`(SOURCE CALLBACK ON-ERROR)`，异步调用 `(CALLBACK SESSIONS DIAGNOSTICS)` 或 `(ON-ERROR MESSAGE)`，返回静默取消函数。会话是 `ashub-session` 结构，来源必须与 SOURCE 一致。枚举不得启动 agent 或修改来源数据。
- `:open-function`：`(SESSION DIRECTORY ON-READY ON-ERROR)`，仅在用户显式恢复时调用。应验证完整身份、使用正确 profile、保持窗口布局、不发消息、返回可选取消函数。
- `ashub-terminal-open-function`：可替换 ghostel，参数为 `(SESSION PROGRAM ARGS DIRECTORY ENVIRONMENT ON-READY)`。替代函数负责自己的异步启动、错误、存活检测和实例复用；默认 ghostel 路径已有这些基本生命周期检查。

## 一致性、失败与生命周期

- 文件/SQLite 扫描在独立 Python 进程进行，按记录流式返回。Emacs 每批处理最多 32 条协议记录。Pi 的协作式分块读取由客户端负责。
- 每源默认 120 秒扫描超时；刷新、退出或关闭 Hub buffer 会取消旧扫描。旧代回调不能覆盖新结果。
- SQLite 使用 `mode=ro`、`query_only` 与读事务，不创建数据库、不执行写 SQL、不切换 journal 模式。存在非空 WAL 但缺少 SHM 时明确失败，不为浏览主动创建 SHM。SQLite 自身仍使用正常的读取协调机制；不使用可能忽略 WAL 的 `immutable=1`。
- 不建立磁盘索引、持久化缓存或项目目录映射。源结果、失败旧数据和实例映射只在内存中。
- 全源失败保留上次成功结果并显示“旧数据／刷新失败”。部分失败保留读到的新结果；未能重新确认的旧记录标记 `[旧]`。只有一次无诊断的成功刷新才删除未再次发现的记录。
- 空文件、非文本用户输入、损坏数据和未知状态彼此区分。Hermes 排除已知 compaction/bookkeeping 行及 delegate 会话；不把全部 parent/branch 会话当成 subagent。
- 首次扫描失败不会显示成“已确认没有历史”。顶部会指出受影响源，`!` 提供诊断。
- 默认终端恢复直接传 argv，不经过 shell。调用 ghostel 时动态禁用 `ghostel-module-auto-install`，即使用户平时配置为自动下载，也不会由 Hub 安装模块；缺模块明确失败。只复用 Hub 创建且进程仍存活的 buffer；进程退出则在原 buffer 重启，buffer 消失则重建。不探测或接管外部实例。
- Native 客户端负责验证就绪与复用。并发按同一会话的 `RET` 不重复启动。超时/失败不会被 Hub 当成成功；迟到就绪回调不抢窗口。
- 终端进程存活**不等于** agent 已接受恢复 ID。Hub 只提示“参数已提交”；实际是否恢复成功需在 agent 界面验收，不会自动发消息探测。

## 已知限制，不能当作已验收能力

1. DSH 当前公开枚举主要返回 Host 原始元数据，未保证完整首条用户消息及真实交互时间。Hub 仅在显式消息字段存在时使用，否则显示未知并给诊断，不把 title/updatedAt 当替代。`turnOutline` 也不被假定为完整原始首轮。
2. 已通过公开客户端 API 查询现有 Desktop Host，加载 65 条；本次业务 RPC 仅 `session/list`。静态检查该 Host 的列表实现未走恢复入口，但未完成文件级写入审计或跨版本保证；真实 follow 快照字段、真实恢复仍未验证。
3. DSH 来源保护暂依赖当前客户端的内部只读身份函数 `emacs-dsh--source-identity`，因为公开 open 接口尚无 expected-source 参数。接口变化时应失败关闭，不应移除保护。Host generation 变化时恢复失败关闭，要求刷新，不能把旧来源 ID 交给新 Host。若旧 Host 不可用，Hub 不偷偷恢复到默认 Host；需要客户端重新提供可验证来源。
4. Pi 客户端的 RPC 文件/ID 校验已接入，但实际执行 cwd 尚未有权威验证。不能以 Emacs `default-directory` 代替 agent 执行 cwd 的证明。当前客户端也未提供完整的 open 取消契约。
5. Pi open 接口没有 `expected-id` 参数。它验证打开时文件头与 RPC 的一致性，而不是历史列表快照中的旧 ID。选中文件被原地替换的竞态仍需客户端扩展契约；Hub 不另写 Pi 解析器掩盖它。
6. 部分 Codex 历史只有索引，没有可读 rollout 或完整 thread history/原始时间。此类记录保留为元数据，不从生成标题或 index 更新时间补造字段。
7. 尚无事务性跨文件系统快照。文件只读初始大小；一个巨大的 JSON 行仍需一次解析，内容变化/格式升级可能产生部分结果或诊断。
8. 独立 Emacs GUI 已按用户授权从只读准备切为正常手动使用：DSH 接入现有 Desktop Host、恢复拦截解除、清除筛选现场验证通过。没有自动恢复或发消息；五种 agent 的“真实恢复、正确 cwd、继续发送消息”仍是最终验收项。
9. 开发版仓库为 <https://github.com/wowhxj/ashub.el>，使用 `main` 和 `package-vc` 分发。许可证尚未决定，未声明为正式稳定版或已满足包仓库收录规范。

## 独立只读准备工具

这不是正常使用入口：该脚本故意让 DSH 不加载、`RET` 不能恢复。正常使用应按前文加载并执行 `M-x ashub`。本次已获授权的独立窗口已移除这些临时限制；日常 Emacs 配置未改。

`dev/readonly-init.el` 只供获得用户授权后，在全新 `Emacs -Q` 实例中加载。调用前显式设置 `ashub-readonly-client-directories`（开发客户端目录列表）和 `ashub-readonly-dependency-directory`（已有依赖目录），不要加载到有活动聊天的 Emacs。

工具不安装包、不修改已有配置。它禁用 Hub/native open/ghostel 启动入口，跳过真实 DSH Host 查询，并提供 `ashub-readonly-report` 返回版本、加载路径及聚合计数。该保护用于验收准备，不是限制用户任意 Emacs Lisp 执行的安全沙箱。真实验收应另行明确授权，不自动解除保护。

命名 daemon 可用 `emacsclient -s SERVER -c -n` 打开独立窗口；用 `emacsclient -s SERVER --eval '(kill-emacs)'` 关闭该专用实例。必须使用对应 server 名，不要把关闭命令发到日常 Emacs。

## 测试

```sh
make clean check
```

只使用临时合成日志、SQLite 库和 mock/fake transport；不会发送真实消息、连接真实 DSH Host 或启动真实 agent。

`make check` 检查全部 Lisp 括号、将 byte-compile warning 作为错误，并执行 19 项 Python 与 43 项 ERT 测试（共 62 项）。客户端各自的公开接口测试不包含在可移植测试命令中，应在它们自己的开发目录另行运行。

可选 `elisp-lint` 使用开发目录策略（不检查发布元数据、70 列限制及外部可选库声明解析），命令如下；依赖须已在 `load-path`，不会自动安装：

```sh
emacs -Q --batch -L . -l elisp-lint -f elisp-lint-files-batch \
  --no-package-lint --no-fill-column --no-check-declare \
  ashub-core.el ashub-sources.el ashub-open.el ashub.el
```

未调整参数的通用 `elisp-checker.sh` lint 阶段存在发布头信息/行宽规则不匹配，不能宣称完整通过该默认规则。它在当前安装版本中还可能在输出 FAIL 后返回成功；应以实际 lint 输出及 `make check` 的严格退出码为准。

实现分工：`ashub-core.el`（模型/来源/纯过滤）、`ashub-sources.el`（异步适配）、`ashub-open.el`（恢复生命周期）、`ashub.el`（界面）、`ashub-scan.py`（后台只读本地扫描）。
