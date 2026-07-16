# Development loop

Canonical configuration:

- Project: `TuberNotes.xcodeproj`
- Scheme: `TuberNotes`
- Simulator: `iPad Pro 13-inch (M5)` on the newest installed iOS runtime
- Bundle ID: `com.tubernotes.app`

Agent operating rules, checkpoints, and evidence requirements live in `AGENTS.md`.

## Preferred verification command

For user-visible work, prefer the one-shot verifier (build → install → launch scenario → screenshot → artifact paths):

```sh
DeveloperTools/verify-scenario.sh fake-pin
```

Artifacts land under `tmp/verify/<timestamp>-<scenario>/` and include `summary.txt`, `build.log`, `launch.log`, `scenario-selection.json`, and `screenshot.png`. The script reports mechanical pass/fail only. It does not judge visual taste or Apple Pencil feel.

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
FORCE_MECHANICAL_FAILURE=1 SKIP_BUILD=1 DeveloperTools/verify-scenario.sh blank-canvas
```

This command is expected to exit nonzero. Its bundle includes `intentional-failure.txt`; later verifier runs remain normal because the failure is opt-in for that process only.

End user-visible tasks with the evidence packet in `Docs/templates/EvidencePacket.md`. Use `Docs/templates/Handoff.md` when transferring work between sessions or models.

## Scenario-to-change map

| Change type | Required scenarios | Notes |
|---|---|---|
| Canvas / PencilKit drawing surface | `blank-canvas`; reviewed pen fixture when applicable | Confirm ink and paper without Pin clutter; use `human-device-loop` for authentic Pencil |
| PDF page surface | `pdf-pages` and `ink-pages` | Fixture selection is callable; expected UI requires coordinator App wiring |
| Blank notebook surface | `blank-notebook` and `notebook-pages` | Fixture selection is callable; expected UI requires coordinator App wiring |
| Pin layout | `fake-pin`, `multi-pin`, and `edge-pins` | Check deterministic positions, overlap, and edge clipping |
| App composition / root chrome | `blank-canvas`, `fake-pin`, and `multi-pin` | All three DEBUG states |
| Coordinate / transform work | `pin-drift` before and after viewport change | Fixture selection is callable; viewport assertion requires coordinator App wiring; use `spatial-debugging` Skill |
| Human feel / taste / interaction quality | scenario that exposes the change | Mechanical verify first, then create a feedback thread; use the morning queue for human-only checks |
| Non-UI / pure contract text | none required | Still avoid product/runtime vs tooling confusion |

M0 verifier values are `blank-canvas`, `fake-pin`, `multi-pin`, `pdf-pages`, `blank-notebook`, `notebook-pages`, `ink-pages`, `pin-drift`, and `edge-pins`. Default is `blank-canvas`.

`DevelopmentScenario.fixture` owns stable documents, page IDs, page-specific `PenFixture` values, canned `PageAnnotation` values, expected state, and integration readiness. `blank-canvas`, `fake-pin`, and `multi-pin` are rendered by the current scaffold. The other M0 selections, fixture inputs, expected-state reporting, and evidence capture are runnable, but their full expected UI states remain **ready for coordinator App wiring**. A verifier PASS for those scenarios proves the automation path, launch, screenshot integrity, console scan, and crash scan; it does not accept the pending UI state.

## Manual loop

Open the project in Xcode for normal work. If XcodeBuildMCP is available to an agent, use it with the canonical values above. Otherwise keep terminal output concise:

```sh
xcodebuild -project TuberNotes.xcodeproj -scheme TuberNotes \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath DerivedData build | tee /tmp/tubernotes-build.log | tail -n 40
```

Boot, install, and launch the built app:

```sh
xcrun simctl boot 'iPad Pro 13-inch (M5)' 2>/dev/null || true
open -a Simulator
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/TuberNotes.app
xcrun simctl launch --terminate-running-process booted com.tubernotes.app
```

For a scenario, prefix app variables with `SIMCTL_CHILD_`:

```sh
SIMCTL_CHILD_TUBER_SCENARIO=fake-pin xcrun simctl launch --terminate-running-process booted com.tubernotes.app
```

Xcode may instead pass `--scenario fake-pin`. Capture a screenshot when inspection must be shared:

```sh
xcrun simctl io booted screenshot tmp/verify/manual-screenshot.png
```

A successful compile is insufficient verification of user-visible behavior.

Physical Apple Pencil feel and latency require a human on real iPad hardware.

## Human device loop

PencilFixtureMCP exposes two separate Debug-only protocols. Use feedback threads for conversational UI review. Use the pen-fixture protocol only when authentic Apple Pencil input must become a replayable fixture. Skill: `human-device-loop`; tool details and installation: `DeveloperTools/PencilFixtureMCP/README.md`.

### Feedback-thread agent path

1. `create_feedback_thread` creates an owned, target-pinned review session and either activates it or queues it FIFO.
2. The Debug app shows a minimal floating bar. The human uses the full-screen thread view to reply, answer, annotate, block, or resolve.
3. `await_thread_response` waits for a newer human reply; `collect_thread_updates` collects ordered messages and durable attachment paths after a sequence cursor.
4. Use `post_thread_message` for normal follow-up or bounded revision metadata and `ask_thread_question` for free-text or single-choice questions.
5. Use `set_feedback_thread_state` for optimistic block, resolve, cancel, resume, or reopen transitions; pass the last sequence consumed so newer human feedback cannot be skipped. A human-requested reopen is prioritized ahead of ordinary queued work without preempting the active review.
6. Use `get_feedback_thread` for durable state/history and `export_feedback_thread` for a bounded Markdown evidence transcript.

Keep the returned `owner_token`; only its hash is persisted. A human reply moves the active feedback thread to `awaiting-model`, retaining the device slot. A genuinely `blocked`, `resolved`, or `cancelled` thread releases the slot and advances the next queued scenario cleanly. Prefer one focused clarification before revising; ask another only when the answer exposes a materially different ambiguity.

Screenshots are human-triggered. The model may request one in a message but cannot invoke capture or send. The human must preview, may annotate with the native PencilKit tool palette, caption, cancel, and explicitly send. History emphasizes the annotated preview while collection retains both clean and annotated PNG paths. Feedback-thread UI is excluded from the captured product viewport.

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
