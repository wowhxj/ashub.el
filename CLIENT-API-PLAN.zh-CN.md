# 客户端公开接口：待确认改造方案

状态：本文保留接口设计提案；用户已通过 DeepSeek Harness 在源码项目完成四个公开 API 的开发实现，ashub 已接入。提案中的完整契约与验收项仍需逐项核查，不因 API 存在而自动视为全部完成。范围仅为用户维护的 emacs-pi、emacs-dsh 源码项目，不修改 agent 本体、runtime 安装副本或远端仓库。当前进度见 `IMPLEMENTATION-STATUS.zh-CN.md`。

## 1. 公共原则

- 增加程序调用接口，不替换现有交互 picker。
- 将创建／复用聊天 buffer 与显示窗口拆开；旧命令保留原有默认显示行为。
- 新接口默认使用当前窗口，不删除其他窗口；提供 display 参数：current（当前窗口）、none（不主动显示）、或标准 display-buffer action。
- ashub 优先用 none 获取目标 buffer，再遵循 Hub 的显示和窗口复用策略。
- 精确指定会话，不创建替代 session，不更改审批参数，不清理、归档或重命名其他会话。
- 新恢复接口严格校验明确工作目录；不静默退回其他目录。
- 返回 buffer 只代表已创建／复用聊天界面，不等于 agent 已成功恢复。
- 恢复必须验证服务端或 RPC 返回的会话身份；身份不匹配时报告失败，不能标记为恢复成功。
- 不支持的数据源／profile 必须明确拒绝，不能借用默认连接打开同 ID 会话。

## 2. emacs-pi

### 2.1 指定会话恢复

建议新增程序接口：

```elisp
(cl-defun emacs-pi-open-session
    (session-file &key directory session-directory
                  (display 'current) on-ready on-error))
```

- session-file：必须存在且可读的指定会话文件；使用完整规范路径识别，不使用 ID 前缀。
- directory：明确启动目录；不提供时可取 header 的 cwd，但不存在或未知时直接报错，不弹出隐式目录选择。
- session-directory：可选数据源覆盖，不更改全局客户端配置。
- 相同真实 session-file 已打开且连接健康时复用，不重复启动。
- 确认进程已退出时沿现有 restart 机制恢复同一会话，尽量复用 buffer；无法确定时明确报错，不主动重复启动。
- 返回目标 buffer；on-ready(buffer) 在 RPC 状态确认恢复身份后调用，on-error(failure) 报告异步失败。
- 对每次有效请求，ready/error 终态回调最多一个；超时、进程退出与异步旧响应需要请求／连接代次防护。
- 不能通过恢复后自动发送测试消息来探测是否成功。

预期变更：

- emacs-pi.el：增加公开入口，拆开内部 open 的创建与显示；原有交互命令保留默认行为。
- emacs-pi-session.el、必要时 emacs-pi-rpc.el：复用既有启动、状态更新、代次和重启能力，增加最小就绪／失败通知。
- test/emacs-pi-test.el 与已有 fake-pi：增加指定恢复、身份校验、存活复用、死进程重启、目录校验、窗口保持与回调测试。
- README.md、README.zh-CN.md、CHANGELOG.md：记录接口及生命周期语义。

上述 callback 名称和数据结构在具体实现中应一致记录；错误对象不包含凭据或默认复制聊天正文。

### 2.2 只读枚举（用户已确认纳入范围）

```elisp
(cl-defun emacs-pi-list-sessions
    (on-success &key directories on-error))
```

- 只读本地历史，不启动 Pi 或 RPC 进程。
- 未指定 directories 时遵循客户端配置、环境变量与默认存储目录；显式指定时支持多个会话目录。
- 返回完整 ID、规范会话文件路径、数据源身份、项目目录、首条用户消息、最后交互时间及其来源。
- 返回可可靠识别的空会话、内部子会话等状态；无法判断时标为未知，默认过滤由 ashub 负责。
- 支持异步且可取消的扫描；损坏记录附带诊断，其他可用结果仍能返回，不静默漏掉记录。
- 与现有 emacs-pi-history-list 共用解析逻辑，避免维护两套解析器；保留现有调用兼容性。
- 不以有限前缀扫描证明会话为空，不以文件修改时间冒充准确消息时间。
- 增加 emacs-pi-history.el 的读取、调度与诊断测试，覆盖多目录、取消、损坏、非文本首条输入、最新消息时间和未知状态。
- 扫描取消句柄、结果与诊断结构在实现前明确记入接口文档，不因采用回调就声称已实现非阻塞扫描。

