# Development loop

Canonical configuration:

- Project: `TuberNotes.xcodeproj`
- Scheme: `TuberNotes`
- Destination: the physical iPad pinned by `DeveloperTools/device-preflight.sh`
- Bundle ID: `com.tubernotes.app`

The target and review lifecycle contract is `Docs/DeviceWorkflow.md`. Start each
device session explicitly:

```sh
DeveloperTools/device-preflight.sh --device <device-id>
```

Commands must stop when the pinned iPad is unavailable, locked, untrusted,
offline for developer-mode validation, or divergent from host state. They must
never choose another target.

Agent operating rules, checkpoints, and evidence requirements live in `AGENTS.md`.

## Preferred verification command

For user-visible work, prefer the one-shot verifier (device build → install → launch scenario → pull runtime evidence → artifact paths):

```sh
DeveloperTools/verify-scenario.sh fake-pin
```

Artifacts land under `tmp/verify/<timestamp>-<scenario>/` and include `summary.txt`, `build.log`, `install.log`, `launch.log`, `scenario-selection.json`, and required `runtime-rendered.json`. The script reports a narrow mechanical pass/fail for physical-device build/install/launch and nonce-matched app evidence. It does not capture the physical screen, collect an attached console or device crash report, automate navigation, judge visual taste, or judge Apple Pencil feel; report those checks separately.

Show the exact M0 allowlist and expected states:

```sh
DeveloperTools/verify-scenario.sh --help
```

Reuse an existing build:

```sh
SKIP_BUILD=1 DeveloperTools/verify-scenario.sh multi-pin
```

Prove that mechanical failures produce a failing summary and a durable artifact without changing the normal app:

```sh
FORCE_MECHANICAL_FAILURE=1 SKIP_BUILD=1 \
  DeveloperTools/verify-scenario.sh blank-canvas
```

This command is expected to exit nonzero. Its bundle includes `intentional-failure.txt`; later verifier runs remain normal because the failure is opt-in for that process only.

End user-visible tasks with the evidence packet in `Docs/templates/EvidencePacket.md`. Use `Docs/templates/Handoff.md` when transferring work between sessions or models. When preparing a new device-review journey, start with the owning major-group guide in `Docs/ReviewGuides/README.md`.

## Scenario-to-change map

| Change type | Required scenarios | Notes |
|---|---|---|
| Canvas / PencilKit drawing surface | `blank-canvas`; reviewed pen fixture when applicable | Confirm ink and paper without Pin clutter; use `human-device-loop` for authentic Pencil |
| PDF page surface | `pdf-pages` and `ink-pages` | Both scenarios are App-wired with stable page identity and page-local canned ink |
| Blank notebook surface | `blank-notebook` and `notebook-pages` | Both scenarios are App-wired with stable navigation; verify App-owned page addition in `blank-notebook` |
| Pin layout | `fake-pin`, `multi-pin`, and `edge-pins` | Check deterministic positions, overlap, and edge clipping |
| App composition / root chrome | `blank-canvas`, `fake-pin`, and `multi-pin` | All three DEBUG states |
| Coordinate / transform work | `pin-drift` before and after viewport change | Use the deterministic `Change viewport` control and the `spatial-debugging` Skill |
| Human feel / taste / interaction quality | scenario that exposes the change | Mechanical verify first, then create a feedback thread; use the morning queue for human-only checks |
| Non-UI / pure contract text | none required | Still avoid product/runtime vs tooling confusion |

M0 verifier values are `blank-canvas`, `fake-pin`, `multi-pin`, `pdf-pages`, `blank-notebook`, `notebook-pages`, `ink-pages`, `pin-drift`, `edge-pins`, and the explicitly partial `hero-recorded` stub. Default is `blank-canvas`.

`DevelopmentScenario.fixture` owns stable documents, page IDs, page-specific `PenFixture` values, canned `PageAnnotation` values, expected state, and integration readiness. `blank-canvas`, `fake-pin`, and `multi-pin` are rendered by the current scaffold. `pdf-pages`, `blank-notebook`, `notebook-pages`, `ink-pages`, `pin-drift`, and `edge-pins` are rendered through the coordinator App integration seam. `hero-recorded` is only a bounded offline recorded agent-to-Pin **stub**; genuine SpatialCanvas lasso capture and crop remain pending, so it is not App-wired acceptance evidence. Other selections remain **ready for coordinator App wiring** or later milestones; a verifier PASS for those states does not accept pending UI behavior.

## Manual loop

