# Pi persistent RPC feasibility probe

## Scope

Temporary standalone bridge and clients; no production-code changes to ashub, emacs-pi or emacs-dsh. The scripts and this report were subsequently archived in ashub docs/research/pi-persistent-rpc-probe/.
Real installed Pi RPC, isolated agent directory and synthetic session file.
No model prompts, paid API calls, user sessions, MCP servers or discovered extensions.
RPC `bash` runs a controlled shell task in this directory, not a model-generated tool call.

## Run

```sh
# From the ashub repository root. Never run the archived script in-place:
# it writes synthetic session files next to itself.
PROBE=$(mktemp -d /tmp/ashub-pi-rpc-probe.XXXXXX)
cp docs/research/pi-persistent-rpc-probe/{probe.py,client.el} "$PROBE/"
python3 "$PROBE/probe.py" test
python3 "$PROBE/probe.py" test --emacs
```

Runs are sequential and overwrite probe state. Requires installed pi, Python 3 and (second run) Emacs.
Each controller starts an independent-session bridge process, which owns Pi stdin/stdout.
One Unix socket client lease; RPC events receive monotonic sequence numbers and are retained in memory.
The test socket is under a private temporary directory with restrictive umask.

## Passed observations

Both Python and real Emacs batch clients were tested for normal exit and SIGKILL.
Each client submits a delayed RPC bash job, then exits before job completion.
With no client connected, the same Pi PID remains alive and completes 1 MiB of output plus a completion marker file.
A separate Python reconnecting client resumes at the last acknowledged sequence, receives contiguous replayed events and the successful bash response, then queries get_state and get_messages.
Session ID/file match pre-disconnect state and messages include the completion marker.

Emacs run: bridge PID 9215, Pi PID 9216; both cases passed with the same live Pi process.
Per case: 18 replayed bash_execution_update records; 21 records read through snapshot/message requests.
Final sequence: 44. All bridge/Pi/test client processes were stopped; socket removed.

The archived scripts were copied to a fresh temporary directory and rerun with `test --emacs`: PASS for both cases, bridge PID 13594 / same Pi PID 13595; 18 replayed updates per case and final sequence 44. This verifies the archived copy is reproducible outside the original probe directory.
Event types, IDs and record byte sizes are retained in event-summary.jsonl without full output.

## Discovered implementation hazard

asyncio's default subprocess line-read limit is 64 KiB. Large RPC records exceed it and terminate a naive reader, causing lost consumption and stalled replies. This bounded probe uses an 8 MiB stream limit. Production needs an explicit byte-framing policy and bounded storage, not this fixed limit alone.

## Not established

- Production emacs-pi transport or UI reconstruction: the Emacs client here is a minimal network client, not the existing package; reconnect assertions currently run in Python.
- Real provider/model streaming, tool approvals, extension UI, queued prompts, retry/compaction behavior.
- Replay durability across bridge crashes or machine restarts; prototype replay is memory-only and unbounded over its deliberately short run.
- Durable single-session ownership/locks, command deduplication, authentication policy for production, stale socket recovery, cancellation and attachment races.
- DSH real running-task detach/reconnect.

The feasibility result establishes that a separate owner of real Pi RPC stdio can survive normal/abrupt Emacs exit, continuously drain output and permit a new client to recover events/state. It is not a shipped persistence feature or full unattended-task guarantee.

## Elisp checks

client.el passed check-parens and batch byte compilation. The bundled checker printed OK despite elisp-lint being unavailable; lint was NOT validated.
