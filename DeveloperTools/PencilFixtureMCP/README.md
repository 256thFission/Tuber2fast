# PencilFixtureMCP

Development tooling only — not the in-product AI agent.

Runs two **Debug** protocols on an explicitly named connected physical iPad: persistent conversational feedback threads with event-driven Codex task resumption, and separate authentic Pencil fixtures. Agents collect durable JSON and attachments; the human does no Mac-side file copying. The server stops when no physical iPad is available and never falls back to a simulator.

Canonical lifecycle: `Docs/DeviceWorkflow.md`. Protocol detail:
`Docs/Development.md` § Human device loop, Skill `human-device-loop`, and
evidence fields in `Docs/templates/EvidencePacket.md`.

## Tools

| Tool | Purpose |
|---|---|
| `request_pen_fixture(description, scenario?, requester_id?, stale_after_seconds?)` | Enqueue a physical-iPad Pencil capture request; launch only when the queue was idle |
| `request_human_review(prompt, title?, scenario?, requester_id?, stale_after_seconds?)` | Legacy physical-iPad one-shot verdict request; prefer `create_feedback_thread` for new UI review |
| `await_interaction(request_id, timeout_seconds?, owner_token?)` | Poll the pinned iPad until the human finishes; return fixture/verdict/index |
| `collect_interaction(request_id, owner_token?)` | One-shot pull of completed physical-device artifacts |
| `cancel_interaction(request_id, owner_token?, reason?)` | Safely cancel an owned pending or stale request |
| `list_interactions()` | On-device index + local request catalog |
| `list_pen_fixtures()` / `get_pen_fixture(name)` | Read fixtures |
| `replay_pen_fixture(name)` | Install fixture and relaunch replay seam |

Feedback threads are a separate protocol and store. They do not replace Pencil
fixture capture or change its corpus.

Guided human review, asynchronous Review Runs, and harness conformance are different operating modes. One guided journey uses one visible feedback thread and presents one action plus, when needed, one short question at a time. A Review Run uses one visible checklist for independent human-autonomous steps and wakes the originating task only when the human taps `Finish Review`. Harness conformance may create multiple internal threads to test queues, ordering, lifecycle, ownership, and persistence, but those fixtures must not appear as a guided human journey.

Human-facing feedback copy should be easy to scan on the iPad:

- Keep titles and objectives brief.
- Request only one action and, optionally, one question at a time.
- Avoid dense paragraphs; use a single sentence when a list would add no clarity.
- Keep IDs, tokens, sequence cursors, lifecycle/queue states, expected assertions, artifact paths, and test keys in host-side evidence only.
- Do not request an exact answer and a PASS/FAIL verdict in the same step.

| Feedback-thread tool | Purpose |
|---|---|
| `create_feedback_thread(...)` | Create an owned queued thread and watch record, pin its target, and deliver it for device-owned activation |
| `post_thread_message(...)` | Append an idempotent informational model message; rejects new messages while `awaiting-model` |
| `ask_thread_question(...)` | Append a free-text or single-choice question |
| `await_thread_response(...)` | Active-turn fast path: wait from an exclusive cursor for a human response |
| `collect_thread_updates(...)` | Mirror new messages and sent screenshot files to durable Mac paths |
| `get_feedback_watch_state(...)` | Return unseen human/terminal wake eligibility without mutating the thread |
| `arm_codex_feedback_wake(...)` | Hand the next reply to the originating Codex CLI thread through the local app-server bridge |
| `acknowledge_feedback_wake(...)` | Idempotently acknowledge a scheduled/delivered wake and advance its cursor |
| `close_feedback_watch(...)` | Stop host monitoring without resolving the thread or releasing its slot |
| `set_feedback_thread_state(...)` | Optimistically transition lifecycle state; only the device advances FIFO |
| `cancel_feedback_thread(...)` | Idempotently cancel and release a thread; normally owner-token authorized, with an explicitly confirmed audited system-cleanup mode for orphaned development sessions |
| `get_feedback_thread(...)` | Read the durable snapshot and append-only history |
| `export_feedback_thread(...)` | Write an evidence-oriented Markdown transcript and attachment path list |
| `create_review_run(...)` | Create one durable asynchronous checklist containing only human-autonomous steps and explicit prerequisites |
| `collect_review_run(...)` | Collect one submitted ordered result bundle; repeated collection is idempotent |
| `cancel_review_run(...)` | Cancel an owned active Review Run |
| `export_review_run(...)` | Export Review Run JSON/Markdown plus the underlying transcript and attachments |

Every mutating model operation uses an `idempotency_key`. State changes also
require `expected_last_sequence` and `last_consumed_sequence`; stale resolution
is rejected so the model cannot resolve across an unseen human reply. Keep the
`owner_token` returned by creation. Only its SHA-256 hash is persisted. Resolved
and cancelled threads are immutable; only blocked threads may resume.

If an agent lost the token for an orphaned development session, cleanup must be
deliberate: call `cancel_feedback_thread` with a specific `reason`,
`system_cleanup=true`, and `confirm_system_cleanup=true`. This exceptional path
does not mint or reveal an owner token. Cancelling the active thread reconciles
the ledger against canonical snapshots and activates exactly one queued thread;
duplicate queue sequence values are ordered deterministically by thread ID.

Composer drafts are session-owned per feedback thread. Reply text, selected
choices, and optional comments survive focus changes, compact/full-screen
transitions, and capture/annotation presentation. They clear only after the
corresponding submission succeeds.

A normal guided loop is:

