# ashub — Agent Session Hub

English | [简体中文](README.zh-CN.md)

Browse and resume your coding-agent conversations from one Emacs buffer. Supports **Claude Code, Codex, Pi, DeepSeek Harness, and Hermes**, using their existing clients rather than replacing them.

## Features

- Sessions grouped by project, with available dates and message previews.
- Search by agent, full session ID, project path, or first user message.
- Keyboard navigation, agent shortcuts, collapsible groups, and session details.
- Asynchronous history loading with per-source diagnostics.

Browsing never starts a chat or sends a message. Press `RET` to resume a session, or `N` to create one. Progress appears immediately in the echo area and header until readiness, failure, or timeout; a session being restored is also marked in its row.

## Requirements

- Emacs **29.1+**. The `use-package :vc` configuration below requires Emacs **30+**.
- Python **3.9+** for Claude, Codex, and Hermes history scanning; no extra Python packages are needed.
- For Pi and DeepSeek Harness: recent versions of [emacs-pi](https://github.com/wowhxj/emacs-pi) and [emacs-dsh](https://github.com/wowhxj/emacs-dsh) with the public session-listing and restore APIs.
- For Claude, Codex, and Hermes restoration: `ghostel` with its native module installed, plus the corresponding CLI on Emacs's `PATH`.

Only the integrations you use need their optional dependencies.

## Installation

```elisp
(use-package ashub
  :vc (:url "https://github.com/wowhxj/ashub.el"
       :branch "main"
       :rev :newest)
  :commands ashub
  :bind ("C-c h" . ashub))
```

Keep your existing agent-client configuration. To connect emacs-dsh to an already running Desktop Host:

```elisp
(setq emacs-dsh-connection-mode 'desktop)
```

Alternatively, clone this repository and add it to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/ashub.el")
(require 'ashub)
```

## Usage

Run `M-x ashub` or press `C-c h` with the configuration above. The Hub fills the current frame; `q` restores the previous window layout without closing chat buffers.

| Key | Action |
| --- | --- |
| `n` / `p` | Next / previous entry |
| `RET` | Resume the selected session |
| `N` | Create a session: choose an agent (default Pi), then choose or create a project directory |
| `j` | Choose a session from all loaded sessions; Vertico/Orderless can filter candidates, and `RET` jumps to the selected row |
| `a` / `o` | Filter by agent / project |
| `1`–`5` | Filter and jump to Claude / Codex / Pi / DSH / Hermes |
| `C` | Clear all filters |
| `c` | Switch project / agent grouping |
| `TAB` | Collapse or expand a group |
| `i` | Show session details and the full readable conversation (user/assistant text; thoughts and tool calls omitted) |
| `l` | Refresh and toggle live-session-only filtering in the Hub; `RET` switches to an open session buffer. `*` marks open rows |
| `d` / `u` / `x` | Mark / unmark the current session / confirm permanent deletion of marked sessions |
| `w` / `W` | Copy the full session ID to the clipboard / project path |
| `R` | Map a renamed/moved project directory to its new location (saved in `ashub-project-relocations`). Missing projects show `[目录缺失]`. If a Pi session's recorded cwd is missing, restore forks it into the mapped directory and removes the old file only after verifying the live session and complete copied history; other agent history is not rewritten. |
| `g` / `!` | Refresh / show diagnostics |
| `q` | Leave the Hub and restore the previous window layout |

`d` can mark only successfully refreshed Claude/Pi sessions; `x` asks for confirmation and permanently deletes their session files. Codex, Hermes, DSH, custom sources, and stale data are not supported. Deletion cannot be undone.

`N` opens the new session through the existing Pi/DSH client or the same terminal backend used for restoration. No first message is sent automatically. Claude terminals launched by `N` are linked to exact history IDs using the terminal PID and Claude's `sessions/<PID>.json` record. Linked sessions show `*` in the main list and retain their indexed date and preview in `l`. Unlinked terminals appear in `l` as `unindexed`; a shared project directory alone never establishes a match. `RET` switches directly to the terminal. Update emacs-pi and emacs-dsh to versions exposing `emacs-pi-create-session` and `emacs-dsh-create-session`.

Project grouping is the default. Agent shortcuts preserve the current project filter; use `C` to return to the full list. If a session has no usable working directory, you will be asked to choose one before restoring it.

## Referencing another session

Continue work from any agent's saved session inside another agent. Bind the command yourself:

```elisp
(global-set-key (kbd "C-c @") #'ashub-insert-reference)
```

`C-c @` lists sessions from all agents in aligned **Last user interaction | Agent | First user query | Latest user query | Project | ID** columns, newest user interaction first. Narrow windows hide Project while retaining Agent and both queries. Timestamps are local time from user messages only; missing data shows `—`, not a generated title, assistant activity or file timestamp. DSH query previews may already be truncated by the Host. Vertico headers are aligned locally without changing global completion settings. The picker exports the chosen session's user and assistant text (tool calls omitted) to a private Markdown file in `~/.cache/ashub/refs/`, and inserts a file reference into the current draft: `@path` pasted into ghostel terminals (Claude, Codex, Hermes), an @file reference in Pi and DSH. In Pi and DSH chats you can also type `@ashub` and press `TAB`; this needs clients that provide `emacs-pi-reference-providers` / `emacs-dsh-reference-providers`, and DSH sessions need `emacs-dsh-read-session`. Nothing is sent until you submit.

Very long sessions keep their beginning and end and omit the middle (`ashub-reference-max-chars`). DSH references include at most the latest `ashub-reference-dsh-max-messages` messages because the Host offers no older pages. The same export is available without Emacs: `python3 ashub-scan.py export claude ~/.claude SESSION-ID`.

## Troubleshooting

If Pi or DSH is missing, press `!` and check that the loaded client provides `emacs-pi-list-sessions` or `emacs-dsh-list-sessions`. After upgrading VC-installed packages with `M-x package-vc-upgrade`, finish active chats and restart Emacs to load the new code.

`[预览]` marks a projected message preview; `[标题]` marks a title, not the original message. DSH previews use the same `turnOutline` data as emacs-dsh. DSH dates use the interaction timestamp when available, otherwise `updatedAt` or `createdAt`, matching emacs-dsh. A `*` marks a source update/creation time rather than a verified interaction time; details show its origin.

The header distinguishes source failures, read issues, and missing fields. Missing fields do not mean sessions were lost; displayed counts also reflect agent, project, and live-only filters and hidden internal, empty, or archived sessions. Press `!` for details.

This is a development version. Some histories do not provide the original first message or a reliable interaction time; these fields remain unknown. Archived sessions cannot be restored directly from the Hub.
