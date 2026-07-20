# WL-H — Portable selection overlay (any-canvas lasso)

Status: not-started — after WL-G step 3
Owner: `PointBackKit/Sources/PointBackKit/` (Host/ + Investigation/)
Subagent-eligible: yes once the WL-G API is settled.

## Objective

The package owns the Magic Lasso gesture so ANY conforming host gets the hero
interaction without implementing capture:

- lasso tool mode overlay (explicit mode, never inferred from ink) drawn over
  the host view; near-closed path completion; degenerate-path rejection —
  reusing the proven WL-A logic, relocated behind the package boundary;
- selection glow/lift rendering in view space, tracking host viewport events;
- crop production via `CanvasHost.snapshot(_:on:)` → `SelectionArtifact`,
  identical downstream shape to the reference host's native capture;
- host chooses per-mount: native capture (inject `SelectionArtifact`) or
  package overlay. Both feed the same investigation flow.

## Acceptance evidence

- Reference host runs the full hero loop **via the package overlay + snapshot
  path with SpatialCanvas native capture disabled** — proving a host that has
  no capture code still gets lasso → crop → Check → Pins.
- `lasso-crop` scenario (or a new `portable-lasso` scenario if expectations
  diverge — CONTRACT-flag the addition) passes with a retained crop PNG
  containing background AND ink.
- Degenerate/early-cancel paths leave host state untouched.
- Package unit tests for path closing/rejection geometry.
- Evidence Packet; queue one human Pencil-feel check of the overlay gesture
  via `human-device-loop` (non-blocking).

## Non-goals

- Changing SpatialCanvas; changing crop semantics; conversation/Pin visuals;
  friend's branch.

## Stop conditions

- Evidence collected → stop.
- Snapshot API proves insufficient for a real host (e.g. can't compose ink) →
  that's an adapter design flaw: stop, redesign with Phillip before code.
- Two verification failures → stop, report.

## Session log

- (none yet)
