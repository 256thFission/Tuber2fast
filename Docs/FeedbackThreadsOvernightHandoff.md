# Handoff — Feedback Threads Overnight Implementation

Model-independent handoff for an autonomous overnight agent implementing the Debug human-review harness.

## Objective and status

- Objective: Replace the transactional review request/banner with the complete accepted v0.2 feedback-thread protocol: queued conversational review, model follow-up questions, human-triggered annotated viewport screenshots, single-choice questions, one live A/B comparison seam, and evidence export.
- Status: ready to start.
- Source specification: [`Docs/FeedbackThreadsSpec.md`](FeedbackThreadsSpec.md).
- Required first action: revise the source specification to the accepted v0.2 middle-ground described below, then implement against that narrower contract.
- Overnight execution: keep working autonomously and asynchronously for the full available window. Finish milestones in dependency order, but do not stop the overall run because one optional verification path fails while independent implementation or verification work remains.
- Morning outcome: Phillip should find a built, installed, mechanically verified Debug app plus a concise checklist of every physical-iPad behavior he still needs to test.

## Authority

The agent has full implementation autonomy inside the named Debug tooling and App composition scope, using an isolated git worktree. This includes:

- adding and changing Debug-only feedback-thread models, persistence, UI, and MCP operations;
- replacing the current review-request UI and queue behavior;
- adding focused tests and deterministic development fixtures;
- building, installing, and launching Debug TuberNotes on the connected physical iPad;
- creating gitignored logs and verification artifacts;
- making narrow App composition changes needed to host the harness;
- updating the feedback-thread specification and developer documentation to match the implemented behavior.
- creating and using a `codex/feedback-threads-overnight` branch and isolated worktree;
- integrating the existing scoped review-harness work into that worktree without disturbing the dirty primary checkout.

Full autonomy does not override repository security or architecture boundaries. Stop before:

- changing frozen `App/Contracts`;
- changing module ownership or product runtime contracts;
- bypassing iOS permissions or screenshot consent;
- introducing arbitrary model-authored executable UI;
- changing Release behavior;
- making irreversible external writes;
- modifying `.cursor/`, `SPEC.md`, or product Pin design;
- overwriting or reverting unrelated dirty work.

If a shared-contract or architecture change appears necessary, leave a concrete proposal in the work log and continue with the narrowest implementation that avoids it. Stop only if no useful in-scope path remains.

## Accepted v0.2 decisions

Incorporate these decisions into `Docs/FeedbackThreadsSpec.md` before implementation:

1. Treat this as a persistent review-session protocol, not a project-management product.
2. Only one feedback thread is active on the iPad. Others wait FIFO.
3. Use lifecycle states:
   - `queued`: waiting behind the active review;
   - `open`: awaiting human interaction;
   - `awaiting-model`: human replied and the thread retains the device slot while the model works;
   - `blocked`: a genuine external blocker; the next queued thread may advance;
   - `resolved`: terminal and immutable until explicitly reopened;
   - `cancelled`: terminal and abandoned.
4. Both the human and model may resolve a thread. Use optimistic concurrency so a model cannot resolve across an unseen newer human message. Record actor and last-consumed sequence.
5. Use two UI modes:
   - a minimal floating/draggable/collapsible bar over the product;
   - a full-screen thread view for history, composer, annotations, and resolution.
6. Do not build a rich intermediate expanded overlay.
7. During live A/B review only, the minimal product-facing bar exposes `[A] [B] [Reset]` so the human can switch while interacting with the product.
8. Initial MCP surface should be small and explicit:
   - `create_feedback_thread`;
   - `post_thread_message`;
   - `ask_thread_question`;
   - `await_thread_response`;
   - `collect_thread_updates`;
   - `set_feedback_thread_state`;
   - `get_feedback_thread`.
9. Keep existing `owner_token`, hashed ownership, `requester_id`, pinned target, FIFO, and idempotency behavior.
10. Feedback-thread names must not use bare `thread` where it could collide with product Pin `threadID` terminology.
11. Pen fixtures remain a separate protocol and corpus. Do not absorb `request_pen_fixture` into feedback threads.
12. M1 questions are free-text. M3 adds single-choice with optional comment and attachment. Defer multi-choice and Pencil capture as feedback-thread interaction types.
13. Screenshot capture is always triggered by the human. The model may ask for one but cannot trigger it.
14. Before sending a screenshot, the human must receive a preview and may annotate it with Apple Pencil, caption it, cancel it, or explicitly send it.
15. M2 persists and collects clean and annotated PNGs. Defer Photos import, custom media-library behavior, editable drawing archives, deletion UX, and elaborate retake flows.
16. Revision metadata is carried on a normal message/surface directive: summary, build ID, scenario, surface revision, and reset policy. Do not build a mini CI system.
17. Store durable device-side thread JSON, a gitignored Mac mirror, and append-only JSONL events. Defer search, archive UI, storage dashboards, and general export UI.
18. Live A/B is one narrow Debug registry seam, not a generalized variant platform. The first comparison uses two compiled live variants, identical viewport geometry, switch-in-place, synchronized reset, `[A] [B] [Reset]`, and logged preference.
19. Worktrees may be used to author alternatives, but runtime comparison comes from one manually integrated build containing A and B. Do not automate worktree merging.
20. Agent behavior: prefer one focused clarification before revising. Ask another only if the previous answer exposes a materially different ambiguity. Do not create question loops.

