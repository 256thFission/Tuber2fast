# PC-14 — Favorite color scrub

Status: **implementation complete — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Owner: App integration, using the existing notebook color and favorite-settings
contracts.

## Objective and user-visible outcome

Let the user long-press the working toolbar's color control and slide left or
right through favorited colors, matching the pen tools' hold-and-slide
interaction. A normal tap must continue to open the full color picker.

## Scope

- `TuberNotes/Notebook/NotebookToolbar.swift`
- `DeveloperTools/tests/test_notebook_tool_selection_contract.py`
- this child work-line and the PC-14 parent status/log in `PLAN.md`

## Non-goals

- No favorite-color persistence, palette contents, PencilKit, canvas,
  coordinate, toolbar-order, or shared-contract changes.
- No redesign of the full color picker or notebook settings.

## Work and verification

1. Add a priority hold-then-horizontal-drag gesture to the color button while
   retaining its short-tap popover action.
2. Select the nearest favorited color as the drag crosses each swatch step and
   show a compact live favorite strip above the toolbar during the hold.
3. Keep adaptive-toolbar scrolling disabled only while color scrubbing is
   active and add an adjustable accessibility path through favorites.
4. Run the focused host contracts and diff hygiene.
5. On the explicitly pinned iPad, build and inspect tap, hold, scrub, release,
   clipping, overlap, and favorite selection in the normal notebook path.

## Acceptance evidence and stop conditions

- A short color-button tap still opens the full picker.
- Holding the color button and sliding horizontally selects only favorited
  colors, including the first and last entries, with visible current selection.
- Release dismisses the scrub strip and restores adaptive toolbar scrolling.
- Empty favorites do not start a scrub and leave tap-to-open intact.
- Focused host checks pass and unrelated collaborator edits remain untouched.
- Stop after evidence is collected, after two failed device verifications
  without a narrower fix, or when the exact-device prerequisite is absent.

## Session log

- 2026-07-20 — Started from the existing adaptive-toolbar implementation.
  Confirmed favorite colors already persist in `NotebookSettings` and the color
  button currently supports only tap-to-open. Began the smallest toolbar-only
  hold-and-scrub addition; no shared contract or ownership change is required.
- 2026-07-20 — Added a priority 0.45-second hold followed by horizontal scrub,
  anchored to the current favorite and clamped through the first/last saved
  colors. The live compact indicator shows up to seven nearby swatches and the
  current favorite position; release restores adaptive toolbar scrolling.
  Short tap still routes to the full picker, empty favorites do not start a
  scrub, and VoiceOver adjustable actions traverse the same list. Focused
  toolbar/lasso contracts pass 9/9, all directly affected host contracts pass,
  the 16-start-index boundary simulation passes, and `git diff --check` passes.
  The complete host suite passes 62/63; its sole failure is the already logged
  unrelated verifier-truthfulness fixture supplying 13 arguments to a 19-field
  assertion. Evidence is under
  `tmp/verify/pc-14-favorite-color-scrub/summary.txt`. Xcode build, physical
  launch, tap/scrub inspection, screenshot, console, and crash checks remain
  blocked because this Linux host has no Xcode toolchain, explicit device ID,
  or pinned iPad session.
