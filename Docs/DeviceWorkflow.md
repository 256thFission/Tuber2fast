# Physical iPad workflow

This is the single target and review lifecycle contract for TuberNotes
development tooling. `Docs/Development.md` owns scenario selection and detailed
commands; repo Skills own task-specific judgment.

## 1. Pin one device

From the repository root, explicitly select the connected iPad:

```sh
DeveloperTools/device-preflight.sh --device <device-id>
```

The preflight validates that the exact target is a connected, paired, booted
physical iPad with Developer Mode and developer services available. It writes
the gitignored `.tubernotes-device-session.json`. The verifier, feedback reset,
and PencilFixtureMCP all consume this file. They do not enumerate alternatives,
accept a target preference, switch devices, or fall back to a simulator.

Rerun preflight whenever the iPad, checkout, or connection changes. Treat a
request pinned to a different target as device/host divergence and stop.

## 2. Build and prove runtime state

Run the scenario verifier after preflight:

```sh
DeveloperTools/verify-scenario.sh <scenario>
```

It builds for the pinned iPad, installs, launches with a per-run nonce, and
pulls fixture-declaration and required runtime-rendered evidence. A PASS covers
only those mechanical facts. The tool does not capture the physical display,
collect an attached console, retrieve device crash diagnostics, automate
navigation, measure Pin drift, or judge interaction quality.

Inspect user-visible behavior on the pinned iPad. Record any uncollected check
as uncollected, not passed.

## 2a. Cross-session safety (one iPad, many conversations)

The iPad is a single shared resource across conversations, agent instances, and
both human tracks. The tooling enforces exclusivity:

- `verify-scenario.sh` takes a PID-owned lock
  (`.tubernotes-device-lock.json`, gitignored) before touching the device and
  releases it on exit. An interrupted conversation does **not** release the
  lock while its orphaned verifier/xcodebuild process keeps running — that is
  intentional: the process still holds the device, so the lock still tells the
  truth. The lock goes stale (and auto-breaks) the moment the owner exits.
- `device-preflight.sh` refuses to pin when a live lock or active
  verifier/xcodebuild/devicectl process from any session holds the device, and
  names the offender. Pass `--reclaim` to kill those orphans and take over.
- A `Device is busy (Connecting…)` build failure after a passing preflight
  means a contender or stuck daemon: run `DeveloperTools/device-recover.sh`.
  It kills repo-scoped orphans, clears the lock, restarts the user-level
  CoreDevice daemon, warns if Xcode.app is open, and re-validates the session.
  If it still fails, follow its printed escalation ladder (unlock → reboot
  iPad → `sudo pkill remoted` → reboot Mac).

Rules for agents: never start a device run while `lock-status` reports a live
foreign owner; prefer waiting over `--reclaim` when the owner may be doing
useful work; count a busy-device stop as a blocked attempt, not a verification
failure; and keep Xcode.app closed during agent verification.

## 3. Start a clean human journey

Between review journeys, clear only stale Debug feedback state:

```sh
DeveloperTools/reset-feedback-state.sh --confirm
```

This uses the pinned session. It does not uninstall the app or delete notebooks,
PDFs, ink, Pins, or Pencil fixtures.

Choose one review mode:

- Use one asynchronous Review Run for independent human-autonomous checks. The
  human may complete ready items in any order and taps `Finish Review` once.
- Use one guided feedback thread for sequential or agent-gated checks. Present
  one current action and at most one short question.
- Use harness conformance for protocol facts; do not expose those fixtures as a
  human review journey.

One visible session stays pinned to one scenario. Never ask the human to manage
Mac files, identifiers, tokens, cursors, queue state, or mechanical assertions.

## 4. Wait and resume

1. Actively call `await_thread_response` while the initiating Codex turn remains
   alive.
2. If no reply has arrived at the yield boundary, arm exactly one
   `arm_codex_feedback_wake` bridge using the exclusive cursor.
3. If bridge registration fails, use a one-minute collection-only task heartbeat
   or report `feedback-created-but-not-armed`.
4. On wake, collect first and acknowledge only after collection succeeds.
5. Record and interpret the response. For guided review, verify the next
   precondition before presenting exactly the next action. For a Review Run,
   collect and export the submitted bundle.

Do not claim event-driven continuation unless the bridge is armed. If the
desktop-owned task does not surface an externally resumed turn, report the host
integration mismatch and continue from CLI; do not conceal it with rapid polling.

Stop on the first failure, ambiguity, human confusion, missing prerequisite,
unavailable device, or device/host divergence.
