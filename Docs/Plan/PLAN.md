# TuberNotes — Execution Plan (parent doc)

This is the single long-running coordination document. One work line = one
child doc = one bounded task.

Authority chain: `SPEC.md` (product contracts) → `AGENTS.md` (operating
contract) → this plan (current execution) → child docs (per-line detail).

## PIVOT (Phillip, July 20, 2026)

The product of THIS repository is now **PointBackKit**: a standalone Swift
package implementing the intelligence layer — Magic Lasso selection, the
Explain/Check/Ask hero interaction, recorded + live agent clients, Pins, and
the Pin-tethered conversation sidebar — usable by **any** Swift canvas that
conforms to a small host adapter protocol.

- The notebook substrate (canvas, pages, ink, persistence) is Phillip's
  friend's, on their better branch. This repo no longer competes with it.
- The existing TuberNotes app here shrinks into the **reference host**: it
  proves the package works, keeps the scenario verifier meaningful, and serves
  as the adapter's living documentation.
- The frozen contracts evolve into the package's public API.

Packaging decisions (locked):

1. **SPM package inside this repo** (`PointBackKit/`); extraction to its own
   repo is a later one-move operation. Name is provisional — renaming is a
   find/replace, not a design decision.
2. **Page-aware adapter.** The host provides page identity and page-normalized
   coordinates (the existing contract shape). A single-canvas host is the
   degenerate one-page case.
