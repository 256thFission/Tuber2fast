# WL-B — Investigation UI and hero integration

Status: in-progress — steps 1–2 mechanically complete
Owner subsystem: coordinator `App`, consuming `AgentHarness` and `Pins` as-is
Depends on: P0. Step 3 depends on WL-A.
Subagent-eligible: **no** — this is coordinator integration work.

## Objective

Replace the `RecordedHeroView` stub in `TuberNotes/App/RootView.swift` with the
genuine M1 loop on the real spatial surface:

- `LassoState` machine (SPEC §5.2) driving truthful UI states;
- action strip with **Explain / Check / typed Ask** adjacent to the selection,
  no intermediate screen (SPEC §5.4);
- recorded `AgentEvent` stream → progress states → streaming `PinDraft` →
  page-normalized `PageAnnotation` via the existing transform → `PinOverlayView`
  on the real canvas;
- Retry without redrawing the lasso; cancellation and invalid output leave the
  page intact.

## Steps (bounded, in order — one session each)

1. **Action strip + state machine against a fixture `SelectionArtifact`.**
   Does not wait on WL-A. Reuse the fixture-crop construction currently inside
   `RecordedHeroView` as the stand-in selection.
2. **Recorded scenarios light up.** Wire `RecordedAgentClient` variants so
   `agent-recorded-success`, `agent-recorded-retrieval`, and
   `agent-recorded-failure` move from `later-milestone` to `app-wired`, with
   runtime evidence and verifier expectations (coordinate with WL-E).
3. **Swap in the real selection.** When WL-A lands, replace the fixture
   artifact with live lasso output; `hero-recorded` becomes the genuine
   end-to-end recorded Check on the real canvas and drops `partial-stub`.
   Delete `RecordedHeroView`.

## Files in scope

- `TuberNotes/App/RootView.swift` and new `TuberNotes/App/` views for the
  action strip / progress UI
- `TuberNotes/DeveloperSupport/DevelopmentScenario.swift` (scenario readiness
  and fixtures for the three recorded scenarios)

## Non-goals

- Live networking (WL-D); persistence (WL-C); Pin redesign; changes inside
  `AgentHarness` or `SpatialCanvas`; knowledge-tool decisioning beyond the
  recorded retrieval sequence.

## Acceptance evidence (M1 gate, SPEC §16)

- Explain / Check / typed Ask produce the correct `InvestigationIntent`.
- Recorded events drive truthful progress states (never claim activity that
  is not happening).
- Valid crop-relative drafts become page-normalized annotations on the correct
  page; invalid coordinates are rejected without corrupting state.
- Retry works without redrawing; Cancel from submitting/receiving preserves
  the page.
- Verifier PASS with runtime evidence for `agent-recorded-*` and
  `hero-recorded`.
- Evidence Packet per template.

## Human review (after step 3)

Guided `human-device-loop` journey: lasso → Check → watch progress → read Pin.
Human-only checks: status clarity, Pin readability/obstruction, interaction
timing. Never ask the human to judge mechanical facts.

## Stop conditions

- M1 gate evidence collected → stop.
- Shared-contract change required → stop, escalate.
- Two verification failures without a narrower fix → stop, report.

## Session log

- 2026-07-19 — Step 1 mechanically complete. Replaced the automatic
  `RecordedHeroView` journey with a fixture-backed `.selected` state and an
  adjacent Explain / Check / typed Ask action strip. Each action constructs an
  `InvestigationRequest` retaining the fixture `SelectionArtifact` and moves to
  `.submitting`; selection and submitting cancellation return safely to
  `.idle`, with a Debug fixture restore control for repeatable checks. Physical
  iPad build/install/launch passed on
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`; nonce-matched runtime evidence is in
  `tmp/verify/20260719-141254-wl-b-step1/`. Stopped before recorded event
  wiring, progress/Pin handling, scenario readiness changes, and live lasso
  integration (steps 2–3).
- 2026-07-19 — Step 2 mechanically complete. Wired the success, retrieval,
  and recoverable-failure `RecordedAgentClient` variants through truthful
  submitting/receiving/terminal UI; valid crop-relative drafts now render as
  page-normalized streaming/completed Pins, while cancel and Retry retain the
  fixture selection. Moved the three `agent-recorded-*` fixtures to
  `app-wired`. With coordinator approval, made the narrow WL-E ownership
  exception needed to add verifier allowlist/runtime expectations for only
  those scenarios. Generic iOS build, strict-concurrency agent checks, and
  verifier truthfulness tests passed. Physical iPad preflight and all three
  scenario verifiers passed on `2DD98ECC-A26A-5730-943B-01DD63DC4117`; runtime
  artifacts are in `tmp/verify/20260719-150032-agent-recorded-success/`,
  `tmp/verify/20260719-150050-agent-recorded-retrieval/`, and
  `tmp/verify/20260719-150057-agent-recorded-failure/`. Stopped before step 3
  and live lasso integration; human interaction/visual review remains deferred
  until step 3 per this work-line plan.