## Milestones

### M1 — Conversational durable feedback threads

- Persistent feedback-thread and append-only message models.
- Single-active FIFO queue with `awaiting-model` retention.
- Ownership, pinned target, idempotency, and optimistic state transitions.
- Minimal product overlay that does not alter geometry.
- Full-screen thread history and free-text composer.
- Human `Reply`, `Resolve`, and `Blocked` actions.
- Model follow-up text questions in the same thread.
- Seven bounded MCP operations listed above.
- Device persistence, Mac mirror, cursor-based collection, and JSONL event log.
- Relaunch restoration.
- Correct clean scenario transition when a terminal/blocked thread advances the queue.
- Pen fixture behavior remains functional and separate.

### M2 — Human-triggered annotated screenshots

- `Capture & Annotate` is available only as an explicit human action.
- Capture excludes the feedback-thread UI and preserves the tested product viewport.
- The human sees a preview before sending.
- Apple Pencil annotation is supported on the frozen image.
- Optional one-line caption.
- Explicit `Send` and `Cancel`.
- Persist clean and annotated PNGs with dimensions, orientation, scenario, surface revision, thread ID, and message ID.
- Append the sent attachment to the feedback thread.
- MCP collection returns durable Mac-side paths the model can inspect.
- A cancelled or failed capture creates no sent attachment or successful message.

### M3 — Single-choice questions

- Model posts free-text or single-choice questions.
- Single-choice supports one answer, optional comment, and optional human-triggered annotated screenshot.
- Completed questions are read-only.
- Answers are append-only messages and idempotent.

### M4 — One live A/B seam

- One Debug-only registered comparison, preferably a small Pin presentation or another existing bounded surface that does not require product-contract changes.
- Options A and B are compiled into one build.
- Switching happens instantly without relaunching.
- Both variants receive identical container geometry and deterministic starting fixtures.
- V1 uses synchronized reset only.
- Product-facing bar exposes `[A] [B] [Reset]`.
- Full thread view collects `Prefer A`, `Prefer B`, `Neither`, or `No preference`, plus optional comment/annotation.
- Event log records variant exposure, switching, reset, and preference.

### M5 — Evidence export and operational finish

- Add one bounded `export_feedback_thread` operation or equivalent export flag that writes Markdown plus attachment paths into an evidence directory.
- Document the implemented MCP workflow.
- Ensure relaunch restoration, queue recovery, and event logging are mechanically covered.
- Keep Photos import, search, archive UI, storage dashboards, and generalized cleanup UI deferred.

Do not expand into Level 2/3 generalized component or architectural variants. Complete the one live comparison seam and move on to remaining verification and reliability work.

## Files and subsystem scope

Expected primary scope:

- `TuberNotes/DeveloperSupport/`
- `DeveloperTools/PencilFixtureMCP/`
- focused queue, persistence, state-transition, MCP, screenshot-metadata, and source/UI contract tests under `DeveloperTools/PencilFixtureMCP/tests/`
- minimal harness composition in `TuberNotes/App/RootView.swift`
- `Docs/FeedbackThreadsSpec.md`
- `Docs/Development.md` and MCP README only where operational instructions materially change
- Xcode project membership only for new source files

Likely implementation files may include new Debug-only types such as:

- `FeedbackThread.swift`
- `FeedbackThreadStore.swift`
- `FeedbackThreadSession.swift`
- `FeedbackThreadBar.swift`
- `FeedbackThreadView.swift`
- `FeedbackAnnotationView.swift`

Names are suggestions, not requirements. Prefer the smallest coherent set.

Files already dirty belong to ongoing work. Inspect `git status` and the scoped diff before editing. Preserve unrelated changes and do not normalize or reformat adjacent systems.

## Non-goals

- Release/product chat functionality.
- A mini issue tracker.
- Search, archive UI, storage dashboards, notification systems, or general media management.
- Photos import during the required milestones.
- Editable Pencil annotation archives beyond what is necessary to produce the annotated PNG.
- Arbitrary model-supplied UI or hot-loaded Swift.
- Generalized variant frameworks or automated worktree merges.
- Product Pin redesign.
- Changes to frozen contracts.
- Large new test suites unrelated to the feedback-thread state machine.

