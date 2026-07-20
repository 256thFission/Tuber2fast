# WL-F — Long-press Pin conversation UI (Track I)

Status: mechanically-accepted — steps 1–3 pass on the pinned iPad; human conversation-quality review remains unqueued because the feedback queue reports divergent device-slot ownership
Owner subsystem: coordinator `App` + `AgentHarness` (recorded conversation
turns); `Pins` consumed as-is
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
- `TuberNotes/AgentHarness/` (recorded conversation turns)
- `TuberNotes/DeveloperSupport/DevelopmentScenario.swift` (`pin-conversation`)
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