职责修正：Pi 与 DSH 都由各自 Emacs 客户端负责枚举和恢复；ashub 不再另写 Pi 日志解析器。Claude Code、Codex、Hermes 的读取仍由 ashub 适配器负责。

## 3. emacs-dsh

### 3.1 指定会话恢复

```elisp
(cl-defun emacs-dsh-open-session
    (session-id &key directory (display 'current) on-ready on-error))
```

- 使用当前明确配置的连接；数据源必须与该连接匹配，不声称该接口已支持同时连接任意多个 Host。
- directory 必须可用且明确；客户端不能以 project-root 静默替换。
- 仅恢复 session-id，不走交互 resume picker，也不调用 archive-empty-sessions。
- 根据显式连接模式进行连接；Desktop 不偷偷改为 managed。
- 发起操作为异步：不承诺同步返回 buffer；通过 on-ready(buffer) 返回经过会话身份与连接快照确认的目标。
- 活跃 buffer 直接复用；失联则采用可验证的重连路径，不把 buffer-live-p 当作连接健康证明。
- 不删除其他窗口；窗口显示模式与 Pi 一致。

### 3.2 只读枚举

```elisp
(cl-defun emacs-dsh-list-sessions
    (on-success &key on-error))
```

- 异步回调返回会话元数据和来源身份；具体字段以验证后的 Host API 为准。
- 返回已配置连接中可枚举的会话，不在客户端静默隐藏空会话或执行清理；ashub 负责默认过滤。
- 未提供的字段保留未知状态，原始首条用户消息不能用生成标题冒充。
- 认证或服务不可用时返回明确错误，不自动启动 managed Host，也不切换连接模式。
- 必须将现有 ensure-auth 内“发现已运行服务／认证”和“启动服务”路径分开，不能简单包装当前会自动启动的通用调用。
- 严禁调用 workspace/archiveSession、创建／激活 agent 或订阅完整聊天流来枚举。
- 成功／失败回调必须有超时和一次终结语义；不泄露 bridge token。
- 若不能从 API 验证无管理写入／无启动副作用，则此接口暂不可宣称完成。

预期变更：

- emacs-dsh.el：公开入口、显示职责拆分、禁止启动的枚举连接路径、异步生命周期和错误处理。
- 该项目实际测试文件：先确认现有测试布局，再扩展连接、窗口、身份、枚举不启动／不归档测试；不修改 .release 下参考项目。
- README 与变更记录：说明新接口、连接限制与错误语义。

## 4. 尚需核实、不能用假设代替的内容

1. DSH session/list 的服务端只读保证、主子会话／归档字段、原始首句及更新时间语义。
2. Pi 的精确恢复状态确认与 session-file 回传规范；不同目录恢复能否真正约束 cwd。
3. DSH 的本地 directory 和 Host 已保存 cwd 是否能够一致；若 Host 不允许更换 cwd，不能只改 buffer 的 default-directory 就声称已更换工作目录。
4. 同时多个 Host／profile 的连接与 buffer 注册表隔离；本次不偷偷扩展成客户端大重构，发现缺口先报告。
5. 新接口当前窗口显示行为与现有客户端钩子的副作用。

## 5. 测试与执行边界

- 首先使用 mock／fake 后端和 ERT，禁止测试触发真实 Host 启动、归档或发送消息。
- 有意义的 Elisp 修改后运行 elisp-checker；使用隔离输出避免生成或加载陈旧 .elc。
- 检查最终 diff，并运行原有测试回归。
- 真实恢复和继续聊天需另行确认测试会话。
- 不自动 git commit、push、安装 package 或修改 chemacs2/runtime 配置。

## 6. 本次请求确认的范围

是否同意按上述最小方向开始两个 Emacs 客户端的接口改造与隔离测试；遇到 DSH 服务端契约无法确认或需要修改 agent 本体的情况，停止该分支并报告，不绕过约束实现。
