# Feedback Threads — Human Review Harness Specification

Status: Accepted v0.2 for implementation  
Scope: Debug-only `DeveloperSupport`, `DeveloperTools/PencilFixtureMCP`, and narrow App composition  
Primary user: Human reviewer using Phillip's physical iPad  
Primary client: Development model coordinating work through MCP

## 1. Objective

Replace the transactional review request/banner with a persistent review-session protocol. A feedback thread is the durable unit for a model review request, human replies, focused follow-up questions, human-triggered annotated viewport screenshots, implementation revision metadata, one bounded live A/B comparison, and final resolution.

This is development tooling, not product chat or project-management software. It remains absent from Release behavior. The existing pen-fixture protocol and corpus remain separate.

## 2. Accepted principles

- Feedback is conversational rather than verdict-first.
- Exactly one feedback thread owns the iPad review slot. Other feedback threads wait FIFO.
- A human reply does not resolve the thread. It moves the thread to `awaiting-model`, which retains the device slot.
- Both human and model may resolve, subject to optimistic concurrency.
- Resolved threads are terminal and immutable; they cannot be reopened.
- The floating harness preserves the prior quick context interaction: collapsed bar, bounded expanded current-turn card, and a full-screen thread view for complete history.
- Human composer drafts are session-owned per feedback thread and persist across focus or presentation changes until successful submission.
- The model may ask for a screenshot but cannot trigger one. Capture, attachment drafting, and final message send are separate, explicit human actions.
- The initial structured interaction is single-choice only. Multi-choice and Pencil capture as feedback-thread interactions are deferred.
- A/B review is one compiled, Debug-only comparison seam with synchronized reset, not a generalized variant platform.
- Messages, answers, attachments, and events are append-only and idempotent.
- The review UI floats above the product and never changes its viewport geometry.
- Names use `feedbackThreadID` or another explicit feedback-thread term where bare `threadID` could be confused with product Pin terminology.

## 3. Lifecycle and queue

A feedback thread has one lifecycle state:

```text
queued
open
awaiting-model
blocked
resolved
cancelled
```

Only one feedback thread may be `open` or `awaiting-model`. That thread owns the active device slot. All other nonterminal threads are `queued`.

The iPad is the sole queue-activation authority. Host tools create and requeue
threads as `queued`, mirror device snapshots, and may request terminal state
changes, but they never promote a thread to `open`. This prevents host and
device queue coordinators from independently claiming the same slot.

```mermaid
stateDiagram-v2
    [*] --> Queued
    Queued --> Open: reaches FIFO head
    Queued --> Cancelled: abandoned
    Open --> AwaitingModel: human replies or answers
    AwaitingModel --> Open: model posts next prompt or revision
    Open --> Blocked: genuine external blocker
    AwaitingModel --> Blocked: genuine external blocker
    Open --> Resolved: human or model resolves
    AwaitingModel --> Resolved: human or model resolves
    Open --> Cancelled: abandoned
    AwaitingModel --> Cancelled: abandoned
    Blocked --> Queued: explicitly resumed
```

When the active feedback thread becomes `blocked`, `resolved`, or `cancelled`, the device advances the next queued thread and loads its pinned scenario cleanly. A blocked thread does not retain the device slot. Resuming a blocked thread joins the queue and the device opens it only when the slot is idle. Resolved and cancelled threads never re-enter the queue. Message history and per-thread sequences are preserved.

### Optimistic concurrency

Every append receives a monotonic sequence number. A state-changing model call includes the last human/message sequence it consumed. A model resolve is rejected if a newer message exists. State changes record:

- actor (`human`, `model`, or `system`);
- last-consumed sequence;
- resulting sequence and timestamp;
- idempotency key.

This prevents a model from resolving across unseen newer human feedback. Repeating an accepted operation with the same idempotency key returns the original result rather than appending again. Duplicate create is stricter: it also requires the original owner token.

## 4. Ownership, delivery, and identity

Keep the existing queue guarantees:

