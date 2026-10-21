# ashub — Agent Session Hub

[English](README.md) | 简体中文

在一个 Emacs buffer 中浏览和恢复编程智能体的历史会话。支持 **Claude Code、Codex、Pi、DeepSeek Harness 和 Hermes**，复用现有客户端，不另做一套聊天界面。

## 功能

- 默认按项目分组，展示可用日期和消息预览。
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
| `N` | 新建：选择 agent（默认 Pi），再选择现有项目目录 |
| `/` | 搜索 |
| `a` / `o` | 按 agent／项目筛选 |
| `1`–`5` | 筛选并定位 Claude／Codex／Pi／DSH／Hermes |
| `C` | 清除全部搜索和筛选 |
| `c` | 切换项目／agent 分组 |
| `TAB` | 折叠或展开分组 |
| `i` | 查看会话详情及完整对话（仅用户/助手文本，不含思考和工具调用） |
| `l` | 在 Hub 列表中过滤存活会话；按 `RET` 进入已打开的会话 buffer；`*` 标识已打开 |
| `d` / `u` / `x` | 标记当前会话／取消当前会话的删除标记／确认后永久删除标记会话 |
| `w` / `W` | 复制完整会话 ID 到剪贴板／项目路径 |
| `g` / `!` | 刷新／查看诊断 |
| `q` | 离开 Hub，恢复进入前的窗口布局 |

`d` 仅支持标记已成功刷新的 Claude/Pi 会话；`x` 会再次确认后永久删除对应会话文件。Codex、Hermes、DSH、自定义源及过期数据暂不支持删除。删除不可撤销。

`N` 通过已有 Pi/DSH 客户端或与恢复相同的终端后端打开新会话，不自动发送首条消息。需要升级到提供 `emacs-pi-create-session`、`emacs-dsh-create-session` 的客户端版本。

默认按项目分组。agent 快捷键保留现有项目和搜索筛选，按 `C` 返回完整列表。会话没有可用工作目录时，恢复前会要求选择一个目录。

## 引用其他会话

在任一 agent 里引用另一个 agent 的历史会话，继续相关任务。按键需自行绑定：

```elisp
(global-set-key (kbd "C-c @") #'ashub-insert-reference)
```

按 `C-c @` 后，从所有 agent 的会话中（最新的在前）选一个。ashub 把它的用户和助手文本（不含工具调用）导出为 `~/.cache/ashub/refs/` 下的私有 Markdown 文件，再往当前输入区插入文件引用：ghostel 终端（Claude、Codex、Hermes）粘贴 `@路径`，Pi 和 DSH 插入各自的 @文件引用。在 Pi、DSH 聊天里也可以输入 `@ashub` 后按 `TAB`；这需要客户端提供 `emacs-pi-reference-providers` / `emacs-dsh-reference-providers`，引用 DSH 会话还需要 `emacs-dsh-read-session`。提交前不会发送任何内容。

超长会话保留开头和结尾、省略中间（`ashub-reference-max-chars`）。DSH 引用最多包含最近 `ashub-reference-dsh-max-messages` 条消息，因为 Host 不提供更早的分页。也可以脱离 Emacs 导出：`python3 ashub-scan.py export claude ~/.claude SESSION-ID`。

## 常见问题

Pi 或 DSH 没有显示时，按 `!` 查看原因，并确认当前加载的客户端提供 `emacs-pi-list-sessions` 或 `emacs-dsh-list-sessions`。VC 安装的包可通过 `M-x package-vc-upgrade` 更新；结束活动聊天后重启 Emacs，才能加载新代码。

`[预览]` 表示消息投影预览，`[标题]` 表示标题，不冒充原始首条消息。日期优先用交互时间，否则使用 `updatedAt` 或 `createdAt`；日期后的 `*` 表示来源更新时间/创建时间，并非已验证的交互时间。按 `i` 可查看完整可读对话；隐藏思考内容和工具调用。

顶部分别显示「来源失败」「读取异常」「字段缺失」。缺字段不等于会话丢失；显示数量还受搜索条件，以及内部、空、归档会话的隐藏规则影响。按 `!` 查看详情。

当前为开发版。部分历史不提供原始首条消息或可信交互时间，这些字段会保留为未知。已归档会话不能直接从 Hub 恢复。
