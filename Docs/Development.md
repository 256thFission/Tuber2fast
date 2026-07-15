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

Artifacts land under `tmp/verify/<timestamp>-<scenario>/` and include `summary.txt`, `build.log`, `launch.log`, and `screenshot.png`. The script reports mechanical pass/fail only. It does not judge visual taste or Apple Pencil feel.

Reuse an existing build:

```sh
SKIP_BUILD=1 DeveloperTools/verify-scenario.sh multi-pin
```

End user-visible tasks with the evidence packet in `Docs/templates/EvidencePacket.md`. Use `Docs/templates/Handoff.md` when transferring work between sessions or models.

## Scenario-to-change map

| Change type | Required scenarios | Notes |
|---|---|---|
| Canvas / PencilKit drawing surface | `blank-canvas`; reviewed pen fixture when applicable | Confirm ink and paper without Pin clutter; use `human-device-loop` for authentic Pencil |
| Pin layout or spatial anchoring | `fake-pin` and `multi-pin` | Check deterministic positions and overlap |
| App composition / root chrome | `blank-canvas`, `fake-pin`, and `multi-pin` | All three DEBUG states |
| Coordinate / transform work | `fake-pin` and `multi-pin`, before and after viewport change | Once pan/zoom exists; use `spatial-debugging` Skill |
| Human feel / taste / interaction quality | scenario that exposes the change | Mechanical verify first, then `request_human_review` |
| Non-UI / pure contract text | none required | Still avoid product/runtime vs tooling confusion |

Supported scenario values: `blank-canvas`, `fake-pin`, `multi-pin`. Default is `blank-canvas`.

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

For authentic Pencil fixtures or human UI verdicts, use PencilFixtureMCP (Skill: `human-device-loop`). Full tool list and install: `DeveloperTools/PencilFixtureMCP/README.md`.

### Agent path

1. `request_pen_fixture(description)` or `request_human_review(prompt)` pushes a request into the Debug app on the connected device (physical preferred; simulator fallback) and launches it.
2. The Debug app shows the agent prompt in a top banner (`AgentRequestBanner`).
3. `await_interaction` / `collect_interaction` pulls indexed JSON from the device.
4. Record the request id, verdict, optional `humanNotes`, fixture path, and index entry in the evidence packet.

### What the human does on device

| Request kind | Required | Optional |
|---|---|---|
| `pen-fixture` | Draw the requested stroke once | After capture: verdict + free-text note |
| `review` | Tap a verdict: `looks-good` / `needs-work` / `blocked` | Free-text note (`humanNotes`) |

Textual feedback is never required. Verdicts and notes are indexed with the request; strokes are stored as normalized fixture JSON.

### On-device index

```text
Documents/
  agent-requests/pending/<id>.json
  agent-requests/completed/<id>.json
  pen-fixtures/<name>.json
  pen-fixtures/index.json
```

App ownership: `DeveloperSupport` (`PenFixture.swift`, `AgentInteractionSession.swift`, `AgentRequestBanner.swift`). MCP ownership: `DeveloperTools/PencilFixtureMCP`. The human should not set environment variables or copy container files.