- `owner_token` is returned only on the first successful create;
- only its SHA-256 hash is persisted;
- owned mutation, await, collection, and state calls require the matching token;
- a duplicate `create_feedback_thread` must present the original `owner_token`; it returns the original record without minting or revealing another token;
- `requester_id` remains in durable records and collected output;
- the delivery target is pinned at creation and polling never changes it;
- enqueue order is stable across MCP processes;
- thread and message creation are idempotent.

Owner tokens must never appear in device records, Mac mirrors, event logs, or exported evidence.

## 5. Core conversational workflow

1. The model creates a feedback thread with title, objective, initial message, pinned scenario, and an idempotency key.
2. The thread opens immediately when the review slot is idle; otherwise it is queued FIFO.
3. Activation loads the thread's deterministic scenario with a clean reset.
4. The minimal bar appears without resizing or refitting the product.
5. The human opens the full thread view and replies, answers a question, captures an annotation, blocks, or resolves.
6. A human reply is appended and moves the thread to `awaiting-model` while retaining the active slot.
7. The model collects the update and normally asks no more than one focused clarification before revising. It asks another only if the answer exposes a materially different ambiguity.
8. The model posts a question or revision, returning the thread to `open`, or performs an optimistic state transition.
9. Terminal or blocked state advances the next queued thread and removes stale controls immediately.

Text follow-ups preserve the current product surface unless their normal message carries an explicit surface directive.

## 6. User interface

### 6.1 Minimal product-facing bar

The floating bar starts at the top-trailing safe-area edge every time, and remains draggable and collapsible. Collapsed, it shows compact session information. Expanded, it preserves the quick context UI: the exact current model turn, its immediate reply or single-choice control, high-contrast state actions, and `View Full Thread`. A compact forward arrow yields the current thread to the next queued review without resolving it. The UI does not browse or reopen older history and does not participate in product layout.

During the registered live A/B comparison only, it additionally exposes:

```text
[A] [B] [Reset]
```

The expanded current-turn card is intentionally bounded; complete history, attachment review, comments, and longer interaction remain in the full-screen view.

### 6.2 Full-screen thread view

The full-screen view contains:

- complete chronological, append-only history;
- the current free-text composer or single-choice question;
- the annotated screenshot as the primary history preview, with clean-image retention indicated as metadata;
- implementation and surface revision markers;
- human actions for `Reply`, `Capture & Annotate`, `Blocked`, and `Resolve`;
- live A/B preference controls when the registered comparison is active.

Leaving the view returns to the same product surface without resetting it. Submitted replies and completed questions become read-only. Only the newest unanswered interaction is editable. No duplicate composer or stale Reset-only prompt may remain after submission or queue advancement.

Reply text, selected choices, and optional comments are keyed by feedback-thread ID in the long-lived feedback session. Opening or dismissing the full-screen view, moving focus, or presenting capture/annotation does not clear them. Successful submission clears only the submitted thread's draft; a failed submission preserves it. Draft state never transfers to another queued thread.

Human-facing model copy is optimized for quick review on the iPad:

- Keep titles and objectives brief.
- Use short `-` bullets when a prompt or follow-up contains multiple checks.
- Put one requested check or action in each bullet.
- Avoid dense paragraphs and repeated context.

## 7. Questions

M1 supports free-text questions. M3 adds single-choice questions with:

- one selected option;
- optional comment;
- optional human-triggered annotated screenshot.

The answer is an append-only message and uses an idempotency key. After completion, both question and answer are read-only. Answering leaves the thread in `awaiting-model`; it does not resolve or reset the scenario.

Multi-choice and Pencil capture requests are not feedback-thread interaction types in v0.2. Authentic Pencil fixture capture continues through `request_pen_fixture` and its existing corpus.

## 8. Human-triggered annotated screenshots

### 8.1 Consent boundary

The model may request visual clarification in a normal message. It cannot invoke capture. Only the human can tap `Capture & Annotate`, preview the result, and explicitly send it.

### 8.2 Flow

