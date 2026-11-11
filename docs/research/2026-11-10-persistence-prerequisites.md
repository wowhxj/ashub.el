# 持久化前置条件：Pi bridge 部署与 DSH finish 能力

日期：2026-11-10。性质：只读本机代码/已安装程序核对；未对用户 session 发出写请求，未停止 Desktop Host，未执行 DSH 模型任务。

后续范围更新：用户已确认 Pi bridge 使用 Node，并补充 DSH 的 C-c C-q 不必与 Pi 一致，保持关闭界面、保留 Desktop/Host session。因此本报告关于 DSH finish/plugin 的建议已退出当前实施范围，不再是阻塞项；停止插件探索，未安装或注入任何 Host。DSH managed 持久化与重连仍需实施。

## 结论

1. Pi bridge 推荐正式使用随 emacs-pi 发布的 Node 标准库 `.mjs` 程序，不将 Python 原型直接转为安装依赖。该选型已获用户确认。
2. DSH 已检查的 session 远程接口不能直接实现完整 finish：cancel 保留队列，updateQueue 是逐项修改；未在该 namespace 找到 finish/close/unload。不能由此断言整个 Host 不存在其他内部能力。
3. 若坚持“不归档历史、结束运行并释放资源”，需进一步验证显式安装的 Host 侧 companion plugin 是否能提供安全、可等待完成的 finish 操作。仅靠现有 Emacs 客户端 HTTP 调用还没有证据支持完成目标。
4. 用户要求 DSH managed 模式也持久化；这不消除共享 Desktop Host 的目标 session 结束问题。

## Pi 部署候选

本机 Pi：`@earendil-works/pi-coding-agent` 1.5.0，package.json 声明 Node `>=22.19.0`；当前 node 为 v22.23.1。emacs-pi 0.3.4 当前 Package-Requires 为 Emacs 29.1 + markdown-mode，安装方式支持 package-vc 和手工 load-path。

建议：

- Node 标准库子进程、Unix socket、文件锁/日志；不 import Pi 内部模块，不需要编译或 npm install。
- bridge 源文件随 emacs-pi 安装；Emacs 根据已加载包的位置定位，不能依赖开发 checkout 或 cwd。
- Node 与 Pi CLI 路径分别可配置/预检。对于自包含 Pi 或包装脚本，不得推断一定有可单独执行的 Node。
- package-vc 与手工安装都需验证非 Elisp 资源确实随包存在；用 staging 安装验证，不改当前用户 ELPA。
- 第一个受控实现平台为 macOS/POSIX。Windows/named pipe、Windows 进程脱离与跨用户权限需独立设计和测试；未经支持时明确报错。
- 明确升级协议：客户端/bridge 握手版本，不在旧实例运行中覆盖/偷偷重启它。
- 所有路径 argv 传参，避免 shell 拼接；私有运行目录及本地 IPC。不以本机无 TCP 监听就推断没有权限风险。

以上为部署设计建议，尚未编写正式 bridge，也未证明 Windows 和自包含 Pi 的支持。

## DSH 程序来源与版本

Desktop ASAR：`/Applications/DeepSeek Harness.app/Contents/Resources/app.asar`

SHA-256：`f21d83abfb33d463822a52c439cc9b15c8245dbce4ae4cf9424c90eae8eba94f`

相关成员：

- `dsh/node_modules/@deepseek-ai/dsh-api-session-controller/lib/index.js`
- `dsh/node_modules/@deepseek-ai/dsh-agent/lib/index.js`
- `dsh/node_modules/@deepseek-ai/dsh-session/lib/index.js`

以上包的版本均为 `0.2.2-rc.1`。独立 CLI 顶层 `@deepseek-ai/dsh` package.json 为 `0.1.7-rc.2`，但其当前安装的 `dsh-api-session-controller` 依赖实际为 `0.2.2-rc.1`；不能用顶层 CLI 版本推断所有运行包版本。

Desktop 与独立 CLI 的 controller `lib/index.js` 内容 SHA-256 相同：

`4cf6c66e65cce865d270fa89405b96d048ffa62e493e4ffbd1a826be2207a4cd`

## 已观察实现

### cancel 不是 finish

controller `lib/index.js:956–965`：