```text
create_feedback_thread
await_thread_response while the initiating Codex turn remains active
arm_codex_feedback_wake before yielding when no response has arrived
the bridge resumes the originating Codex CLI thread on the next eligible wake
collect and record the current response
ask_thread_question or post_thread_message
repeat active wait or bridge handoff
set_feedback_thread_state
export_feedback_thread
```

A human-autonomous packet uses `create_review_run`, one active wait or bridge
handoff, and no intermediate model messages. Step edits, choices, comments, and attached
annotations persist in `thread.json` without producing a wake. `Finish Review`
appends exactly one human summary message. The resumed task acknowledges that
wake, calls `collect_review_run`, and may then call `export_review_run`.

After a human reply moves the session to `awaiting-model`, present the next
human step with `ask_thread_question`. It reopens the session and appends the
actionable interaction atomically. `post_thread_message` deliberately rejects a
new message in that state so visible instructions cannot leave reply controls
read-only; an idempotent retry of an already-posted message remains valid.

Every created feedback thread gets a gitignored watch record under
`.feedback-threads/watches/`. The record contains requester identity, cursor,
acknowledged wake IDs, and accepted bridge dispatch metadata, but never the raw
owner token. `arm_codex_feedback_wake` passes that capability to a detached
one-response bridge over an anonymous pipe, then polls the pinned device locally.
An eligible reply resumes the exact `requester_id` through a repo-local Codex
app-server Unix socket. The bridge records dispatch without acknowledging the
wake; the resumed agent acknowledges only after collection succeeds. Use
`DeveloperTools/connect-feedback-codex.sh <thread-id>` to attach the CLI when the
desktop app does not reflect externally resumed turns.

The bridge must be armed only at the yield boundary, after active waiting ends.
Do not arm it at thread creation: the standalone CLI app-server cannot observe a
desktop-owned in-progress turn and could otherwise race it. A scheduled task
heartbeat is now an emergency fallback only when bridge arming fails.
Advance only after the previous response is understood and recorded. Pause the
human interaction on ambiguity, the first failure, an unmet precondition, human
confusion, or device/host state divergence. For an authorized in-scope product
defect, block the visible session, fix and mechanically verify it, then resume
that same session; do not mutate the session to conceal divergence.

## Feedback model

| Kind | Required on device | Optional |
|---|---|---|
| `pen-fixture` | One Apple Pencil stroke | Free-text `humanNotes` entered before drawing |
| `review` | Verdict: `looks-good` / `needs-work` / `blocked` | Free-text `humanNotes` |

Text is never required. Collected payloads include `status`, `verdict`, `humanNotes`, `fixtureName` / fixture JSON, and the `pen-fixtures/index.json` entry.

## Queue and ownership

Requests share a stable FIFO queue across MCP processes. The first enqueue into
an idle queue launches TuberNotes; later enqueues are copied to the same pinned
device and the running app advances automatically after each terminal result.

Every new request returns an `owner_token`. Keep it with that agent's request ID
and pass it to collect, await, or cancel. Only a SHA-256 hash is persisted; a
different agent's token is rejected. Records created by the pre-queue tools have
no owner and remain collectable by request ID alone. `requester_id` is retained
in the completed request and index so results can be routed to the correct agent.

Run `DeveloperTools/device-preflight.sh --device <device-id>` before using the
server. It writes the repo-local gitignored physical-device session consumed by
the verifier, reset command, and every MCP device operation. The delivery target
is copied from that session and stored with each request. Polling never switches
targets. A record pinned to any other target is reported as device/host
divergence and must not be reconciled by changing its visible session.

## On-device layout

```text
Documents/
  agent-requests/
    pending/<id>.json
    completed/<id>.json
  pen-fixtures/
    <name>.json
    index.json
```

Mac-side mirror (gitignored): `.pencil-fixtures/requests/`, `.pencil-fixtures/collected/`.

Feedback-thread device storage is under
`Documents/feedback-threads/`; its gitignored Mac mirror is
`.feedback-threads/`, including `threads/`, `collected/`, `attachments/`, the
FIFO `queue.json`, and append-only `event-log.jsonl`.
Device-originated events carry unique IDs and source sequences. Collection
preserves the pulled device JSONL and deduplicates its events into the canonical
Mac event log.

Reviewed fixtures can be copied into `Fixtures/` for the repo.

## Reset stale feedback state

When abandoned Debug review questions are still visible, reset the feedback
protocol from the repo root with an explicit physical-device target:

```sh
DeveloperTools/reset-feedback-state.sh --confirm
```

The confirmation is mandatory. The script resolves the pinned device session,
then verifies that
`com.tubernotes.app` is installed, clears only the repo-local
`.feedback-threads` host mirror, launches the app once with
`TUBER_RESET_FEEDBACK_STATE=1`, and immediately relaunches it normally. The app
is not uninstalled and product data such as notebooks, PDFs, ink, Pins, and
Pencil fixtures is not removed. Run this between guided journeys, because all
feedback threads, drafts, queue entries, watches, collected feedback
attachments, and exports are intentionally lost.

## Legacy one-shot / Pencil human path

1. Agent calls `request_pen_fixture`, or the compatibility-only `request_human_review`.
2. App opens on the connected test device with the prompt at the top.
3. Human draws once and/or chooses a verdict (optional note).
4. Agent calls `await_interaction` / `collect_interaction` and records results in the evidence packet.

No environment-variable fiddling or container browsing is required of the human.

## Install

```sh
cd DeveloperTools/PencilFixtureMCP
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

Register `pencil-fixture-mcp` as a stdio MCP server. Connect, unlock, trust, and
enable the target physical iPad before invoking a device tool. Device tools fail
closed when it is unavailable; there is no simulator fallback.
