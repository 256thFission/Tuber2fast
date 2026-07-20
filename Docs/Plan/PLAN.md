# TuberNotes — Execution Plan (parent doc)

This is the single long-running coordination document. One work line = one
child doc = one bounded task.

Authority chain: `SPEC.md` (product contracts) → `AGENTS.md` (operating
contract) → this plan (current execution) → child docs (per-line detail).

## Decisions locked (Phillip, July 19, 2026)

1. **Horizon:** ~1 week+ to demo-ready.
2. **Demo agent:** deterministic **recorded** agent on stage (M1 loop). Live
   provider (M2) is a gated stretch, never a demo dependency.
3. **Live-provider spike is retained** and becomes WL-D, behind the
   `AgentClient` protocol. It must never leak into the M1 path.
4. **Persistence/relaunch, PDF import, and notebook creation are in scope.**
5. **Two-human split:** Phillip's friend owns the **notebook substrate**
   (Track N: SpatialCanvas, documents, ink, persistence, Pin projection).
   Phillip owns the **intelligence layer** (Track I: AgentHarness, Knowledge,
   investigation/conversation UI). **Phillip keeps coordination**: merges to
   `main`, `RootView.swift` integration, and final judgment. Track N never
   edits `RootView.swift` or Track I subsystems, and vice versa.
6. **Long-press Pin conversation UI is promoted into the main spec**
   (SPEC §1 Confirmed #11) — it is Track I's headline deliverable after M1.
7. **Contracts are soft:** any agent may change `TuberNotes/App/Contracts/`
   or scenario contracts when the work requires it, without stopping.
   Every contract-touching commit carries a `CONTRACT:` prefix and a plan-log
   entry here naming the changed type and why. Phillip reviews after the fact
   and rolls back if needed. Architecture-*ownership* changes still need
   Phillip first.

## Status board

States: `not-started` → `in-progress` → `mechanically-accepted` →
`human-accepted`. Blockers get named inline.

### Coordination (Phillip)

| Line | Child doc | Status |
|---|---|---|
| P0 — Stabilize tree | [Phase0-Stabilize.md](Phase0-Stabilize.md) | mechanically accepted; overnight-branch cleanup deferred (ignored by direction) |

### Track N — Notebook substrate (friend)

| Line | Child doc | Owner subsystem | Status |
|---|---|---|---|
| WL-A — Lasso capture + crop | [WL-A-LassoCrop.md](WL-A-LassoCrop.md) | SpatialCanvas | mechanically-accepted — merged; human Pencil review queued |
| WL-C — Documents + persistence | [WL-C-DocumentsPersistence.md](WL-C-DocumentsPersistence.md) | App(Persistence) + DeveloperSupport | in-progress — merged by direction; notebook acceptance blocked by device-service timeouts |
| WL-E(N) — Notebook device reviews | [WL-E-VerificationReview.md](WL-E-VerificationReview.md) §Track N | DeveloperTools | not-started |

### Track I — Intelligence layer (Phillip)

| Line | Child doc | Owner subsystem | Status |
|---|---|---|---|
| WL-B — Investigation UI | [WL-B-InvestigationUI.md](WL-B-InvestigationUI.md) | App | mechanically-accepted — M1 real lasso-to-recorded-Pin loop complete; human hero review queued |
| WL-F — Conversation UI | [WL-F-ConversationUI.md](WL-F-ConversationUI.md) | App + AgentHarness | mechanically-accepted — human needs-work: long-press undiscoverable and stale Retry card z-fights the thread panel |
| WL-D — Live adapter [stretch] | [WL-D-LiveAdapter.md](WL-D-LiveAdapter.md) | AgentHarness | not-started; gated |
| WL-E(I) — Agent-side verification | [WL-E-VerificationReview.md](WL-E-VerificationReview.md) §Track I | DeveloperTools | not-started |

Dependency shape:

```text
Track N (friend)              Track I (Phillip)
  WL-A ✓ ────────────────────→ WL-B step 3 → M1 demo core
  WL-C (device gate) ─→ repeatable demo      │
                                             ├→ WL-F conversation UI
                                             └→ WL-D live flex [gated]
  Contracts (TuberNotes/App/Contracts/) are the interface.
  WL-E rides both tracks → truthful scenarios + human review → M4
```

Merge policy: **Phillip merges everything.** Track N delivers branches/PRs
against the contracts; a line merges when its device-verified evidence bar
passes — a device outage pauses the merge, it doesn't waive the gate (WL-C's
pending notebook acceptance is the standing exception, by explicit direction,
and gates further Track N merges until cleared).

## Session rules

- Every session works **one** child doc. Before long-running work, restate its
  acceptance evidence, files in scope, non-goals, and stop point (AGENTS.md).
- Subagents only when Phillip explicitly requests them, and only for lines
  marked subagent-eligible. Integration and merge judgment stay with the
  coordinating agent.
- End each session by: updating the child doc's Status + Session log, the
  status board here, and an Evidence Packet for user-visible changes.
- Device work follows `Docs/DeviceWorkflow.md` — one pinned iPad, sessions
  serialize device access across BOTH tracks; never simulator-fallback.
- Verification is tiered (`Docs/Development.md` § Verification tiers): per-edit
  runs use only the change-map scenarios; the last plan-logged green sweep at
  the current commit is the baseline — do not re-sweep before editing. Full
  sweeps are reserved for tooling changes, multi-line merge days, and the M4
  gate.
- Push `main` to origin after every merged work line — Track N and Track I
  sync through origin, not through this Mac.
- Contract changes: allowed, `CONTRACT:`-flagged, plan-logged (decision 7).
- Never modify `.cursor/`; never commit `__pycache__/`, `DerivedData*/`,
  `tmp/`, or `.tubernotes-device-session.json`.
- Do not create standalone handoff docs; append here.

## Definition of done for the week

1. **M1 gate passes** (SPEC §16) on the demo iPad: real lasso → crop → Check →
   recorded events → real Pins; Retry without redraw; cancel/invalid safe.
   (WL-A ✓ + WL-B step 3)
2. **Repeatable demo state:** create/import, draw, get Pins, relaunch —
   everything restored. (WL-C, pending device gate)
3. **Conversation:** long-press an existing Pin → follow-up turn reusing the
   retained selection → threaded reply renders. (WL-F)
4. **All runnable scenarios PASS** with rendered-runtime evidence; no
   scenario overstates readiness. (WL-E)
5. **Human sign-off** on Pencil feel, spatial taste, hero + conversation
   timing via human-device-loop. (WL-E / M4 gate)
6. **Stretch, only if 1–5 green:** one live provider hero run behind the
   DEBUG gate. (WL-D)

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
