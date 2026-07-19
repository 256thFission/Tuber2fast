# TuberNotes — Execution Plan (parent doc)

This is the single long-running coordination document. It replaces all prior
handoffs (`M0V2*`, `FeedbackThreads*`, `OpenCodeAuthReproduction` handoffs —
deleted July 19, 2026). One work line = one child doc = one bounded task.

Authority chain: `SPEC.md` (frozen product contracts) → `AGENTS.md` (operating
contract) → this plan (current execution) → child docs (per-line detail).

## Decisions locked (Phillip, July 19, 2026)

1. **Horizon:** ~1 week+ to demo-ready.
2. **Demo agent:** deterministic **recorded** agent on stage (M1 loop). Live
   provider (M2) is a gated stretch, never a demo dependency.
3. **Live-provider spike is retained** (`DebugCodex*`, `ResponsesSSEDecoder`,
   `CodexAdapterTests`, `OpenCodeAuthReproduction`) and becomes WL-D, behind
   the `AgentClient` protocol. It must never leak into the M1 path.
4. **Persistence/relaunch, PDF import, and notebook creation are in scope.**
5. The only pre-approved shared-contract addition is the
   `persistence-relaunch` scenario name (see WL-C). Everything else escalates.

## Status board

Update the Status column and the log below when a work line changes state.
States: `not-started` → `in-progress` → `mechanically-accepted` →
`human-accepted`. Blockers get named inline.

| Line | Child doc | Owner subsystem | Depends on | Status |
|---|---|---|---|---|
| P0 — Stabilize tree | [Phase0-Stabilize.md](Phase0-Stabilize.md) | coordinator | — | in-progress — mechanically accepted; overnight branch cleanup blocked by linked-worktree edits |
| WL-A — Lasso capture + crop | [WL-A-LassoCrop.md](WL-A-LassoCrop.md) | SpatialCanvas | P0 | mechanically-accepted — merged; human Pencil review queued |
| WL-B — Investigation UI | [WL-B-InvestigationUI.md](WL-B-InvestigationUI.md) | App | P0 (step 3 needs WL-A) | in-progress — steps 1–2 mechanically complete and merged; step 3 pending |
| WL-C — Documents + persistence | [WL-C-DocumentsPersistence.md](WL-C-DocumentsPersistence.md) | App + DeveloperSupport | P0 | in-progress — implementation merged by direction; notebook acceptance blocked by device-service timeouts |
| WL-D — Live adapter [stretch] | [WL-D-LiveAdapter.md](WL-D-LiveAdapter.md) | AgentHarness | P0; gated | not-started |
| WL-E — Verification + review | [WL-E-VerificationReview.md](WL-E-VerificationReview.md) | DeveloperTools | continuous | not-started |

Dependency shape:

```text
P0 (coordinator)
    ├── WL-A ──┐
    ├── WL-B ──┴─→ M1 deterministic point-back loop (demo core)
    ├── WL-C ────→ repeatable/persistent demo
    ├── WL-D ────→ M2 live flex (only if everything else is green)
    └── WL-E ────→ truthful scenarios + human review → M4 demo candidate
```

Merge order into `main`: P0 → (WL-A, WL-C in any order) → WL-B steps as they
complete → WL-E scenario updates ride with the line that changes behavior →
WL-D last, only if green.

## Session rules

- Every session works **one** child doc. Before long-running work, restate its
  acceptance evidence, files in scope, non-goals, and stop point (AGENTS.md).
- Subagents only when Phillip explicitly requests them, and only for WL-A,
  WL-C, or WL-D — each stays inside one subsystem with a concrete return
  contract. WL-B and all integration/merge judgment stay with the coordinator.
  Never give a subagent work spanning two lines.
- End each session by: updating the child doc's Status + Session log,
  updating the status board row here, and producing an Evidence Packet
  (`Docs/templates/EvidencePacket.md`) for user-visible changes.
- Device work follows `Docs/DeviceWorkflow.md` (pin one iPad, verify, never
  simulator-fallback) and the human-review session contract in `AGENTS.md`.
- Frozen contracts (`TuberNotes/App/Contracts/`, scenario names/semantics,
  architecture ownership) stop the line and escalate to Phillip.
- Never modify `.cursor/`; never commit `__pycache__/`, `DerivedData*/`,
  `tmp/`, or `.tubernotes-device-session.json`.

## Definition of done for the week

1. **M1 gate passes** (SPEC §16) on the demo iPad: real lasso → crop → Check →
   recorded events → real Pins; Retry without redraw; cancel/invalid output
   safe. (WL-A + WL-B)
2. **Repeatable demo state:** import or create a document, draw, get Pins,
   relaunch — everything restored. (WL-C)
3. **All runnable scenarios PASS** with rendered-runtime evidence; no scenario
   claims more readiness than it has. (WL-E)
4. **Human sign-off** on Pencil feel, spatial taste, hero timing via
   human-device-loop. (WL-E / M4 gate)
5. **Stretch, only if 1–4 green:** one live provider hero run behind the DEBUG
   gate. (WL-D)

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