1. The human taps `Capture & Annotate` in the full-screen thread view.
2. The harness captures the TuberNotes product viewport while excluding all feedback-thread UI.
3. A frozen preview opens.
4. The human may draw with Apple Pencil using the native PencilKit tool picker, cancel, or attach the result as an unsent composer draft.
5. The reply composer previews the draft and lets the human add optional text or remove the attachment.
6. `Cancel` and `Remove Attachment` create no sent attachment and no successful attachment message.
7. The reply composer's `Send Reply` atomically persists the clean and annotated images, attachment metadata, optional text, and their single owning message.
8. The MCP collection path mirrors both PNGs to durable model-accessible paths.

M2 persists:

- clean PNG;
- composited annotated PNG;
- pixel dimensions and orientation;
- scenario;
- surface revision;
- feedback-thread ID and owning message ID;
- capture and send timestamps;
- optional message text on the owning reply.

Photos import, custom media-library behavior, editable drawing archives, deletion UX, and elaborate retake flows are deferred. Captures from other apps or system UI are prohibited.

## 9. Revisions and surface directives

Thread state and product-surface state are separate. A normal message may carry bounded revision metadata:

```json
{
  "summary": "Adjusted the Pin callout anchor.",
  "buildID": "debug-2026-07-16-01",
  "scenario": "pin-drift",
  "surfaceRevision": 2,
  "resetPolicy": "clean"
}
```

Reset policy is one of:

- `preserve`: keep the current product surface; default for follow-ups;
- `clean`: reload the named deterministic scenario;
- `new-revision`: rebuild the surface only when the revision changes.

Advancing to a different feedback thread always loads that thread's pinned scenario cleanly. Revision metadata is evidence carried on a message, not a CI, deployment, or build-management subsystem.

## 10. One bounded live A/B seam

M4 registers one Debug-only live comparison, preferably a small existing Pin presentation surface that requires no product-contract change.

- A and B are compiled into one manually integrated build.
- Both render switch-in-place in the identical product viewport geometry.
- Switching does not reinstall or relaunch the app.
- Every switch and `[Reset]` applies the same deterministic synchronized reset and briefly shows `Resetting` before accepting more comparison input.
- The minimal bar exposes `[A] [B] [Reset]` only while comparison is active.
- The full thread view offers `Prefer A`, `Prefer B`, `Neither`, and `No preference`, with optional comment and human-triggered annotation.
- The event log records each variant exposure, switch, reset, and submitted preference.
- Unknown comparison and variant identifiers fail visibly and safely.

This is one explicit registry seam, not a reusable variant framework. Independent per-variant state, side-by-side comparison, generalized component/architecture variants, arbitrary model-authored UI, hot-loaded Swift, and automated worktree merging are out of scope. Worktrees may be used for authoring, but runtime review uses the one integrated binary.

## 11. Data contract

Names below are illustrative; stored keys must avoid collision with product Pin `threadID` terminology.

```swift
struct FeedbackThreadRecord {
    var feedbackThreadID: String
    var title: String
    var objective: String
    var state: FeedbackThreadState
    var requesterID: String
    var target: DeliveryTarget
    var scenario: String
    var surfaceRevision: Int
    var lastSequence: Int
    var lastConsumedSequence: Int?
    var createdAt: Date
    var updatedAt: Date
}

struct FeedbackThreadMessage {
    var messageID: String
    var feedbackThreadID: String
    var sequence: Int
    var author: Author
    var body: String?
    var interaction: Interaction?
    var attachmentIDs: [String]
    var surfaceDirective: SurfaceDirective?
    var createdAt: Date
    var idempotencyKey: String
}
```

Authors are `model`, `human`, and `system`. Messages, answers, attachments, and state events are append-only. A resolved record is immutable and cannot be reopened.

## 12. MCP surface

The conversational core has seven feedback-thread operations:

1. `create_feedback_thread` — create idempotently, pin target/scenario, and enqueue for device activation.
2. `post_thread_message` — append a normal model message, optionally carrying bounded revision/surface metadata.
3. `ask_thread_question` — append a free-text or single-choice question.
4. `await_thread_response` — bounded poll for a newer human response without changing delivery target.
5. `collect_thread_updates` — return messages and attachment paths after a sequence cursor.
6. `set_feedback_thread_state` — perform authorized optimistic transitions, including block, resolve, cancel, and blocked-thread resume.
7. `get_feedback_thread` — retrieve the durable record, ordered history, active state, and queue position.

