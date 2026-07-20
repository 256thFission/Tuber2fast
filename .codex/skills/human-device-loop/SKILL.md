---
name: human-device-loop
description: Facilitate guided or asynchronous human review, run isolated harness conformance checks on a connected TuberNotes test device, and collect durable evidence without exposing protocol internals.
---

# Human device loop

Use this for judgments or authentic Pencil input on the physical iPad pinned by `DeveloperTools/device-preflight.sh`. The tooling never chooses another target. Read `Docs/DeviceWorkflow.md`; protocol detail lives in `Docs/Development.md` § Human device loop and `DeveloperTools/PencilFixtureMCP/README.md`.

## Choose the mode

### Guided human review

Use one persistent visible feedback session for the whole review journey. The device is a human workspace, not a protocol console.

1. Before creating device state, publish a compact table in the Codex chat listing every planned visible review thread by human-readable label, pinned scenario, and checks covered. Do not include runtime IDs, owner tokens, cursors, or queue state, and do not show this table on the iPad.
2. Split each check privately into preconditions, one human action, mechanical assertions, and at most one human-only question. Verify preconditions before presenting the step.
3. Create one feedback thread with this Codex task ID as `requester_id`; retain its owner token and sequence cursor privately. Reuse this thread for every step in the journey.
4. Present only the current action and optional short question. A good prompt is: `C3 of 7: Send any short reply. Did anything prevent you from replying?`
5. Never expose thread/request IDs, tokens, cursors, lifecycle or queue states, expected results, artifact paths, test keys, waiter names, or verification instructions. Never combine an exact-answer instruction with a PASS/FAIL request.
6. Use `await_thread_response` while the initiating turn remains active. Before yielding without a reply, call `arm_codex_feedback_wake` with the exclusive cursor. Arm only at the yield boundary: the CLI app-server cannot see a desktop-owned in-progress turn. If bridge registration fails, use a one-minute task heartbeat as the emergency fallback or report `feedback-created-but-not-armed`.
7. Interpret and record the response and mechanical evidence before advancing. Summarize what was received in the originating Codex task. Post the next action only when the previous result is unambiguous and its preconditions hold.
8. Pause the human interaction on the exact first failure, ambiguity, human confusion, unmet precondition, or device/host state divergence. Do not present another human action until the response is understood and recorded. If the failure is an authorized in-scope product defect, block the visible session, fix it, mechanically verify it, then resume that same session. Do not reconcile divergence by changing the visible session, and never invent Pencil feel, visual taste, intent, or interaction judgments.
9. A resumed bridge turn collects and interprets the response, acknowledges only after collection succeeds, then may present exactly the next action after verifying its precondition. Never claim automatic continuation is active when neither the bridge nor the fallback heartbeat is armed.

### Asynchronous review run

Use one Review Run when the human should complete a packet independently and wake the originating task once at the end.

1. Publish the same chat-only preflight table before creating device state.
2. Include only `human-autonomous` steps. Keep stale-write checks, queue transitions, model follow-ups, mechanical assertions, and any step that needs an agent mutation in guided review or harness conformance.
3. Declare prerequisites explicitly. A failed, skipped, or blocked prerequisite blocks only its dependents; unrelated ready steps remain available.
4. Create one visible session with `create_review_run`. The iPad checklist owns in-progress responses and annotation drafts durably across relaunch.
5. Use active waiting or arm one Codex feedback wake bridge before yielding. Step edits and attachments do not wake the task. `Finish Review` appends one immutable ordered summary and produces the single eligible wake.
6. On wake, acknowledge once, call `collect_review_run`, record each explicit human outcome and attachment, and use `export_review_run` for the evidence bundle.
7. Never infer a verdict from completion state or ask the human to judge mechanical facts. Stop and report if the device is unavailable, the run diverges, or the submitted bundle is incomplete.

### Harness conformance

Use this mode for queue retention, sequence ordering, lifecycle transitions, stale-write rejection, ownership, deduplication, and export behavior. It may create multiple protocol threads, but those threads are internal development fixtures and must not masquerade as a guided review or require the human to interpret protocol state. Prefer automated integration tests. Keep conformance threads separate from the single visible guided session.

## Pencil capture

For authentic Pencil capture, use `request_pen_fixture`, then `await_interaction` / `collect_interaction`, on the physical iPad. Tell the human only the stroke or interaction to perform in TuberNotes. For replay, use `replay_pen_fixture(name)` through the controlled app seam. Stop if the device is unavailable rather than changing targets, inventing feedback, or inventing stroke data.