```js
cancel(request) {
  const agent = this.ctx.agents.get(request.sessionId);
  // 不存在和 subagent ownership 的检查省略。
  agent.cancel({ kind: "user" }, { keepInbox: true });
  return { accepted: true };
}
```

这是对实际随包代码的节选，不是可复制的新实现。`accepted: true` 只确认请求 cancellation，不等待执行结束，也不卸载 Agent。

### 队列只有逐项更新

controller `lib/index.js:903–953` 的 updateQueue：按 itemId 查询 nextTurn/nextStep，支持 edit/remove/steer。remove 从 inbox 删除单项，必要时 retirePrompt。它不是原子“冻结准入 + 清空队列 + 停止执行 + 等待退出”。控制器还可能恢复 cold Agent，不能用它冒充无副作用 inspect。

### 远程 session namespace 的注册清单

controller `lib/index.js:3445–3470` 注册 list/search/create/selectModel/rename/fork/prompt/attachment/updateQueue/cancel，以及 page/events/observeEvent/observeProjections/state/observeState/wait/follow/projections/control 等方法；这份已检查清单中没有 finish/close/unload。

这是该 controller 的静态观察，不是所有插件/namespace 的穷举。客户端不能凭空发出未发现的 `session/close` 请求。

### 内部释放与归档不是同一个契约

`dsh-session/lib/index.js` 有 detach disposer 与 session/disposed 生命周期；`dsh-agent/lib/index.js` 也有 store removal/disposal 路径。仅看见 disposer 不能推断安全远程 finish：仍需确认其所有者、执行取消顺序、持久化 flush、队列、jobs、subagents 和 schedule 的处理。

`dsh-agent/lib/index.js:9–39` 的 archive-admission 在 running 时使用不带 keepInbox 的 cancel；`dsh-api-session-controller/lib/index.js:3240–3288` 的 ArchivedSessionGate 阻止归档 Session/其 subagent 后代继续模型步骤。这说明现有“禁用后续执行”的一条机制绑定 archive 状态；不能偷偷归档或临时归档再恢复，来模拟用户要求的非归档 finish。

### Emacs managed Host 当前确实依附 Emacs

`emacs-dsh.el:508–521` 的 managed-stop 删除拥有的 dsh web 进程，并挂在 kill-emacs-hook。删除这个 hook 不能独自解决 stdin/进程树/凭据发现及重连问题。

## 旧范围下的插件验证边界（已停止，不属于当前下一步）

建议先在 emacs-dsh 仓库构建独立测试用 Host companion plugin，不改 Desktop ASAR、不默认注入当前 Desktop、不操作真实 session。评估其能否：

1. 在目标 Session 范围内冻结新的 admission 和队列启动。
2. 清理待执行消息并取消当前任务及其拥有的工作，等待 settlement。
3. flush 后释放目标 Agent/Session 运行资源，保留原日志及 Workspace 非归档身份。
4. 生成可查询的完成回执；完成前不返回 finished。
5. 避免其他 Desktop 客户端、jobs/schedules/children 立即唤醒目标；定义显式重新打开才能清除的结束栅栏。
6. 不影响同 Host 其他 session，且遵守 Host 的 session/subagent ownership 与权限边界。

若当前 plugin API 做不到，需要 Host 上游能力，而不是继续堆 Emacs 侧轮询/取消。届时需回到用户确认是否扩大改造范围。

真实模型断连测试、原生 emacs-dsh 状态恢复和资源回收仍未验证。本轮只能结论“已找到不能误用 cancel 的证据”，不能宣布 DSH 持久化验收通过。

## 工具与证据限制

先使用 REA 对 ASAR 做静态分析：完整结果超过 MCP 传输预算，retained view 又报告父记录类型不兼容；REA 的整包提取超时。随后只读解析 ASAR header/成员 offset，定点复制相关程序包到临时目录，不执行包代码、不读取用户 profile。对定点 controller 目录再做 REA 分析，返回摘要 Evidence `ev_a64d802529103c8ed9fb3fcd9bc8d4e0fc4cfeffa6f00c6132eb4afbabddffdb`，operation 为 inspect_analysis_view；图覆盖不完整。本文关键结论依赖可逐行复核的随包文本及上述文件 hash，不把静态图候选当运行时保证。