Operational recovery, evidence, and automatic wake add five bounded operations:

8. `cancel_feedback_thread` — idempotently cancel an owned or explicitly confirmed orphaned development session.
9. `export_feedback_thread` — write one thread's readable Markdown history and paths for attachments already collected to the Mac mirror into an evidence directory, then return those paths.
10. `get_feedback_watch_state` — return unseen human/terminal wake eligibility for a task heartbeat.
11. `acknowledge_feedback_wake` — idempotently record a delivered wake and monotonically advance its cursor.
12. `close_feedback_watch` — stop host monitoring without mutating thread lifecycle or queue state.

No separate list, queue-advance, attachment-delete, attachment-collection, comparison-post, resolve, or reopen operation is part of v0.2. Attachments arrive through messages and are returned by cursor collection. Queue advancement is state-machine behavior. Comparison and revision directives travel on normal messages.

Collection uses an exclusive `afterSequence` cursor so polling never duplicates messages. Await has a finite caller-selected timeout and is safe to repeat. All mutating operations accept idempotency keys; owned calls enforce `owner_token`.

## 13. Durable storage and export

Device-side canonical storage:

```text
Documents/
  feedback-threads/
    queue.json
    events.jsonl
    <feedback-thread-id>/
      thread.json
      messages/
        000001.json
        000002.json
      attachments/
        <attachment-id>-clean.png
        <attachment-id>-annotated.png
```

Gitignored Mac mirror:

```text
.feedback-threads/
  queue.json
  event-log.jsonl
  threads/<feedback-thread-id>/
    thread.json
    messages/*.json
  collected/<feedback-thread-id>/
    device/...
    evidence/feedback-thread.md
  attachments/<feedback-thread-id>/*.png
  watches/<feedback-thread-id>.json
```

Collected attachment paths are added to the owning message's attachment metadata as `collectedPaths`; they are not maintained in a separate attachment index. The per-thread `collected/.../device` directory is the raw pull, while durable PNG copies live under `attachments/<feedback-thread-id>/`.

Every meaningful event is appended to a mergeable JSONL schema with a globally unique event ID, source (`backend` or `device`), per-source sequence, feedback-thread ID, timestamp, requester ID, pinned target, scenario, surface revision, and relevant message/attachment/comparison fields. Collection deduplicates device events by event ID into the canonical Mac event log while preserving the pulled device log as an evidence artifact. Required events cover creation, queueing, activation, message/question/answer, state transition, capture cancellation/send/collection, surface revision, variant exposure/switch/reset/preference, blocked-thread resume, and export.

`export_feedback_thread` writes a bounded Markdown transcript plus references only to durable attachments already collected into the Mac mirror. Export does not pull uncollected device attachments implicitly. It does not add a general export UI, archive browser, search index, or storage dashboard.

## 14. Reliability, security, and privacy

- Queue order is deterministic and exactly one feedback thread owns the review slot.
- `awaiting-model` retains the slot; `blocked`, `resolved`, and `cancelled` release it.
- Per-thread sequences are monotonic; append and answer operations are idempotent.
- Relaunch restores the active thread, queue, history, unread state, and current surface metadata.
- State transitions reject stale last-consumed sequences.
- Failed attachment writes create neither a successful message nor partial attachment metadata.
- The clean and annotated PNG paths returned to the model are durable Mac-side copies.
- Thread controls disappear immediately after terminal/blocked transition and cannot mutate resolved history.
- The feedback UI never changes canvas geometry.
- Screenshot capture and send each require explicit human action; capture excludes the harness UI.
- The system is Debug-only and does not bypass iOS permissions.
- Owner tokens are never persisted or exported in plaintext.
- Pen fixtures remain a separate protocol and corpus.

### 14.1 Automatic model wake

Creating a feedback thread also creates a gitignored watch record containing
the requester ID, monotonic acknowledgement cursor, and bounded acknowledged
wake-ID history. It does not contain the plaintext owner token.

