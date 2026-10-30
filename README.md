# ashub — Agent Session Hub

English | [简体中文](README.zh-CN.md)

Browse and resume your coding-agent conversations from one Emacs buffer. Supports **Claude Code, Codex, Pi, DeepSeek Harness, and Hermes**, using their existing clients rather than replacing them.

## Features

- Sessions grouped by project, with available dates and message previews; optional gptel background summaries describe topic and progress in one Chinese sentence.
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
| `?` | Show full key bindings and column-marker help |
| `q` | Leave the Hub and restore the previous window layout |

`d` can mark only successfully refreshed Claude/Pi sessions; `x` asks for confirmation and permanently deletes their session files. Codex, Hermes, DSH, custom sources, and stale data are not supported. Deletion cannot be undone.

`N` opens the new session through the existing Pi/DSH client or the same terminal backend used for restoration. No first message is sent automatically. Claude terminals launched by `N` are linked to exact history IDs using the terminal PID and Claude's `sessions/<PID>.json` record. Linked sessions show `*` in the main list and retain their indexed date and preview in `l`. Unlinked terminals appear in `l` as `unindexed`; a shared project directory alone never establishes a match. `RET` switches directly to the terminal. Update emacs-pi and emacs-dsh to versions exposing `emacs-pi-create-session` and `emacs-dsh-create-session`.

The main content is split into **Summary | Latest user query | Summary status**. Summary shows the AI summary, or only the first user query until one has been generated; it no longer combines first/latest messages. The latest query remains independent. The status column explicitly distinguishes pending, generating, generated, outdated, failed, disabled and paused (Chinese labels). Hover for full untruncated column text and to identify whether Summary contains AI text or a first-query fallback. Original queries also remain in `i` details. Missing latest queries show `[末句未知]`, and DSH projections retain `[预览]`. Narrow windows hide Project but retain all three columns. Existing restore/directory warnings remain at the row end, with full warnings in the status tooltip when space is tight. Key hints occupy one line; press `?` for full help.

Project grouping is the default. Agent shortcuts preserve the current project filter; use `C` to return to the full list. If a session has no usable working directory, you will be asked to choose one before restoring it.

## Compact chat details

Press `i` for a compact header (agent, short ID, project, readable time, summary status and any AI summary). Full paths, source/profile, original first/latest queries and summary provenance are folded under **详细信息**; click it or press `m` to expand. Searching hidden metadata reveals it automatically. Source update/creation timestamps retain `*` rather than posing as interaction times.

Agent messages sit on the **left**, users on the **right**, with separate light/dark-aware backgrounds. Paragraphs and code lines reflow to the window width from cached text, without re-reading history or using models. Role-like lines inside fenced code do not split messages.

- Each message's **复制** button copies its original text, without presentation padding/reflow.
- `C-c C-w` copies the original exported conversation; ordinary region copying includes presentation whitespace.
- `TAB` / `S-TAB` navigate buttons, `g` reflows cached content, `q` leaves details. Reopen with `i` to read newer dialogue.
- Customize `ashub-details-message-width` (100 columns), `ashub-details-message-width-ratio` (0.76), and the `ashub-details-user-face` / `ashub-details-assistant-face` faces.

This reader shows saved user/assistant text, not images, hidden reasoning or tool calls. It is separate from summary input and never modifies agent history.

## Optional background AI summaries

Disabled by default. Enabling this mode sends full readable conversations and tool evidence to your **default gptel backend/model**, potentially incurring API charges. It does not start an agent or modify its history. Add after your existing gptel configuration:

```elisp
(with-eval-after-load 'gptel
  (require 'ashub-summary)
  (setq ashub-summary-idle-delay 300
        ashub-summary-request-interval 60
        ashub-summary-check-interval 30
        ashub-summary-scan-interval 300
        ashub-summary-stable-delay 300
        ashub-summary-read-timeout 120
        ashub-summary-request-timeout 180
        ashub-summary-retry-delay 300
        ashub-summary-retry-max-delay 3600
        ashub-summary-max-attempts 3)
  (ashub-summary-mode 1))
```

All times are positive seconds, configurable in your init file or the `ashub-summary` Customize group. New scheduling uses current values; already scheduled deadlines are not retroactively rewritten. Re-enable the mode to reschedule its check cycle.