## Worktree setup

Do not implement in the dirty primary checkout.

1. Record the primary checkout path, current branch/HEAD, `git status --short`, and scoped diffs.
2. Create an isolated worktree on branch `codex/feedback-threads-overnight` in a sibling or `tmp/` location that will not overlap build artifacts.
3. Because the primary checkout contains relevant uncommitted harness work and untracked specification files, transplant only the required scoped starting state into the worktree:
   - current `DeveloperSupport` review-harness changes;
   - current minimal `RootView` harness placement;
   - current focused MCP queue tests and server changes required by the harness;
   - `Docs/FeedbackThreadsSpec.md`;
   - this handoff if useful for local reference.
4. Use a scoped patch or careful file copy for untracked documentation. Do not copy `.cursor/`, unrelated M0 changes, build products, collected fixtures, or arbitrary dirty-tree state.
5. Confirm the worktree starts with only intentional feedback-harness changes before implementing.
6. Keep all implementation, tests, logs, builds, and commits inside the worktree.
7. Commit coherent milestones on the worktree branch as progress is proven. Do not push or open a PR unless separately requested.

## Canonical overnight workflow

1. Read completely:
   - `AGENTS.md`;
   - `.codex/skills/xcode-loop/SKILL.md`;
   - `.codex/skills/visual-verification/SKILL.md`;
   - `.codex/skills/human-device-loop/SKILL.md`;
   - `Docs/Development.md` human-device and physical-device sections;
   - `Docs/FeedbackThreadsSpec.md`;
   - this handoff.
2. Set up and enter the isolated worktree, then record its initial scoped state.
3. Update the specification to the accepted v0.2 decisions.
4. Write a short implementation plan and acceptance matrix to the work log.
5. Implement M1 with focused tests; commit when mechanically proven.
6. Implement M2 with focused tests; commit when mechanically proven.
7. Implement M3 with focused tests; commit when mechanically proven.
8. Implement the single bounded M4 live A/B seam; commit when mechanically proven.
9. Implement M5 evidence export and operational documentation.
10. Build for the physical iPad after every user-visible milestone or coherent batch.
11. Install and launch only on Phillip's connected iPad. Do not launch Simulator.
12. Mechanically verify restoration, queue transitions, stale-control removal, geometry, attachment persistence, and variant switching wherever device tooling permits.
13. Do not fabricate human screenshot consent, Pencil annotation quality, visual taste, or A/B preference. Add each human-only judgment to the morning checklist and continue.
14. When a verification path fails twice without a narrower fix, preserve its evidence and stop that path as required by the repo guide, then continue all independent milestones and checks. Do not treat one exhausted path as a reason to end the overnight run.
15. Revisit deferred failures after later work only when new evidence provides a genuinely narrower fix.
16. Perform final scoped diff inspection and update both overnight artifacts.
17. Leave the latest build installed and positioned at the first morning test when feasible, but do not create, annotate, send, or approve a screenshot on Phillip's behalf.

## Async execution and communication

- Begin with an active goal for the complete overnight objective if the running Codex surface supports goals.
- Continue autonomously across long builds and verification loops.
- Use nonblocking polling and keep full logs in artifact files rather than model context.
- Do not stop merely because a build is slow or a human is unavailable overnight.
- Do not wait indefinitely for human interaction. Record the human-only step and continue with mechanical work.
- After two verification failures with no narrower fix, stop that verification path, preserve evidence, and continue independent implementation and verification work.
- Keep chugging until the time window ends or no safe in-scope work remains.
- At the end, mark the goal complete only if the accepted v0.2 implementation and required mechanical evidence are genuinely complete. Otherwise report exact milestone status without declaring success.

## Durable overnight artifacts

Create and maintain these gitignored artifacts from the start:

```text
tmp/feedback-threads-overnight/
  WORKLOG.md
  MORNING_TESTS.md
  build-device.log
  focused-tests.log
  artifacts/
```

### `WORKLOG.md`

Append concise timestamped entries containing:

- milestone and current hypothesis;
- files changed;
- test/build command and result;
- failure tail and narrow fix;
- scenario and device used;
- important architecture decisions;
- deferred or rejected scope;
- artifact paths;
- final scoped diff summary.

Do not paste full build logs into the work log.

### `MORNING_TESTS.md`

Maintain a checklist throughout the night. Each item must include:

- exact starting state;
- exact human action;
- expected visible result;
- what failure would look like;
- relevant thread/scenario/variant ID;
- where the resulting message or attachment should be collected.

At minimum include the morning checks listed below.

## Required morning physical-iPad checklist

### Conversational thread