The initiating Codex task arms a supported task heartbeat before ending its
turn. The heartbeat calls `get_feedback_watch_state`; human messages and
human terminal/blocked transitions produce a wake ID derived from feedback
thread identity, sequence, state, and revision. After the originating task is
resumed, `acknowledge_feedback_wake` records that ID and advances the cursor.
Repeated polls or acknowledgements are harmless. `close_feedback_watch` stops
monitoring without mutating the transcript or advancing the device queue.

PencilFixtureMCP remains passive and does not invoke undocumented Codex APIs.
If heartbeat registration fails, the initiating task must await immediately or
report `feedback-created-but-not-armed`.

### 14.2 Asynchronous Review Runs

A Review Run is an optional object embedded in one feedback thread. It contains
ordered human-autonomous steps with explicit prerequisite IDs and durable
states: `locked`, `ready`, `in-progress`, `passed`, `failed`, `skipped`, or
`blocked`. Failed, skipped, and blocked prerequisites block their dependents,
while unrelated ready steps remain actionable.

The device persists each explicit verdict, choice, comment, and annotation in
the run snapshot. These edits do not append transcript messages and therefore
do not wake the originating task. Once every step is terminal, `Finish Review`
atomically marks the run submitted and appends exactly one ordered human
summary message containing all attachment metadata. Submission is immutable
and produces the run's single feedback-watch wake. Collection advances the run
from `submitted` to `collected` idempotently without changing thread queue
ownership.

## 15. Milestones and acceptance

### M1 — Conversational durable feedback threads

- persistent records and append-only messages;
- FIFO queue with one active slot and `awaiting-model` retention;
- ownership, target pinning, idempotency, and optimistic transitions;
- minimal floating bar and full-screen free-text conversation;
- seven MCP operations;
- durable automatic-wake cursor operations and task-heartbeat workflow;
- device persistence, Mac mirror, cursor collection, JSONL events, and relaunch restoration;
- correct clean scenario load on queue advancement;
- existing pen-fixture behavior remains functional and separate.

### M2 — Human-triggered annotated screenshots

- capture only from a human action;
- harness UI excluded by construction;
- frozen preview with Pencil annotation, explicit Attach/Cancel, and a removable composer draft;
- one final reply send for optional text and the annotated screenshot together;
- atomic clean/annotated PNG persistence and durable Mac paths;
- cancelled/failed capture produces no sent attachment or successful message.

### M3 — Single-choice questions

- one answer with optional comment and annotation;
- append-only, read-only completion;
- idempotent answer submission.

### M4 — One live A/B seam

- two compiled live variants in one build;
- identical geometry, switch-in-place, synchronized reset;
- `[A] [B] [Reset]`, preference collection, and exposure/switch/reset/preference events.

### M5 — Evidence export and operational finish

- bounded `export_feedback_thread` writes Markdown and paths for already-collected attachments;
- relaunch, queue recovery, and event logging have focused mechanical coverage;
- implemented MCP workflow is documented.

The milestone is accepted mechanically only with focused state/persistence/MCP tests, a successful Debug device build/install/launch, deterministic scenario inspection, and a scoped final diff. Human consent, Pencil feel, interaction taste, and A/B preference remain morning checks and must not be fabricated.

## 16. Deferred and prohibited scope

Deferred from v0.2:

- a rich intermediate history browser beyond the bounded current-turn card;
- Photos import or general media management;
- editable drawing archives, attachment deletion UX, elaborate retake flows;
- multi-choice and feedback-thread Pencil-capture interactions;
- search, archive UI, storage dashboards, notifications, and generalized cleanup;
- generalized component or architectural variant platforms;
- independent A/B state, per-variant reset controls, side-by-side presentation;
- automated worktree integration or a mini CI/build system.

Prohibited:

- Release/product chat behavior;
- remote or automatic screenshot capture/send;
- capture of another app or system UI;
- arbitrary model-supplied executable UI or hot-loaded Swift;
- changes to frozen contracts, product Pin design, permissions, or module ownership.