- Runs independently of the Hub buffer, gradually backfilling ordinary and archived sessions; known internal/empty sessions are excluded. Emacs-open or restoring sessions are skipped even when idle. After use ends, wait the configured delay; reopening resets it. External terminal usage is not detected. Newly discovered history also observes the waiting/stability windows.
- One model request at a time, at least the configured interval apart. Earlier pending revisions are processed first, with recent history first within a batch, avoiding backfill starvation.
- Saves tokens by **avoiding unnecessary requests**, not shrinking individual inputs: unchanged content is not regenerated, metadata changes are verified without another model call, and successful summaries survive restarts. Initial and updated summaries both use full relevant history, including tool evidence and Pi's saved active branch, not reference-export truncation or old-summary-plus-delta input. Hidden reasoning is omitted.
- Requests use an isolated buffer without unrelated chat context, tools, or prompt transforms. Context-limit errors keep the old summary and stop blind retries rather than silently truncating. Change your gptel model and retry explicitly if needed. Transient backend failures back off the entire queue; configuration/authentication failures pause it until you retry or re-enable the mode.
- Responses are checked against a fresh full read; reopening, changed content, deletion, or disabling the mode prevents stale callbacks overwriting a summary. Cancelling an already-sent request does not guarantee that the provider will not bill it.

Press `s` to requeue a session (still respecting open-session safety and timing), `!` for diagnostics, or `M-x ashub-summary-status` for background status. Details show summary time/model/errors and original queries. Outdated/failed states appear in the dedicated Summary status column, not inside either text column; previous summaries remain visible.

`ashub-summary-cache-file` defaults to `~/.cache/ashub/summaries.json` (respecting `XDG_CACHE_HOME`): an atomically written `0600` file with summaries, fingerprints and scheduling state, not full transcripts. Changing gptel's model does not automatically regenerate everything. Deleting a session through the Hub also removes its summary.

DSH input is limited to what its public read API returns. Reaching `ashub-summary-dsh-max-messages` fails closed. Custom sources can supply `:summary-function` with `(SESSION SUCCESS FAILURE)`, returning cancellation and supplying full transcript text to SUCCESS; see `ashub-sources`. See [the Chinese guide](README.zh-CN.md#后台-ai-摘要可选) for more detail.

## Referencing another session

Continue work from any agent's saved session inside another agent. Bind the command yourself:

```elisp
(global-set-key (kbd "C-c @") #'ashub-insert-reference)
```

`C-c @` lists sessions from all agents in aligned **Last user interaction | Agent | First user query | Latest user query | Project | ID** columns, newest user interaction first. Narrow windows hide Project while retaining Agent and both queries. Timestamps are local time from user messages only; missing data shows `—`, not a generated title, assistant activity or file timestamp. DSH query previews may already be truncated by the Host. Vertico headers are aligned locally without changing global completion settings. The picker exports the chosen session's user and assistant text (tool calls omitted) to a private Markdown file in `~/.cache/ashub/refs/`, and inserts a file reference into the current draft: `@path` pasted into ghostel terminals (Claude, Codex, Hermes), an @file reference in Pi and DSH. In Pi and DSH chats you can also type `@ashub` and press `TAB`; this needs clients that provide `emacs-pi-reference-providers` / `emacs-dsh-reference-providers`, and DSH sessions need `emacs-dsh-read-session`. Nothing is sent until you submit.

Very long sessions keep their beginning and end and omit the middle (`ashub-reference-max-chars`). DSH references include at most the latest `ashub-reference-dsh-max-messages` messages because the Host offers no older pages. The same export is available without Emacs: `python3 ashub-scan.py export claude ~/.claude SESSION-ID`.

## Troubleshooting

The first Pi scan reads session files and saves a summary index. With an updated emacs-pi providing `emacs-pi-cached-sessions`, the Hub displays cached sessions newest first on subsequent starts, including after restarting Emacs, while verifying added, changed and deleted files in the background. Only changed files are reparsed. The header marks these initial results as `缓存待核验` (cached, awaiting verification); existing Hub rows remain visible during refresh. Broken or unwritable indexes fall back safely without changing session files.

Indexes live in `emacs-pi-history-cache-directory` (by default `emacs-pi/history-cache/` under the Emacs configuration directory). They contain paths, first/latest prompt previews and file signatures, with file permissions `0600`. Delete the index files to rebuild them, or set this variable to nil for memory-only caching. Older clients remain compatible but cannot preload summaries across restarts.

If Pi or DSH is missing, press `!` and check that the loaded client provides `emacs-pi-list-sessions` or `emacs-dsh-list-sessions`. After upgrading VC-installed packages with `M-x package-vc-upgrade`, finish active chats and restart Emacs to load the new code.

`[预览]` marks a projected message preview; `[标题]` marks a title, not the original message. DSH previews use the same `turnOutline` data as emacs-dsh. DSH dates use the interaction timestamp when available, otherwise `updatedAt` or `createdAt`, matching emacs-dsh. A `*` marks a source update/creation time rather than a verified interaction time; details show its origin.

The header distinguishes source failures, read issues, and missing fields. Missing fields do not mean sessions were lost; displayed counts also reflect agent, project, and live-only filters and hidden internal, empty, or archived sessions. Press `!` for details.

This is a development version. Some histories do not provide the original first message or a reliable interaction time; these fields remain unknown. Archived sessions cannot be restored directly from the Hub.
