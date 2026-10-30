# ashub — Agent Session Hub

[English](README.md) | 简体中文

在一个 Emacs buffer 中浏览和恢复编程智能体的历史会话。支持 **Claude Code、Codex、Pi、DeepSeek Harness 和 Hermes**，复用现有客户端，不另做一套聊天界面。

## 功能

- 默认按项目分组，展示可用日期和消息预览；可选 gptel 后台维护一句话中文主题＋进展摘要。
- 按 agent、完整会话 ID、项目路径或首条用户消息搜索。
- 键盘导航、agent 快捷定位、分组折叠和会话详情。
- 异步加载历史，单独报告各数据源的问题。

浏览列表不会启动聊天或发送消息。按 `RET` 恢复指定会话，按 `N` 新建会话。操作后立即在回显区和顶部显示进度，恢复的会话行也会标记；就绪、失败或超时后更新状态。

## 依赖

- Emacs **29.1+**。下面的 `use-package :vc` 配置需要 Emacs **30+**。
- Claude、Codex、Hermes 历史扫描需要 Python **3.9+**，无需额外 Python 包。
- Pi、DeepSeek Harness 需要提供公开会话枚举和恢复 API 的新版 [emacs-pi](https://github.com/wowhxj/emacs-pi)、[emacs-dsh](https://github.com/wowhxj/emacs-dsh)。
- Claude、Codex、Hermes 恢复需要安装好原生模块的 `ghostel`，以及 Emacs `PATH` 中可找到的对应 CLI。

只需为自己使用的 agent 配置相应可选依赖。

## 安装

```elisp
(use-package ashub
  :vc (:url "https://github.com/wowhxj/ashub.el"
       :branch "main"
       :rev :newest)
  :commands ashub
  :bind ("C-c h" . ashub))
```

保留现有客户端配置。如果 emacs-dsh 要连接已经运行的 Desktop Host：

```elisp
(setq emacs-dsh-connection-mode 'desktop)
```

也可以克隆仓库后从本地加载：

```elisp
(add-to-list 'load-path "/path/to/ashub.el")
(require 'ashub)
```

## 使用

运行 `M-x ashub`；采用上面的配置后，也可按 `C-c h`。Hub 默认占满当前 frame，按 `q` 恢复进入前的窗口布局，不关闭聊天 buffer。

| 按键 | 操作 |
| --- | --- |
| `n` / `p` | 下一／上一条目 |
| `RET` | 恢复当前会话 |
| `N` | 新建：选择 agent（默认 Pi），再选择或输入项目目录；不存在时会创建 |
| `j` | 从全部已载入的会话中选择；可用 Vertico/Orderless 筛选候选项，按 `RET` 跳到对应列表条目 |
| `a` / `o` | 按 agent／项目筛选 |
| `1`–`5` | 筛选并定位 Claude／Codex／Pi／DSH／Hermes |
| `C` | 清除全部筛选 |
| `c` | 切换项目／agent 分组 |
| `TAB` | 折叠或展开分组 |
| `i` | 查看会话详情及完整对话（仅用户/助手文本，不含思考和工具调用） |
| `l` | 刷新并切换存活会话筛选；按 `RET` 进入已打开的会话 buffer；`*` 标识已打开 |
| `d` / `u` / `x` | 标记当前会话／取消当前会话的删除标记／确认后永久删除标记会话 |
| `w` / `W` | 复制完整会话 ID 到剪贴板／项目路径 |
| `R` | 把已改名／移动的项目目录映射到新位置（保存在 `ashub-project-relocations`）；仍不存在的目录显示 `[目录缺失]`。Pi 会话的原 cwd 缺失时，恢复会在新目录 fork；只有确认新 session 可用且完整历史一致后，才移除旧文件并清掉 fork 的父文件引用。其他 agent 历史不改写。 |
| `g` / `!` | 刷新／查看诊断 |
| `?` | 查看完整快捷键及列表标记说明 |
| `q` | 离开 Hub，恢复进入前的窗口布局 |

`d` 仅支持标记已成功刷新的 Claude/Pi 会话；`x` 会再次确认后永久删除对应会话文件。Codex、Hermes、DSH、自定义源及过期数据暂不支持删除。删除不可撤销。

`N` 通过已有 Pi/DSH 客户端或与恢复相同的终端后端打开新会话，不自动发送首条消息。由 `N` 启动的 Claude 终端，会通过终端 PID 和 Claude 的 `sessions/<PID>.json` 记录关联准确的历史 session ID；关联后首页显示 `*`，`l` 也使用该历史会话的日期和预览。尚未关联的终端会在 `l` 筛选中以“未索引”显示，不会仅凭项目目录猜测关联；按 `RET` 可直接切回该终端。需要升级到提供 `emacs-pi-create-session`、`emacs-dsh-create-session` 的客户端版本。

列表正文拆成「**摘要｜用户末句｜摘要状态**」三列。摘要列优先显示 AI 摘要；尚无成功生成的摘要时，只显示用户首句，不再拼接末句。用户末句独立展示，未知时显示 `[末句未知]`；DSH 投影消息保留 `[预览]` 标签。摘要状态明确区分「待生成、摘要中、已生成、待更新、摘要失败、未启用、已暂停」，鼠标悬停可确认摘要列当前是 AI 摘要还是首句预览。各列只在展示时截断，悬停仍可查看完整文本；原始首末句也保留在 `i` 详情中。窄窗口隐藏项目列，保留三列；原有恢复/目录等会话标记仍在行尾，空间不足时其完整内容可在状态 tooltip 查看。顶部快捷键提示始终只有一行，窄窗口仅显示按键；按 `?` 查看完整说明。

默认按项目分组。agent 快捷键保留现有项目筛选，按 `C` 返回完整列表。会话没有可用工作目录时，恢复前会要求选择一个目录。

## 会话详情：紧凑信息与聊天阅读

按 `i` 打开详情，顶部只展示 agent、短 ID、项目、可读时间、摘要状态和已有摘要。完整路径、来源/profile、原始首末句、模型与生成时间等默认折叠在「详细信息」中；按 `m` 或点击该按钮展开，搜索隐藏字段时也会自动展开。来源更新/创建时间仍以 `*` 区别于可信交互时间。

对话按 **agent 左侧、用户右侧** 排列，采用不同底色，浅色/深色主题分别适配。中文长段落、代码行会按窗口宽度重新排版；调整窗口大小只重排已经读取的内容，不重新读取历史或请求模型。代码块内的 `User:` / `## Assistant` 不会被误拆成新消息。

- 每条消息顶部的「复制」按钮复制该条原文，不含气泡排版增加的空格与换行。
- `C-c C-w` 复制整段原始对话；普通区域复制则会包含展示排版。
- `TAB` / `S-TAB` 在按钮间移动，`g` 重排缓存内容，`q` 退出详情；重新从 Hub 按 `i` 可读取最新对话。
- `ashub-details-message-width`（默认 100 列）和 `ashub-details-message-width-ratio`（默认窗口宽度的 0.76）可调整消息最大宽度。颜色可自定义 `ashub-details-user-face`、`ashub-details-assistant-face`。

此视图只展示已保存的用户/助手可读文本，不渲染图片，也不展示隐藏思考或工具调用；与后台摘要输入独立，不改写 agent 历史。

## 后台 AI 摘要（可选）

摘要功能默认关闭，不会仅因加载 ashub 或刷新列表而向模型发送内容。显式启用后，使用 **gptel 默认后端和默认模型**，向该后端发送完整可读会话及相关工具证据；可能产生 API 费用，请确认该后端适合处理你的历史会话。

在现有 gptel 配置后加入：

```elisp
(with-eval-after-load 'gptel
  (require 'ashub-summary)
  (setq ashub-summary-idle-delay 300          ; 停止使用后等待，默认 5 分钟
        ashub-summary-request-interval 60     ; 模型请求最小间隔，默认 60 秒
        ashub-summary-check-interval 30       ; 后台检查周期
        ashub-summary-scan-interval 300       ; 历史枚举周期
        ashub-summary-stable-delay 300        ; 内容变化后的稳定窗口
        ashub-summary-read-timeout 120        ; 单次读取超时
        ashub-summary-request-timeout 180     ; 模型请求超时
        ashub-summary-retry-delay 300         ; 首次失败退避
        ashub-summary-retry-max-delay 3600    ; 失败退避上限
        ashub-summary-max-attempts 3)         ; 相同内容最大失败次数
  (ashub-summary-mode 1))
```

时间单位均为秒，必须为正数，都可通过配置文件或 `M-x customize-group RET ashub-summary` 调整。调度时读取当前值；已排定的检查、超时和重试期限不会被追溯改写。需要立即重排周期时重新启用模式；`s` 可以清除所选会话的失败退避并重新排队，但仍遵守使用状态、稳定窗口与请求间隔。

- 后台模式独立于 Hub buffer 运行，关闭列表不停止维护；`M-x ashub-summary-mode` 可停止并取消本包拥有的在途工作。
- 自动缓慢补齐所有普通及归档会话，不受列表筛选限制；排除已知内部、空会话。已有缓存即使关闭模式也可展示。
- 只识别 **Emacs 内**打开或正在恢复的会话，不检测外部终端。保持打开即跳过，不把暂时空闲当作使用结束。停止使用并等待配置时长后才可更新；等待期间重新打开则重新计时。新发现的历史会话也先经过等待/稳定窗口。
- 队列单并发；较早进入等待的会话先处理，同批历史优先近期会话，避免持续有新内容时饿死历史补齐。
- 省 token 靠**避免无效调用**：正文未变不重做、使用期间合并变化、持久化缓存避免重启重复生成。元数据变化会触发正文核验，但不会仅凭文件时间变化重发模型请求。
- 首次和后续生成均读取完整相关内容，不使用引用导出的字符裁剪，不默认采用「旧摘要＋增量」；Pi 按当前保存分支读取，保留工具调用/结果，隐藏思考不发送。请求在隔离 buffer 中进行，不使用当前 gptel 聊天上下文、工具或 prompt transforms。
- 模型上下文超限时**不会偷偷裁剪或自动启动多轮压缩**：保留旧摘要和诊断，停止对同一内容盲目重试。可调整 gptel 默认模型后按 `s` 重排。短暂服务故障对整个队列退避；认证或配置错误暂停队列，修复后按 `s` 或重新启用模式。
- 读取和请求均有超时；请求返回后重新读取核对全文。重新打开、删除、停用模式或内容变化后，迟到结果不能覆盖现有摘要。取消已发送请求不保证服务商不计费。

`s` 为当前会话重新排队；`M-x ashub-summary-status` 查看后台状态；`!` 查看队列/来源诊断，`i` 查看摘要生成时间、模型、失败原因及原始首末句。更新或失败时旧摘要仍保留，对应状态单独显示在「摘要状态」列，不再混进摘要或用户末句。

缓存位于 `ashub-summary-cache-file`（默认 `~/.cache/ashub/summaries.json`，尊重 `XDG_CACHE_HOME`），以 `0600` 原子写入；包含摘要、内容指纹和调度状态，**不保存完整会话正文**。切换 gptel 默认模型不会自动重做全部历史。通过 Hub 删除会话时也会删除对应摘要缓存。

本地 Claude、Pi、Codex、Hermes 使用只读后台 Python 读取；不会启动 agent。DSH 复用公开读取 API，使用可配置的 `ashub-summary-dsh-max-messages` 作为传输上限；达到上限时拒绝生成不完整摘要。其输入覆盖以客户端 API 实际返回的消息为限；自定义来源或需要更完整工具记录的 DSH 客户端可通过来源的 `:summary-function` 提供读取适配器，签名见 `ashub-sources`。

## 引用其他会话

在任一 agent 里引用另一个 agent 的历史会话，继续相关任务。按键需自行绑定：

```elisp
(global-set-key (kbd "C-c @") #'ashub-insert-reference)
```

按 `C-c @` 或在 Pi/DSH 中输入 `@ashub` 后按 `TAB`，列表按「**最后交互｜Agent｜用户首句｜用户末句｜项目｜ID**」对齐，按最后一次用户发消息的时间倒序排列。窄窗口自动隐藏项目列，保留 Agent 和首末消息。时间使用本地时区，不拿助手活动、文件时间或生成标题代替缺失的用户数据；未知字段显示 `—`。DSH 的 query 预览可能已被 Host 截断；升级前已缓存的会话数据会在首次打开选择器时自动刷新，Vertico 标题对齐仅在此选择器内生效。选择后，ashub 把它的用户和助手文本（不含工具调用）导出为 `~/.cache/ashub/refs/` 下的私有 Markdown 文件，再往当前输入区插入文件引用：ghostel 终端（Claude、Codex、Hermes）粘贴 `@路径`，Pi 和 DSH 插入各自的 @文件引用。在 Pi、DSH 聊天里也可以输入 `@ashub` 后按 `TAB`；这需要客户端提供 `emacs-pi-reference-providers` / `emacs-dsh-reference-providers`，引用 DSH 会话还需要 `emacs-dsh-read-session`。提交前不会发送任何内容。

超长会话保留开头和结尾、省略中间（`ashub-reference-max-chars`）。DSH 引用最多包含最近 `ashub-reference-dsh-max-messages` 条消息，因为 Host 不提供更早的分页。也可以脱离 Emacs 导出：`python3 ashub-scan.py export claude ~/.claude SESSION-ID`。

## 常见问题

Pi 首次扫描需要读取会话文件；完成后会保存摘要索引。更新后的 emacs-pi 提供 `emacs-pi-cached-sessions` 时，Hub 下次启动（包括重启 Emacs）会先按时间倒序显示缓存，并标注「缓存待核验」，再后台核对新增、修改和删除，只重新解析变动文件。已有 Hub 列表在刷新期间保持显示。缓存损坏或不可写时自动回退，不修改原始会话。

索引保存在 `emacs-pi-history-cache-directory`（默认 Emacs 配置目录下的 `emacs-pi/history-cache/`），包含会话路径、首末消息预览及文件签名，文件权限为 `0600`。可删除目录中的索引以重建，或将此变量设为 nil 禁用磁盘缓存。旧版 emacs-pi 仍可使用，但没有跨重启预载能力。

Pi 或 DSH 没有显示时，按 `!` 查看原因，并确认当前加载的客户端提供 `emacs-pi-list-sessions` 或 `emacs-dsh-list-sessions`。VC 安装的包可通过 `M-x package-vc-upgrade` 更新；结束活动聊天后重启 Emacs，才能加载新代码。

`[预览]` 表示消息投影预览，`[标题]` 表示标题，不冒充原始首条消息。日期优先用交互时间，否则使用 `updatedAt` 或 `createdAt`；日期后的 `*` 表示来源更新时间/创建时间，并非已验证的交互时间。按 `i` 可查看完整可读对话；隐藏思考内容和工具调用。

顶部分别显示「来源失败」「读取异常」「字段缺失」。缺字段不等于会话丢失；显示数量还受 agent、项目、存活筛选，以及内部、空、归档会话的隐藏规则影响。按 `!` 查看详情。

当前为开发版。部分历史不提供原始首条消息或可信交互时间，这些字段会保留为未知。已归档会话不能直接从 Hub 恢复。
