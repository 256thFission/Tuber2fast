# WL-F — Long-press Pin conversation UI (Track I)

Status: mechanically-accepted — steps 1–3 pass on the pinned iPad; composition/feel was accepted as "Excellent" directly in the originating Codex task, but discoverability remains open because Phillip could not reliably trigger the final long-press and needed the sidebar opened remotely
Owner subsystem: coordinator `App` + `AgentHarness` (recorded conversation
turns) + `Pins` (Pin-owned hold gesture and spatial affordance)
Depends on: WL-B step 3 (real hero loop). Independent of Track N.
Subagent-eligible: steps 1–2 yes (bounded, fixture-driven); step 3 integration
stays with the coordinator.

## Objective

Promoted into SPEC critical path July 19, 2026 (SPEC §1 Confirmed #11). A
long-press on an existing Pin opens a threaded conversation anchored to that
Pin's investigation:

- conversation panel opens from the Pin without leaving the page (the thesis:
  never move the user into a detached chat box — the thread stays visually
  tethered to the Pin);
- typed follow-up turns construct `InvestigationRequest`s that reuse the
  retained `SelectionArtifact` and set `conversationID` to continue the
  original investigation;
- recorded conversation turns stream through the existing `AgentEvent` path;
  replies render in the thread, and a reply may also place additional Pins
  (`pinStarted`/`pinCompleted` still work mid-conversation);
- cancel/retry semantics match the action strip; dismissing the panel
  preserves the thread for the next long-press.

## Steps (bounded, in order)

1. **Recorded conversation fixture.** Add a recorded multi-turn sequence to
   `AgentHarness` (extend `RecordedAgentClient` scenarios) keyed by
   `conversationID`: first turn = existing hero Check; follow-up turn =
   deterministic threaded reply. Focused tests alongside
   `DeveloperTools/AgentKnowledgeTests`.
2. **Conversation panel UI** against the fixture: long-press gesture on an
   expanded Pin, threaded transcript view, typed input, streaming reply
   rendering, cancel/retry. New scenario `pin-conversation` (contract
   addition — flag per the `CONTRACT:` rule) with runtime evidence.
3. **Hero integration:** long-press works on Pins produced by the real WL-B
   loop; thread persists across page turn away/back within the session.
   Persistence of threads across relaunch is Track N's store — coordinate,
   don't implement store internals here.

## Files in scope

- `TuberNotes/App/` (conversation panel, gesture wiring)
- `TuberNotes/Pins/` (Pin-owned gesture recognition and conversation request)
- `TuberNotes/AgentHarness/` (recorded conversation turns)
- `TuberNotes/DeveloperSupport/DevelopmentScenario.swift` (`pin-conversation`)
- `TuberNotes/DeveloperSupport/FeedbackThread*` and focused DeveloperTools
  checks only for the screenshot-crash and false-block review defects exposed
  during WL-F human testing
- `TuberNotes/App/Contracts/` only via `CONTRACT:`-flagged commits; expected
  pressure point: a thread/turn record type if `conversationID` alone proves
  insufficient — change it, flag it, log it.

## Non-goals

- Voice input, handwritten follow-up recognition (still deferred)
- Live provider turns (WL-D; recorded only here)
- Pin visual redesign; SpatialCanvas or persistence-store internals (Track N)
- Full detached chat screen — the thread stays Pin-anchored by design

## Acceptance evidence

- Focused tests PASS for the recorded multi-turn sequence (ordering,
  conversationID continuity, cancellation mid-turn).
- `pin-conversation` scenario PASS with rendered runtime evidence: long-press
  opens thread, follow-up turn streams, reply rendered, page state intact.
- Cancel mid-reply and invalid follow-up output leave Pin and page state
  uncorrupted.
- Evidence Packet per template.

## Human review (after step 3)

Guided journey: read a Pin → long-press → ask a follow-up → read the reply.
Human-only checks: gesture discoverability, thread legibility over page
content, timing/feel of the streamed reply.

## Follow-up

- Add one visible affordance on first Pin expansion, such as a persistent
  "Hold for follow-up" hint. Do not address this with another timing tweak.
- Run one two-minute human re-test covering unaided sidebar discovery and a
  screenshot re-send. Screenshot submission is hardened but was not
  re-exercised after the reported crash; this follow-up does not block WL-F
  mechanical closeout.

## Stop conditions

- Step 3 evidence collected → stop.
- Architecture-ownership pressure (e.g. conversation state wanting to live in
  SpatialCanvas) → stop, escalate to Phillip.
- Two verification failures without a narrower fix → stop, report.

## Session log

- 2026-07-19 — Step 1 complete: `RecordedAgentClient` continues the hero
  Check for the matching `recorded-hero` conversation ID, preserves selection
  and event ordering, rejects unknown continuation IDs, and cancels mid-turn
  without late completion. Focused strict-concurrency checks pass. Steps 2–3
  are implemented on the work-line branch and await pinned-device evidence.
- 2026-07-19 — Steps 2–3 mechanically accepted on physical iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`. `pin-conversation` proves the real
  lasso → recorded Check → Pin path, a Pin-tethered three-turn transcript,
  `recorded-hero` continuity, a streamed follow-up Pin, and the same open
  thread after page-away/page-return. `hero-recorded`,
  `agent-recorded-success`, and `agent-recorded-failure` also pass from the
  same build. The first `pin-conversation` attempt exposed an already-active
  feedback thread rebinding an explicit verifier launch; the narrow App guard
  now isolates explicit scenarios, and the next run passed. Artifacts:
  `tmp/verify/20260719-200836-pin-conversation/`,
  `tmp/verify/20260719-200905-hero-recorded/`,
  `tmp/verify/20260719-200916-agent-recorded-success/`, and
  `tmp/verify/20260719-200941-agent-recorded-failure/`. The requested guided
  human journey was not created because the feedback queue reported multiple
  device-slot owners; no existing review session was reset or cancelled.
- 2026-07-19 — Phillip authorized clearing the divergent feedback queue and
  completed the guided Pin conversation journey. Human verdict: the long-press
  was not discoverable, and the persistent `Proposed Pin ready` / Retry card
  visually fights the conversation panel. The attached screenshot confirms
  the App `ZStack` renders the completed-investigation terminal control after
  `PinConversationAnchor`, leaving it above the thread. Phillip suggested a
  subtle shake plus a slowly tracing outline around the Pin as a discoverability
  cue. The review stopped at this first failure and was exported under the
  gitignored `.feedback-threads/collected/` evidence directory.
- 2026-07-20 — Human-review corrections completed on
  `codex/wl-f-human-fixes`: the cramped popup became a Pin-tethered right
  sidebar; tap and hold became mutually exclusive; the 0.35-second hold cue
  cancels immediately on release; the completed-investigation Retry card no
  longer overlaps the thread; feedback fixture binding was corrected; capture
  PNGs now encode sequentially; Block requires confirmation; and the canvas
  ignores the keyboard bottom inset so keyboard presentation does not resize
  the page. Phillip accepted composition/feel as "Excellent" directly in this
  Codex task. Provenance: this was not submitted through the device feedback
  thread and therefore has no thread-side verdict evidence. Phillip could not
  reliably trigger the long-press after the final gesture fixes and needed the
  sidebar opened remotely, so discoverability remains an open finding and the
  line remains mechanically accepted rather than human accepted. The dangling
  device prompt was explicitly resolved at sequence 5 before export; its watch
  is closed. Screenshot re-send is hardened but not re-exercised and is folded
  into the follow-up journey above.

## Evidence packet — 2026-07-20 closeout

### Objective

- Deliver a recorded multi-turn conversation from a real WL-B Pin in a
  Pin-tethered sidebar, retaining the thread across an in-session page turn.

### Changed files

- `TuberNotes/App/RootView.swift`
- `TuberNotes/Pins/Pin.swift`
- `TuberNotes/Pins/PinOverlayView.swift`
- `TuberNotes/DeveloperSupport/FeedbackThreadSession.swift`
- `TuberNotes/DeveloperSupport/FeedbackThreadViews.swift`
- `DeveloperTools/PencilFixtureMCP/tests/test_review_harness_ui.py`
- Human-review workflow documentation in `AGENTS.md`, `Docs/Development.md`,
  `Docs/DeviceWorkflow.md`, `.codex/skills/human-device-loop/SKILL.md`, and
  `DeveloperTools/PencilFixtureMCP/README.md`

### Diff summary / scope check

- Recorded continuation and scenario contracts were already mechanically
  accepted. This correction branch adds precise Pin-owned hold handling, the
  App-owned tethered sidebar, stable canvas sizing during keyboard presentation,
  and narrow feedback-harness crash/false-block safeguards.
- Final diff stayed within WL-F plus the directly implicated review tooling and
  documentation. No SpatialCanvas ownership, persistence-store internals,
  live-provider path, WL-C acceptance, or Pencil review was changed.
- Contract seam: additive `PinOverlayEvent.conversationRequested(annotationID:)`
  is committed under `CONTRACT:` and logged in the parent plan; conversation
  state remains App-owned.

### Build and verification

- Build: PASS on physical iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`.
- Focused review-harness source checks: 16 PASS.
- `pin-conversation`: PASS —
  `tmp/verify/20260719-213910-pin-conversation/`.
- `hero-recorded`: PASS —
  `tmp/verify/20260719-213928-hero-recorded/`.
- `agent-recorded-success`: PASS —
  `tmp/verify/20260719-213934-agent-recorded-success/`.
- `agent-recorded-failure`: PASS —
  `tmp/verify/20260719-213941-agent-recorded-failure/`.
- Runtime evidence proves the real lasso/crop → recorded Check → Pin path, a
  three-turn `recorded-hero` continuation, streamed reply completion, and the
  open thread after page-away/page-return. No attached console, device crash
  diagnostic, or final-frame screenshot was collected by the verifier.

### Mechanical and human checks

- Build/install/launch, scenario selection, required runtime state, retained
  crop, deterministic Pin identity, conversation continuity, and page-return
  survival passed.
- The earlier annotated screenshot is retained at
  `.feedback-threads/attachments/feedback-ed33917e1669401eac1b291331f60534/feedback-attachment-1e74ceb1-8e21-4ad0-8ab1-cbfd847e4fef-annotated.png`.
- Feedback transcript export:
  `.feedback-threads/collected/feedback-ed33917e1669401eac1b291331f60534/evidence/feedback-thread.md`.
- Device feedback thread: explicitly resolved with its unanswered final prompt
  at sequence 5; watch closed; no final thread-side verdict.
- Human judgment provenance: Phillip wrote "Excellent" directly in the
  originating Codex task for composition/feel. This is not represented as
  device-thread evidence.
- Open human finding: Phillip could not reliably discover/trigger the final
  long-press and required remote sidebar presentation.
- Screenshot re-send and final keyboard non-resize behavior were not
  human-re-exercised after hardening.

### Stop reason / unresolved issues

- WL-F mechanical evidence bar passes. Closeout stops at mechanically accepted
  with one non-blocking discoverability follow-up: a visible first-expansion
  affordance and a two-minute re-test that also re-exercises screenshot send.
