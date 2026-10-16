# ashub — Agent Session Hub

English | [简体中文](README.zh-CN.md)

Browse and resume your coding-agent conversations from one Emacs buffer. Supports **Claude Code, Codex, Pi, DeepSeek Harness, and Hermes**, using their existing clients rather than replacing them.

## Features

- Sessions grouped by project, with last-interaction time and first-message previews when available.
- Search by agent, full session ID, project path, or first user message.
- Keyboard navigation, agent shortcuts, collapsible groups, and session details.
- Asynchronous history loading with per-source diagnostics.

Browsing never restores a session or sends a message. Press `RET` to explicitly resume the selected session.

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

Run `M-x ashub` or press `C-c h` with the configuration above.

| Key | Action |
| --- | --- |
| `n` / `p` | Next / previous entry |
| `RET` | Resume the selected session |
| `/` | Search |
| `a` / `o` | Filter by agent / project |
| `1`–`5` | Filter and jump to Claude / Codex / Pi / DSH / Hermes |
| `C` | Clear all search and filters |
| `c` | Switch project / agent grouping |
| `TAB` | Collapse or expand a group |
| `e` / `d` | Expand the first message / show session details |
| `w` / `W` | Copy the full session ID / project path |
| `g` / `!` | Refresh / show diagnostics |
| `q` | Close the Hub without stopping chat buffers |

Project grouping is the default. Agent shortcuts preserve the current project and search filters; use `C` to return to the full list. If a session has no usable working directory, you will be asked to choose one before restoring it.

## Troubleshooting

If Pi or DSH is missing, press `!` and check that the loaded client provides `emacs-pi-list-sessions` or `emacs-dsh-list-sessions`. After upgrading VC-installed packages with `M-x package-vc-upgrade`, finish active chats and restart Emacs to load the new code.

This is a development version. Some histories do not provide the original first message or a reliable interaction time; these fields remain unknown. Archived sessions cannot be restored directly from the Hub.
