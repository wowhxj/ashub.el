# DSH passive quiescence evidence (2026-11-10)

## Boundary

`session/list.running=false` is not an idle proof. The narrower native
`session/wait` contract can prove current quiescence without starting an Agent,
claiming events, cancelling work, answering approvals or installing a plugin.
This changes summary eligibility, not ownership: DSH chat quit remains detach.

## Shipped static evidence

The extracted `dsh-api-session-controller` package has artifact SHA-256
`5a2d93ad420998f1793885d69fa6ee38d60f80b507fbc07aa163b74b124de365`.
REA's retained JavaScript application observation is
`ev_86bb9241c678ff3e5cde2b5dce1af53b720a773a7502546f051ec7e9650ca08d`.
Its authority is **shipped-artifact**, confidence **derived**; 62 limitations
remain. A graph is not execution proof or a claim of complete equivalence.

Read directly alongside that observation:

- `lib/index.js` `StateController`, approximately lines 2200–2410.
- `lib/typert.remote-client.js` schemas for `session_state` / `session_wait`.
- `HistoryController.assistantOutput`, approximately lines 1895–1925.

Native `wait` arms a passive listener and returns `reason`, the last complete
`state`, and bounded `output`. It checks current observation revision and exact
Agent/session identities. Pending Remote input wins; running waits; inactive
returns idle; active non-running requires `agent.whenIdle()` racing the next
state. Aborting this observation does **not** cancel Agent execution.

State fields are `cursor`, explicit boolean `active` / `running`, `queue`
(array when active, null otherwise), and `pendingInput` (an array whose members
are `approval`, `question`, `other`). Queue placement maps `nextTurn` to queued,
user `nextStep` to steering, and non-user `nextStep` to context. The last kind is
not a pending user turn: it can remain in a quiescent blank session.

Preserved canonical REA bundle (work artifact, not a runtime dependency):
`.ralph/artifacts/dsh-passive-state-evidence.json.gz`. It contains two records;
uncompressed size 48,837,962 bytes. Gzip SHA-256:
`1ed72861a9b69c0c758f64a0e910970fa5afafdee95d693e208dfacf98bcf657`;
uncompressed canonical bundle SHA-256:
`17fadf25c3c31e3801b2ce1dc82bc72c1d97b9d2586743eff5b59a9dc1dc902d`.
Uncompress to a temporary file for REA `import_evidence_bundle`; do not execute
its source content. An initial export after an idle connection had zero
records; it was replaced by a fresh analysis + immediately verified two-record
export. Historical IDs alone are not asserted to be portable retained evidence.

## Client/Hub contract

`emacs-dsh-inspect-session-activity` authenticates only an existing Host and
calls `session/wait` with a **named request argument**, not flattened fields:

```json
{"request":{"sessionId":"EXACT-ID","timeoutMs":250,"afterSeq":9007199254740991,"maxMessages":1}}
```

The future exclusive cursor suppresses assistant records and their scan. Native
queue contents can transit the request buffer; the public result returns only
source/session, activity, booleans, cursor, actionable queue count, dormant
context count, and pending-input count. An 8 MiB typed-response limit and
4-second client deadline fail closed. Legacy RPC consumers retain their prior
JSON representation; the new API preserves false/null/empty arrays distinctly.

Only explicit native idle with complete valid state, no running flag,
no actionable queue and no pending input allows idle. Timeout is unknown;
malformed/missing/unsupported state and source changes are generic errors.
Inactive null queue means no active queue, not a global persisted-inbox claim.

Hub binds that sample to configuration + authenticated Host generation + exact
session. Missing, expired or changed evidence blocks both candidate dispatch
and in-flight result acceptance, without resetting idle/stability clocks. The
opt-in native summary scheduler checks at most every five seconds and permits
only two outstanding activity reads. It never queries on render, activates a
cold session or stops a Host to manufacture eligibility.

## Current verification and limits

- Real isolated managed Host + independent Emacs normal exit/SIGKILL/resume:
  same generation, passive blank-session idle, no model work; 12/12 Node tests
  including existing supervisor/Host lifecycle cases.
- Separate Hub → public source client → real isolated Host integration: 1/1;
  UI detached, idle sample opens summary gate, no activation/open/start fallback.
- Typed wire representation, queue/running/pending-input/schema negatives,
  silent cancel, source mismatch, callback races, concurrency, clock stability,
  summary dispatch/result guards have controlled ERT coverage.
- These do **not** validate a real model/queued-user/approval lifecycle. Busy and
  pending-input negatives currently replay controlled shapes, not live model
  tasks. This is a cursor-time sample, not a reservation against future input;
  source/history revision and current sample must still be revalidated.
- The first live probe correctly rejected a flattened RPC argument with
  `gateway/arguments-invalid`; wrapping it in `request` fixed the wire call.
  A second probe exposed one dormant bootstrap context item; classification now
  distinguishes its documented placement rather than weakening the idle check.

Exact test commands and logs are recorded in
`.ralph/persistent-agent-lifecycle.md`; final cross-repository acceptance remains
open. User configuration/packages/Desktop sessions were not modified.
