# PC-2 — Adaptive notebook toolbars

Status: **follow-up implemented — host-checked; awaiting pinned-iPad verification**

Target branch: `sive/dev`

Owner: App integration, preserving `SpatialCanvas` ownership of Pencil and
coordinate behavior.

## Objective and user-visible outcome

Keep notebook working controls proportional and stable. In the current
follow-up, the drawing-refinement lasso bubble stays immediately above its
Magic Lasso toolbar button instead of moving with the page/canvas overlay.

## Scope

- `TuberNotes/Notebook/NotebookToolbar.swift`
- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/SpatialCanvas/DrawingRefinementOverlay.swift`
- `DeveloperTools/tests/test_notebook_tool_selection_contract.py`
- this child work-line and the PC-2 parent status/log in `PLAN.md`

## Non-goals

- No PencilKit gesture, selection-coordinate, refinement-service, persisted
  notebook, or toolbar-order changes.
- No broader toolbar redesign or subsystem ownership change.

## Acceptance evidence

- The refinement lasso bubble resolves the Magic Lasso button's live toolbar
  bounds and stays centered immediately above it.
- Canvas zoom, pan, or page movement cannot reposition the bubble.
- Starting a refinement lasso still clears the prior refinement preview and
  retains page-normalized selection behavior in `SpatialCanvas`.
- Host source-contract tests and diff hygiene pass.
- Canonical build/launch and mechanical wide/compact visual checks run on the
  explicitly pinned physical iPad when that prerequisite is available.

## Session log

- 2026-07-20 — Moved only the refinement control chrome out of the canvas
  overlay and into a toolbar anchor-preference overlay. Lifted its active flag
  through `NotebookView`; selection capture and normalized geometry remain in
  `DrawingRefinementOverlay`. All 20 focused host contract tests and diff
  hygiene pass; evidence is under
  `tmp/verify/pc-2-refinement-lasso-anchor/summary.txt`. Physical-device
  verification remains blocked on this Linux host.