3. **The layer owns the lasso gesture; the host owns snapshots.** Any host
   view gets the gesture/glow overlay from the package; the host implements
   one rendering method ("visible content in this page-normalized rect →
   image"). Hosts with native capture (the reference host's SpatialCanvas)
   may bypass the overlay and deliver a `SelectionArtifact` directly.

## Prior decisions still in force

- ~1 week horizon; recorded agent demos, live provider (WL-D) is a gated
  stretch behind `AgentClient`.
- Contracts are soft: `CONTRACT:`-prefixed commits + a plan-log entry;
  Phillip reviews after the fact. Architecture-*ownership* changes still need
  Phillip first.
- Phillip coordinates and merges everything in this repo. The friend's repo
  is out of bounds for agents here; the seam is the adapter API.
- Long-press Pin conversation is critical path (delivered by WL-F; one open
  discoverability finding).

## Status board

States: `not-started` → `in-progress` → `mechanically-accepted` →
`human-accepted`. Blockers get named inline.

### Active — PointBackKit

| Line | Child doc | Status |
|---|---|---|
| WL-G — Package extraction + CanvasHost API | [WL-G-PackageExtraction.md](WL-G-PackageExtraction.md) | not-started — **start here** |
| WL-H — Portable selection overlay | [WL-H-PortableSelection.md](WL-H-PortableSelection.md) | not-started — after WL-G skeleton |
| WL-F follow-up — long-press discoverability affordance + unaided re-test | [WL-F-ConversationUI.md](WL-F-ConversationUI.md) | open finding; implement inside the package post-WL-G |
| WL-D — Live adapter [stretch] | [WL-D-LiveAdapter.md](WL-D-LiveAdapter.md) | not-started; gated; becomes a package `AgentClient` implementation |
| WL-E — Verification | [WL-E-VerificationReview.md](WL-E-VerificationReview.md) | continuous — package unit tests + reference-host scenarios + host-conformance checklist |

### Later — host integration (joint with the friend)

| Line | Status |
|---|---|
| WL-I — Friend's canvas adopts `CanvasHost` | blocked on WL-G API + their branch readiness; joint session, no agent solo work |

### Retired / transferred by the pivot

| Line | Disposition |
|---|---|
| P0, WL-A, WL-B, WL-C | Complete or transferred. WL-A/WL-B live on inside the reference host and their logic moves into the package via WL-G/WL-H. WL-C (persistence) is host-side — the friend's problem space; the package only defines what it asks a host to persist (annotations, threads). WL-C's open notebook acceptance gate applies to the reference host only and no longer blocks anything. |

Dependency shape:

```text
WL-G package skeleton + CanvasHost API
    ├── WL-H portable selection overlay (any-canvas lasso)
    ├── WL-F discoverability follow-up (inside package UI)
    ├── WL-D live AgentClient [gated stretch]
    └── WL-E package tests + reference-host scenarios
              ↓
WL-I friend's canvas conforms to CanvasHost → the actual demo
```

## Session rules

- Every session works **one** child doc. Restate acceptance evidence, files in
  scope, non-goals, and stop point before long work (AGENTS.md).
- Subagents only when Phillip explicitly requests them, and only for lines
  marked subagent-eligible. Integration and merge judgment stay with the
  coordinating agent.
- End each session: update child doc Status + Session log, this board, the
  plan log; Evidence Packet for user-visible changes; push `main` after every
  merged line (the friend syncs through origin).
- Device work: `Docs/DeviceWorkflow.md` (pinned iPad, lock, recover script).
  Verification tiers per `Docs/Development.md` — no default full sweeps.
  Reference-host scenarios remain the runtime proof for package changes.
- Contract/API changes: allowed, `CONTRACT:`-flagged, plan-logged. The
  CanvasHost protocol is THE contract now — changes to it after WL-I starts
  need the friend's ack too.
- Never modify `.cursor/`; never commit generated/runtime files.
- No standalone handoff docs; append here.

## Definition of done (reframed)

1. **`PointBackKit` builds standalone** (SPM, no app target dependency) with
   the recorded agent, Pins, action strip, and conversation sidebar inside it,
   and focused tests green. (WL-G)
2. **Reference host runs entirely through the package**: hero + conversation
   scenarios (`hero-recorded`, `pin-conversation`, `agent-recorded-*`) pass
   unchanged on the pinned iPad. (WL-G / WL-E)
3. **Any-canvas selection works**: the package lasso overlay + host snapshot
   path produces a valid `SelectionArtifact` on the reference host WITHOUT
   using SpatialCanvas's native capture. (WL-H)
4. **Adapter documented**: `CanvasHost` conformance guide with the reference
   host as the worked example, sufficient for the friend to adopt without
   Phillip present. (WL-G)
5. **Long-press discoverability finding closed** by a visible affordance and
   an unaided 2-minute human re-test (also re-exercises screenshot send).
   (WL-F follow-up)
6. **Stretch:** live provider `AgentClient` smoke behind the DEBUG gate.
   (WL-D)

## Plan log

Append one line per meaningful state change: date, line, what changed.

- 2026-07-19 — PLAN created; stale handoffs deleted; all lines `not-started`.
- 2026-07-19 — P0 mechanically accepted on the pinned physical iPad; split
  tooling/live-spike commits landed on `main` and five work-line branches were
  created. Overnight branch cleanup remains blocked by uncommitted edits in its
  linked worktree.
- 2026-07-19 — WL-B step 1 mechanically complete on the pinned physical iPad:
  fixture-backed `LassoState` selection plus Explain / Check / typed Ask action
  strip. WL-B remains `in-progress`; recorded event wiring and real lasso
  integration remain steps 2–3.
- 2026-07-19 — WL-A mechanically accepted and merged to `main` as `a07b5bf`;
  genuine lasso capture/crop passed with retained PDF+ink PNG evidence. The
  complete 11-scenario post-merge sweep passed on the pinned iPad.
- 2026-07-19 — WL-B step 2 mechanically accepted and merged to `main` as
  `81b7444`; all three `agent-recorded-*` scenarios passed. After correcting
  one stale step-1 `hero-recorded` expectation, the complete 14-scenario
  post-merge sweep passed. Step 3 remains pending.
- 2026-07-19 — WL-C persistence-relaunch and external three-page PDF import /
  navigation evidence passed, with no frozen-contract pressure. Final notebook
  create/append/relaunch acceptance and regression sweep stopped after repeated
  device-service/container-copy/install-query timeouts.
- 2026-07-19 — Phillip explicitly directed WL-C to merge despite incomplete
  notebook acceptance. The implementation was reconciled with WL-A/WL-B and
  merged without upgrading WL-C to mechanically accepted; the device blocker
  remains open.
- 2026-07-19 — A focused merged-main WL-C retry exhausted its two allowed
  attempts before build/install: exact wired preflight passed, but Xcode kept
  the pinned iPad in `Device is busy (Connecting to Phillip’s iPad)`. WL-C
  remains in-progress and no new human-review session was started.
- 2026-07-19 — Physical disconnect/reconnect did not clear the Xcode developer
  service blocker. A fresh two-attempt WL-C cycle again stopped before
  build/install with the exact iPad stuck `busy (Connecting)`; acceptance
  remains open.
- 2026-07-19 — Plan restructured into Track N (friend: notebook substrate) and
  Track I (Phillip: intelligence layer). Long-press conversation UI promoted
  into SPEC critical path (WL-F created); contract-change policy softened to
  the `CONTRACT:` flag-and-log rule; Phillip retains all coordination/merges.
- 2026-07-19 — WL-E tooling fix: cross-session device safety. Root cause of the
  recurring `Device is busy (Connecting)` failures was orphaned
  verifier/xcodebuild processes surviving interrupted conversations while new
  sessions started competing runs. Added a PID-liveness device lock to
  `verify-scenario.sh`, contender detection + `--reclaim` to preflight, and
  `DeveloperTools/device-recover.sh`; documented in `Docs/DeviceWorkflow.md`
  §2a. 15 focused tests pass.
- 2026-07-19 — WL-B step 3 mechanically accepted on the pinned iPad. Replaced
  the synthetic recorded hero with the real `SpatialCanvasView` lasso/crop →
  recorded events → page-normalized Pin loop; focused recorded scenarios and
  the complete 14-scenario regression sweep passed. Scenario-contract change:
  `DevelopmentScenarioFixture.IntegrationReadiness` for `hero-recorded` is now
  `app-wired`, and `DevelopmentRuntimeEvidence.SurfaceKind.recordedHeroStub`
  was removed because all recorded scenarios now prove the real spatial
  surface and retained crop. Human hero-quality review remains queued with its
  event bridge armed.
- 2026-07-19 — WL-F scenario-contract addition: added
  `DevelopmentScenario.pinConversation` plus additive
  `DevelopmentRuntimeEvidence` conversation fields so the verifier can prove a
  Pin-tethered recorded follow-up and in-session page-away/page-return survival.
- 2026-07-19 — WL-F mechanically accepted on physical iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`: focused continuation/cancellation
  checks and `pin-conversation`, `hero-recorded`, `agent-recorded-success`, and
  `agent-recorded-failure` all pass. The Pin-anchored thread reuses the real
  hero selection and `recorded-hero` conversation ID, streams a reply through
  the existing event path, and survives page-away/page-return in App-owned
  session state. The non-blocking human journey was not queued because the
  feedback system reported divergent device-slot ownership; existing review
  sessions were left untouched.
- 2026-07-19 — WL-F guided human review completed after Phillip authorized
  clearing the divergent feedback queue. Human result is needs-work: long-press
  was not discoverable, and the completed-investigation Retry card remains
  above and visually competes with the Pin conversation panel. Screenshot
  evidence confirms the App overlay ordering. Suggested direction: a subtle
  Pin shake with a slowly tracing circular outline; no UI fix was made in this
  review-only session.
- 2026-07-20 — WL-F human-review correction in progress. Contract seam:
  `PinOverlayEvent` gained additive `conversationRequested(annotationID:)` so
  `Pins` owns precise hold recognition while `App` retains conversation state.
  The page popup is being replaced by a Pin-tethered right sidebar; screenshot
  submission now encodes captures sequentially and destructive Block actions
  require confirmation after Phillip's screenshot attempt crashed and was
  incorrectly recorded as a human block.
- 2026-07-20 — WL-F correction branch closeout: physical-iPad
  `pin-conversation`, `hero-recorded`, `agent-recorded-success`, and
  `agent-recorded-failure` are green after the Pin-tethered sidebar, mutually
  exclusive tap/hold handling, keyboard-stable canvas, and feedback capture
  safeguards. Phillip accepted composition/feel as "Excellent" directly in
  the originating Codex task; there is no thread-side final verdict. Because
  he could not reliably trigger the final long-press and needed the sidebar
  opened remotely, WL-F remains mechanically accepted with an open
  discoverability finding. Follow-up: add one visible first-expansion
  affordance (not another timing tweak), then run a two-minute unaided re-test
  that also re-exercises screenshot send. The dangling device prompt was
  explicitly resolved before its closed-watch transcript was exported.
- 2026-07-20 — PIVOT: this repo's product is now the standalone PointBackKit
  package (intelligence layer for any Swift canvas); the friend's branch owns
  the notebook substrate. TuberNotes app becomes the reference host. WL-G
  (package extraction + CanvasHost API) and WL-H (portable selection overlay)
  created; WL-A/WL-B/WL-C retired or transferred; DoD reframed around a
  standalone-building package, an unchanged-passing reference host, and a
  host-conformance guide.
- 2026-07-20 — Phillip granted WL-G a free-reshape mandate: smallest-change
  rules suspended for that line; full authority over structure, contracts,
  scenarios, tooling, and docs. Hard rails only: no secrets, honest evidence,
  coherent rollback-able commits, push at the end.
