# PC-8 — Drawing tool recovery after erasing

Status: **implemented — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Owner: Notebook toolbar integration, preserving `SpatialCanvas`/PencilKit tool
ownership.

## Objective and user-visible outcome

After the eraser becomes active through either the toolbar or the configured
Apple Pencil shortcut, a tap on Pen, Pencil, or Highlighter must immediately
restore that drawing tool. The existing hold-then-drag width control must keep
priority over horizontal toolbar scrolling.

## Scope

- `TuberNotes/Notebook/NotebookToolbar.swift`
- one focused host contract check for the toolbar gesture composition
- this child plan and the PC-8 parent status entry

## Non-goals and dependencies

- No changes to `WritingTool`, PencilKit tool construction, canvas coordinates,
  persisted notebook data, Apple Pencil system-action preferences, toolbar
  layout, or subsystem ownership.
- Authentic Pencil feel and physical tap behavior require an explicitly pinned
  iPad; this Linux workspace currently has neither Xcode nor a pinned session.

## Work and verification

1. Keep the width-adjustment long press high priority so it continues to win
   over the toolbar's horizontal scrolling gesture.
2. Add a simultaneous tap recognizer that shares the same idempotent selection
   action as the button, ensuring a short tap is not lost to the long press.
3. Add one narrow host check that preserves both sides of that gesture contract.
4. Run the focused check and diff hygiene, then use `blank-canvas` and the
   normal notebook writing path on the explicitly pinned physical iPad when
   the Apple/device prerequisite is available.

## Acceptance evidence and stop conditions

- Eraser → Pen, Eraser → Pencil, and Eraser → Highlighter all update the active
  toolbar selection and PencilKit canvas tool on one tap.
- Width hold-and-drag remains reachable and horizontal toolbar scrolling does
  not activate a tool accidentally.
- Host checks and final diff inspection pass without touching concurrent PC-7
  work.
- Stop after evidence is collected, after two failed device verifications
  without a narrower diagnosis, or at the unavailable exact-device boundary.

## Session log

- 2026-07-20 — Diagnosed the regression at `1e75dfe`: the model's
  `selectTool` transition already supports leaving the eraser, while the main
  toolbar composes every tool `Button` with a high-priority sequenced long-press
  gesture. That gesture was introduced to protect width adjustment from the
  horizontal `ScrollView`, but can suppress the short button tap. No Xcode or
  `.tubernotes-device-session.json` is available on this host, so device proof
  is explicitly deferred until after the bounded host repair.
- 2026-07-20 — Routed the button action and a simultaneous short-tap recognizer
  through one idempotent `activateToolbarTool` helper while retaining the
  high-priority width gesture unchanged. Added one focused source contract that
  requires both gesture paths. That check plus the four nearby notebook/Pencil
  checks pass (5/5), `git diff --check` passes, and the PC-8 diff is limited to
  the toolbar selection block, focused test, and PC-8 plan entries. Evidence:
  `tmp/verify/pc-8-drawing-tool-recovery/host-checks.txt`. Concurrent PC-7
  changes, including its edits elsewhere in `NotebookToolbar`, were preserved.
  Canonical build, `blank-canvas`, normal notebook eraser-to-drawing taps,
  screenshot, console/crash checks, and Pencil interaction judgment remain
  blocked because this Linux host has no `xcodebuild` or explicitly pinned iPad
  session.