Open the project in Xcode for normal work. If XcodeBuildMCP is available to an agent, use it with the canonical values above. Otherwise keep terminal output concise:

```sh
TUBER_DEVICE_ID="$(python3 DeveloperTools/device_session.py resolve)"
xcodebuild -project TuberNotes.xcodeproj -scheme TuberNotes \
  -configuration Debug \
  -destination "platform=iOS,id=$TUBER_DEVICE_ID" \
  -derivedDataPath DerivedDataDevice \
  build | tee /tmp/tubernotes-device-build.log | tail -n 40
```

Install and launch the built app on that same iPad:

```sh
xcrun devicectl device install app \
  --device "$TUBER_DEVICE_ID" \
  DerivedDataDevice/Build/Products/Debug-iphoneos/TuberNotes.app
xcrun devicectl device process launch \
  --device "$TUBER_DEVICE_ID" \
  --terminate-existing \
  com.tubernotes.app
```

For a scenario, pass device launch environment explicitly:

```sh
xcrun devicectl device process launch \
  --device "$TUBER_DEVICE_ID" \
  --terminate-existing \
  --environment-variables '{"TUBER_SCENARIO":"fake-pin"}' \
  com.tubernotes.app
```

Xcode may instead pass `--scenario fake-pin`. A successful compile or runtime
marker is insufficient verification of user-visible behavior: inspect the
running iPad. When evidence must be shared, request a human-triggered screenshot
through `human-device-loop`; the human previews and sends it from TuberNotes.

## DEBUG live Codex adapter

The `hero-recorded` surface remains recorded unless DEBUG is launched with both
`TUBER_AGENT_MODE=codex` and a temporary `TUBER_CODEX_ACCESS_TOKEN`. The direct
wire-model default is exposed as `DebugCodexConfiguration.defaultModel` and is
currently `gpt-5.6-terra`; `TUBER_CODEX_MODEL` may override it for a bounded
comparison. `TUBER_CODEX_ACCOUNT_ID` is optional.

Do not place a real token in a shared Xcode scheme, source file, fixture, log, or
artifact. The adapter holds launch configuration in process memory, uses an
ephemeral URL session, and streams the undocumented ChatGPT Codex response as
typed Responses SSE events. If live mode is requested without a token, the app
shows a credential failure instead of silently falling back to the recording.
The current hero sends a deterministic 580×380 rendering of its selected
algebra work; genuine user-driven lasso capture is still a separate milestone.
This adapter is deliberately one-shot: it forces one strict `place_pins` call,
does not advertise a reusable conversation ID, and rejects continuation input.
Live-provider evidence must be labeled separately and must never substitute for
the credential-free recorded scenario.

## Human device loop

PencilFixtureMCP exposes two separate Debug-only protocols. Use feedback threads for conversational UI review. Use the pen-fixture protocol only when authentic Apple Pencil input must become a replayable fixture. Skill: `human-device-loop`; tool details and installation: `DeveloperTools/PencilFixtureMCP/README.md`.

### Feedback-thread agent path

Feedback threads have three modes. Prefer an **Asynchronous Review Run** when the human can perform independent checks in any order: put all human-autonomous checks in one visible checklist, let drafts persist independently, and wake the task once after `Finish Review`. Use **Guided human review** for agent-gated or sequential actions, with one visible thread for one complete one-at-a-time journey. **Harness conformance** exercises queues, ordering, lifecycle, ownership, and persistence with isolated internal fixtures, preferably automated. Never surface conformance threads as review steps.

1. `create_feedback_thread` creates an owned, target-pinned review session and either activates it or queues it FIFO. Create one thread for a guided journey and reuse it.
   - Privately separate preconditions, one human action, mechanical assertions, and an optional human-only question.
   - Show only that action and question. Keep protocol identifiers, cursors, states, queue details, test keys, paths, and expected assertions off the device.
   - Never combine an exact-answer instruction with a PASS/FAIL request.