- Open the installed app in landscape.
- Confirm the minimal floating bar does not resize or refit the product viewport.
- Open the full thread view and return; confirm the product surface did not reset.
- Send a free-text reply and keep the feedback thread open.
- Confirm the reply becomes read-only and no duplicate composer or stale prompt appears.
- Let the model post one follow-up question in the same feedback thread.
- Answer it and confirm history order is correct.
- Relaunch the app and confirm the feedback thread and history restore.

### Queue and state

- Queue two feedback threads with different scenarios.
- Reply to the first and confirm `awaiting-model` retains the active slot.
- Mark the first genuinely `blocked` or resolve it.
- Confirm the second advances FIFO and loads its correct clean scenario.
- Confirm no stale Reset-only prompt appears.
- If the model resolves a feedback thread, post a newer human message during a stale-resolution test and confirm optimistic concurrency rejects the stale resolve.
- Reopen a resolved feedback thread and confirm it becomes mutable only after reopening.

### Annotated screenshot

- From a spatial scenario, tap `Capture & Annotate` yourself.
- Confirm capture does not occur before the tap.
- Confirm the frozen image excludes the feedback-thread UI.
- Draw a clear Pencil circle and arrow.
- Add an optional caption.
- Cancel once and confirm nothing is sent or collected.
- Repeat, tap `Send`, and confirm both clean and annotated previews appear in history.
- Confirm the model receives durable Mac-side paths and can inspect the annotated PNG.
- Confirm the stored image dimensions/orientation match the physical iPad viewport.
- Confirm sending the image does not resolve the feedback thread.

### Live A/B, only if M4 was completed

- Open the registered comparison in landscape.
- Interact with A, switch to B, and confirm there is no app relaunch.
- Confirm A and B use identical product viewport geometry.
- Confirm each switch performs the specified synchronized reset.
- Confirm `[A] [B] [Reset]` remains available over the product without resizing it.
- Submit a preference with a comment and optional annotated screenshot.
- Confirm the event log records both variants being shown and the final preference.

### Human-only quality

- Judge Pencil annotation latency and feel.
- Judge whether the minimal bar is draggable without stealing product gestures.
- Judge full-screen transition quality.
- Judge whether the history is readable without feeling like an issue tracker.
- Note any clipping, keyboard obstruction, orientation bug, or accidental product reset.

## Mechanical acceptance evidence

Required for M1:

- focused tests cover FIFO, one-active enforcement, `awaiting-model`, blocked advancement, optimistic resolution, idempotent message append, cursor collection, relaunch restoration, and differing-scenario advancement;
- MCP operations are exercised end-to-end against isolated stores;
- physical-device Debug build succeeds;
- app installs and launches on Phillip's connected iPad;
- no Simulator was launched;
- final diff remains inside named ownership boundaries.

Required for M2:

- focused tests cover attachment metadata, atomic message/attachment persistence, cancellation/failure behavior, and Mac-side collection paths;
- physical-device Debug build succeeds after annotation implementation;
- capture can only be initiated through a human UI action;
- capture code excludes the harness overlay by construction;
- no claim is made about Pencil feel or final visual quality without Phillip's morning review.

M3–M5 acceptance:

- M3 single-choice answers are append-only, read-only after completion, and idempotent;
- M4 switches two live compiled variants without relaunch, preserves identical geometry, synchronously resets, and logs preference.
- M5 exports a readable Markdown history with durable attachment paths and documents the final MCP workflow.

## Stop conditions

Stop the entire overnight run only when one of these applies:

- all accepted v0.2 milestones and mechanical acceptance evidence are complete;
- a frozen shared contract or architecture change is genuinely required;
- the next action would bypass an OS permission or screenshot-consent boundary;
- unrelated dirty changes prevent a safe scoped edit;
- the overnight time window ends;
- no safe in-scope implementation, test, documentation, logging, or verification work remains.

A repeated failure stops that specific verification path, not the entire run, while independent work remains. Do not broaden scope to compensate for a failure.

## Final evidence packet

Before stopping, produce a compact packet containing:

- objective and milestone status;
- changed files;
- scoped diff summary and unrelated-dirty-work confirmation;
- focused test totals and log path;
- physical-device build/install/launch results and exact destination;
- scenarios and expected states exercised;
- screenshot or attachment artifact paths created mechanically, if any;
- console and crash status;
- mechanical checks completed;
- human-only checks remaining;
- `WORKLOG.md` and `MORNING_TESTS.md` paths;
- unresolved issues and exact stop reason.

## Next bounded action

- Read the required instructions and inspect the dirty primary checkout.
- Create and enter the `codex/feedback-threads-overnight` worktree.
- Transplant only the intentional scoped starting changes.
- Create `tmp/feedback-threads-overnight/WORKLOG.md` and `MORNING_TESTS.md` inside the worktree.
- Patch `Docs/FeedbackThreadsSpec.md` to v0.2.
- Implement M1 through M5 in dependency order, continuously testing, committing, and logging without waiting for morning human interaction.
