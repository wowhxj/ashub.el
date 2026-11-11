# Terminal native identity: bounded evidence, not history guessing

Scope: `ashub-terminal.py`, `ashub-tmux.el`, `ashub-open.el`, `ashub.el`.

## Evidence and limits

The installed `claude`, `codex`, and `hermes` were invoked **only with `--help`**, with temporary HOME/provider homes and telemetry disabled. Help output is retained locally in `/tmp/ashub-{claude,codex,hermes}-help.txt`. No model invocation, interactive login, real user conversation, or installed source/configuration update was used to validate these contracts.

- Claude help explicitly documents `--session-id <uuid>` for a chosen conversation ID. Fresh launches through the `claude` executable receive a random UUID as two literal argv elements. The PID-record codec uses the existing Hub detector's `sessions/<pid>.json` schema (`pid`, `sessionId`); a fresh provider process producing this record has **not** yet been acceptance-tested.
- Codex decoding uses the existing rollout `session_meta.payload.id` schema. Only a **writable descriptor held by the owned primary process** is evidence. File name, creation time, cwd, and newest-file order are not identity sources. Device/inode must match the subsequently opened file. The npm `@openai/codex/bin/codex.js` launcher may be followed only to one direct, same-group executable named `codex`, with the parent executable verified as Node/Bun. Arbitrary tool descendants/subagents are not searched. The real npm topology is not yet runtime acceptance-tested.
- Hermes help documents resume/continue but does not establish an externally chosen fresh-ID argument. Read-only inspection of the installed `hermes_cli/active_sessions.py`, `terminal_breadcrumbs.py`, `cli_init_mixin.py`, `cli_session_mixin.py`, and `cli.py` established the CLI PID lease plus exact terminal breadcrumb formats. **No Hermes module is imported or called by the owner**: its registry helpers can prune/rewrite shared state. The codec reads JSON only.

These codecs are verified with controlled producers inside actual private tmux/PTY owners. That proves lifecycle and decoding behavior, **not** successful real-provider model/approval/queue restoration. Missing files, unsupported CLI versions/frontends, unavailable descriptor inspection, malformed records, or contradictory evidence retain a durable pending/uncertain instance instead of guessing a native ID.

## Ownership and stale data

The owner knows the actual child PID because it forked that still-unreaped child. A pre-exec gate permits capturing stale native records before the provider starts. An unchanged old PID record or unchanged matching Hermes lease is not adopted. Another process modifying the shared Hermes registry does not validate an unchanged matching entry. PID data is an identity observation, never authority to signal an arbitrary recorded process.

Hermes additionally requires the breadcrumb for the actual owned tty to have changed since the gate and to agree with the primary CLI lease. Native `/new`/compression can rotate the breadcrumb while leaving an earlier lease ID: that is explicitly uncertain, not a stale-ID association. Configurations disabling terminal breadcrumbs remain conservative.

On macOS descriptor inspection uses bounded `lsof -FfaniD` output; `ps` is used only for the narrowly recognized npm launcher. Missing tools or exhausted budgets do not cause fallback history guesses. The Linux `/proc` path has not been runtime-tested in this macOS acceptance run. Provider JSON and first-line reads are size-bounded and symlink leaves are rejected. Regular-file device/inode checks prevent resolving an open-descriptor observation to replacement path contents.

## Mutable conversation, immutable instance

A runtime ID is opaque and does not derive from a mutable native conversation ID. Native ID changes preserve runtime ID, generation, backend PID, and controller lease. The old native IDs remain conservatively reserved until that instance ends, because generic CLI inspection cannot prove all earlier conversation writers are drained. At 32 reservations, overflow blocks other history recovery for that storage home rather than silently dropping reservations. Reconnecting the current ID remains possible.

An unknown owner blocks history restore across its entire canonical storage home, even for a different ID: its old metadata cannot establish what its surviving child is writing now. This does not authorize killing it by recorded PID. Terminal inventory/summary guards honor previous-ID reservations and source-wide unknown states without pretending they are active model generation or resetting idle clocks.

Managed Emacs buffer metadata is synchronized only for the same runtime ID **and generation**. An old instance-cache entry cannot associate a changed conversation with an earlier history row. Managed buffers never consult a Ghostel attach-client PID as a provider PID. History open asks the owner before reusing a UI; custom legacy terminal backends remain an explicit separate path.

## Verification (2026-11-10)

Working directory `/Users/randolph/sandbox/ashub`:

- `ASHUB_TMUX_NATIVE=1 python3 test/terminal-owner-test.py`: **30/30**; real tmux/PTY and independent Emacs normal-exit/SIGKILL cases, controlled provider records only. Log `/tmp/ashub-identity-tests.log`.
- Full Hub ERT including `test/runtime-inventory-test.el`: **196/196**. Log `/tmp/ashub-identity-ert.log`.
- Existing native Ghostel renderer suite: **5/5**, no module installation. Log `/tmp/ashub-identity-ghostel.log`.
- Python syntax, Elisp check-parens, warnings-as-errors byte compilation of the three changed production Elisp modules, and `git diff --check`: pass. Log `/tmp/ashub-identity-compile.log`. `elisp-lint` is unavailable and is not claimed to pass.

Exact commands and remaining final acceptance work are recorded in `.ralph/persistent-agent-lifecycle.md`. This is an iteration result, not the three-repository final gate.
