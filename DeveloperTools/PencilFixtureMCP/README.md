# PencilFixtureMCP

Development tooling only — not the in-product AI agent.

Pushes agent interaction requests into the **Debug** TuberNotes app on a connected simulator or physical iPad. The human sees the agent prompt in an in-app banner, completes the request on device, and the app indexes the result under Documents. Agents collect durable JSON; the human does no Mac-side file copying.

Canonical docs: `Docs/Development.md` § Human device loop, Skill `human-device-loop`, evidence fields in `Docs/templates/EvidencePacket.md`.

## Tools

| Tool | Purpose |
|---|---|
| `request_pen_fixture(description, scenario?, prefer_device?, requester_id?, stale_after_seconds?)` | Enqueue a Pencil capture request; launch only when the queue was idle |
| `request_human_review(prompt, title?, scenario?, prefer_device?, requester_id?, stale_after_seconds?)` | Enqueue a review request for looks-good / needs-work / blocked |
| `await_interaction(request_id, timeout_seconds?, prefer_device?, owner_token?)` | Poll until the human finishes; return fixture/verdict/index |
| `collect_interaction(request_id, prefer_device?, owner_token?)` | One-shot pull of completed artifacts |
| `cancel_interaction(request_id, owner_token?, reason?, prefer_device?)` | Safely cancel an owned pending or stale request |
| `list_interactions()` | On-device index + local request catalog |
| `list_pen_fixtures()` / `get_pen_fixture(name)` | Read fixtures |
| `replay_pen_fixture(name)` | Install fixture and relaunch replay seam |

Feedback threads are a separate protocol and store. They do not replace Pencil
fixture capture or change its corpus.

| Feedback-thread tool | Purpose |
|---|---|
| `create_feedback_thread(...)` | Create an owned thread, pin its target, and enter the single-active FIFO |
| `post_thread_message(...)` | Append an idempotent model message |
| `ask_thread_question(...)` | Append a free-text or single-choice question |
| `await_thread_response(...)` | Wait from an exclusive message-sequence cursor for a human response |
| `collect_thread_updates(...)` | Mirror new messages and sent screenshot files to durable Mac paths |
| `set_feedback_thread_state(...)` | Optimistically transition lifecycle state and advance FIFO when appropriate |
| `get_feedback_thread(...)` | Read the durable snapshot and append-only history |
| `export_feedback_thread(...)` | Write an evidence-oriented Markdown transcript and attachment path list |

Every mutating model operation uses an `idempotency_key`. State changes also
require `expected_last_sequence` and `last_consumed_sequence`; stale resolution
is rejected so the model cannot resolve across an unseen human reply. Keep the
`owner_token` returned by creation. Only its SHA-256 hash is persisted.

A normal loop is:

```text
create_feedback_thread
collect_thread_updates / await_thread_response
ask_thread_question or post_thread_message
collect_thread_updates / await_thread_response
set_feedback_thread_state
export_feedback_thread
```

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

The delivery target is selected once and stored with the request. Polling never
switches a request from its original iPad or simulator to another target.

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

Reviewed fixtures can be copied into `Fixtures/` for the repo.

## Human path

1. Agent calls `request_pen_fixture` or `request_human_review`.
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

Register `pencil-fixture-mcp` as a stdio MCP server. Prefer a physical iPad when available; the tools fall back to the booted simulator.