2. The Debug app shows a minimal floating bar. The human uses the full-screen thread view to reply, answer, annotate, block, or resolve.
3. While the initiating Codex turn is active, use `await_thread_response` as the fast path. Before yielding without a reply, call `arm_codex_feedback_wake`; its detached local bridge polls the device and resumes the exact CLI thread through Codex app-server only when a reply becomes eligible. Arm only at the yield boundary so the standalone app-server cannot race a desktop-owned turn. A one-minute task heartbeat is an emergency fallback only if bridge arming fails.
4. The resumed turn collects ordered messages and durable attachment paths with `collect_thread_updates`, acknowledges the dispatched `wake_id` only after collection succeeds, then presents the next focused action with `ask_thread_question` when its precondition holds.
5. Use `post_thread_message` for normal follow-up or bounded revision metadata and `ask_thread_question` for free-text or single-choice questions.
6. Use `set_feedback_thread_state` for optimistic block, resolve, cancel, or blocked-thread resume transitions; pass the last sequence consumed so newer human feedback cannot be skipped. Resolved and cancelled threads are immutable and cannot be reopened.
7. Close the watch on terminal/blocked state. Use `get_feedback_thread` for durable state/history and `export_feedback_thread` for a bounded Markdown evidence transcript.

For an asynchronous packet, publish the chat-only preflight table, then use
`create_review_run` with ordered steps and explicit prerequisites. Include only
human-autonomous judgments or actions; keep agent-gated transitions and
mechanical assertions out of the packet. The human may pass, fail, block, or
skip a step and continue with unrelated ready steps. Responses and annotations
persist without appending messages. `Finish Review` appends one immutable
ordered summary and creates the single eligible wake. Collect and acknowledge it once,
call `collect_review_run`, then `export_review_run` for the evidence bundle.

After collection, summarize the interpreted response in the originating Codex task before presenting another action. Stop on the exact first failure, ambiguity, human confusion, unmet precondition, or device/host state divergence. Do not change the visible session to hide or reconcile a divergence, and do not infer subjective judgments from protocol state.

Keep the returned `owner_token`; only its hash is persisted. Bridge registration transfers the raw capability through an anonymous pipe and never writes it into its watch or configuration files. A human reply moves the active feedback thread to `awaiting-model`, retaining the device slot. A genuinely `blocked`, `resolved`, or `cancelled` thread releases the slot and advances the next queued scenario cleanly. Prefer one focused clarification before revising; ask another only when the answer exposes a materially different ambiguity.

Screenshots are human-triggered. The model may request one in a message but cannot invoke capture or send. The human must preview, may annotate with the native PencilKit tool palette, then attach the result to the reply composer. The annotation remains an unsent draft until the human explicitly sends the reply, which may include text and the screenshot as one message. Canceling or removing the draft publishes nothing. History emphasizes the annotated preview while collection retains both clean and annotated PNG paths. Feedback-thread UI is excluded from the captured product viewport.

Text, choice, and optional-comment drafts are owned by the feedback session and keyed by feedback-thread ID. They persist across focus loss, compact/full-screen transitions, and capture/annotation presentation. A draft clears only after its submission succeeds. Switching to another queued thread does not leak the draft into that thread. Resolved and cancelled threads cannot be reopened.

### Pen-fixture agent path

1. `request_pen_fixture(description)` pushes a Pencil capture request into the Debug app on the connected device.
2. The human draws the requested stroke and may add a verdict/note.
3. `await_interaction` / `collect_interaction` pulls the indexed fixture JSON.
4. Record request ID, verdict, optional `humanNotes`, fixture path, and index entry in the evidence packet.

Pen fixtures are a separate protocol and corpus; they are not feedback-thread interaction types.

### On-device data

```text
Documents/
  feedback-threads/
    queue.json
    events.jsonl
    <feedback-thread-id>/
      thread.json
      messages/*.json
      attachments/*.png
  agent-requests/pending/<id>.json
  agent-requests/completed/<id>.json
  pen-fixtures/<name>.json
  pen-fixtures/index.json
```

App ownership remains `DeveloperSupport`; MCP ownership remains `DeveloperTools/PencilFixtureMCP`. The human should not set environment variables or copy container files. Feedback-thread mirrors, attachments, event logs, and exports are gitignored and collected by the MCP.

### Resetting stale Debug feedback state

If obsolete questions remain visible after a failed or abandoned review, use the
confirmation-gated host command below. It clears only this checkout's
`.feedback-threads` mirror and the app's Debug feedback-thread store, then
relaunches the installed app normally:

```sh
DeveloperTools/reset-feedback-state.sh --confirm
```

The pinned device session and `--confirm` are required. The command validates
that `com.tubernotes.app` is installed before deleting the host mirror. It does
not uninstall TuberNotes or delete notebooks, imported documents, ink, Pins,
Pencil fixtures, or other product data. Run it only between review journeys;
all unresolved feedback threads, drafts, queue entries, watches, collected
attachments, and host-side feedback exports are intentionally discarded.
