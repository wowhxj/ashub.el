# 持久生命周期：离线交付检查（非整体验收完成）

## 本次边界

用户在一次隔离 Pi 请求得到 HTTP 401 后明确选择“不再真实调用，继续其他收尾”。
之后没有更换模型、继续模型请求、刷新 OAuth 或改写用户认证/配置。
Ralph 保持 paused；下面是有限的单次回归，不是开发循环。没有安装、提交或推送。

## 可重跑命令

cwd：`/Users/randolph/sandbox/ashub`

```sh
# 产品模块结构、编译、Hub 单元测试；不调用模型
make check
# 私有 staging：编译后整体移位，再用新 Emacs 验证；不安装/不调用模型
make package-check
# 三仓库与真实进程/原生 UI 的离线回归，仍然没有模型 prompt
bash --noprofile --norc .ralph/verify-passive-idle.sh
```

后两个命令需要本机两个客户端源码及 markdown-mode/websocket，完整回归还需要
Ghostel 原生模块。脚本支持 `EMACS_PI_REPO`、`EMACS_DSH_REPO`、
`EMACS_TEST_MARKDOWN`、`EMACS_TEST_WEBSOCKET`、`EMACS_TEST_GHOSTEL`、`EMACS`。
staging 不需要 Ghostel。默认依赖路径记录在保留的 `RESULTS.txt` 中；没有安装依赖。

本次：Darwin、Node 22.23.1、Python 3.14.6、tmux 3.8、Emacs 32.0.50
（6a856248f2a1）。**没有在最低 Emacs/Node 版本或 Windows 上完成兼容性验收。**

## 当前结果

| 检查 | 结果 |
|---|---|
| Hub Python | 41/41 |
| Hub ERT（含 details/search/native/tmux） | 261/261 |
| Terminal owner Python | 29 pass + 1 opt-in skip；随后独立补跑该 normal-exit/SIGKILL/reconnect 测试 1/1 pass |
| Ghostel/tmux 原生 UI | 5/5 |
| Hub→Pi public API | 两个 vertical，各 1/1 |
| Hub→DSH public activity API→隔离真实 Host | 1/1；空会话，不是模型审批验收 |
| Pi Node | 27/27，含真实隔离 Pi RPC 进程，无模型 prompt |
| Pi ERT | 96/96 |
| DSH Node | 12/12 |
| DSH ERT | 192 pass + 2 intentional skips（Windows DPAPI、可选 orderless） |
| staging 产品文件 | 26 个；autoload、warnings-as-errors 字节编译、移位后加载、缺资源拒绝、受控 Pi detach/reattach/finish、受控 managed DSH Host 均通过 |
| 三仓库 diff check | 通过 |

完整回归初次保留了 terminal 原生测试的 opt-in skip；已补跑通过，并将脚本改为显式
`ASHUB_TMUX_NATIVE=1`，今后的完整命令会一起执行它。没有为这项脚本调整重跑整套测试。

## 安装资源与证据

必须随 Lisp 分发：

- ashub：`ashub-scan.py`、`ashub-summary-read.py`、`ashub-terminal.py`；包括新 `ashub-tmux.el` / `ashub-native.el`。
- emacs-pi：`emacs-pi-runtime.el`、`emacs-pi-bridge.mjs`。
- emacs-dsh：`emacs-dsh-runtime.el`、`emacs-dsh-host.mjs`。

只复制 `*.el` 不完整。staging 从当前工作树复制，不证明这些未提交文件已经存在于远端发布包。
它不打包测试/开发脚本，不修改用户 ELPA，不是实际安装验收。

保留文件：

- 单次完整回归：`/tmp/ashub-passive-verification.e1wL4p/`；含命令、cwd、依赖和各项日志。
- 移位安装树、隔离 HOME、构建/生命周期日志：`/private/tmp/as-stage-rwiz48cp/`。
- 仓库归档：`.ralph/artifacts/offline-final/`，含原始日志、manifest 与 staging 结果。
- staging `manifest.json` SHA-256：`69a6549be122350e865b2f0fc00bd0d8b29dce804a7debef60fc8ec4336faf3a`。

staging 准备时两个错误已修正：资源清单误写不存在的 `ashub-jsonl.py`（实际为
`ashub-summary-read.py`）；受控 DSH fixture 要求 home basename 以 `fixture-home` 开头。
这两次不是产品失败或最终通过证据；最终私有 staging 是上面的成功目录。

## 仍然没有验证/交付的部分

- 真实模型的运行中审批、steering 消费、退出重连与正常完成：**未通过验收**。
  唯一实际请求返回 401；隔离实例已确认结束。调用计数见
  `.ralph/artifacts/live-pi/authorization-used.json`。不再使用剩余额度。
- Terminal 三种真实 provider 的 ID/队列/审批行为仍不能用受控生产者替代。
- Pi 的原生活动/idle 证明仍保守，live owner 不能被当成已知 idle；未完成的跨 home
  嵌套存储 symlink 边界不能视为已证明安全。
- Windows persistence、最低依赖版本、实际用户安装及远端发布包尚未验收。
- 六份中英文 README 已同步依赖、资源和退出语义；源文件仍未提交、未安装到用户环境。

公开退出语义保持：Pi/Claude/Codex/Hermes 的显式 `C-c C-q` 结束所属实例；
普通关闭仅 detach。DSH 的 `C-c C-q` 只关闭 UI；单独确认的 managed Host shutdown
才结束那个 Host，绝不操作 Desktop。没有开发 finish 插件。
