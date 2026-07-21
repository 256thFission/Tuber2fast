# PC-15 — End-pull page creation

Status: **implementation complete — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Owner: App/Notebook integration; `SpatialCanvas` retains ownership of Pencil,
page coordinates, zoom, and within-page panning.

## Objective and user-visible outcome

On the final notebook page, continuing the configured page-navigation gesture
forward reveals a compact progress indicator. Holding past a short threshold
adds exactly one new page; releasing or moving back early cancels.

## Scope

- `TuberNotes/Notebook/NotebookView.swift`
- one focused source regression check under `DeveloperTools/tests/`
- this child work-line and the PC-15 parent status/log in `PLAN.md`

## Non-goals

- No page model, persistence, template, spatial-coordinate, Pencil, zoom/pan,
  toolbar, or settings-contract changes.
- No continuous multi-page canvas or replacement of the existing add-page
  buttons.

## Work and verification

1. Extend the existing axis-aware page-turn state with a final-page forward
   hold, cancellation, and one-add-per-gesture latch.
2. Show progress at the configured forward edge without intercepting touches.
3. Reuse `NotebookViewModel.addPage()` and the existing page-turn animation.
4. Run the focused source check, nearby notebook checks, and diff hygiene.
5. On the explicitly pinned iPad, run `blank-notebook` and `notebook-pages`,
   then inspect complete/cancel paths in both scroll directions.

## Acceptance evidence and stop conditions

- The indicator appears only after a deliberate forward pull on the last page.
- Holding for 0.7 seconds adds exactly one page and shows the new page.
- Releasing or reversing early dismisses the indicator without adding a page.
- One continuous gesture cannot add multiple pages.
- Existing forward/back turns, explicit add buttons, zoom/pan, Pencil, and page
  identity behavior remain unchanged.
- Stop after evidence is collected, when the exact-device prerequisite is
  unavailable, or after two device failures without a narrower repair.

## Session log

- 2026-07-21 — Traced the current axis-aware `NotebookCanvas` pan into
  `NotebookView`'s interactive page-turn state and confirmed page insertion is
  already App-owned by `NotebookViewModel.addPage()`. Began the smallest
  view-state-only extension; no shared contract or ownership change is planned.
- 2026-07-21 — Added a 72-point final-page forward-pull threshold, a 0.7-second
  visible progress hold, early-release/reversal cancellation, success feedback,
  the existing animated `addPage()` path, and a one-add-per-finger-gesture latch
  that also ignores late drag updates until release. The indicator follows the
  selected Horizontal/Vertical forward edge and does not intercept input. The
  10 focused/nearby notebook checks pass; the complete host suite passes 65/66
  with only the previously logged unrelated verifier-truthfulness fixture
  mismatch (19 expected arguments, 13 supplied). Python syntax and diff hygiene
  pass. Evidence is under `tmp/verify/pc-15-end-pull-add-page/summary.txt`.
  Xcode build, `blank-notebook`, `notebook-pages`, physical interaction,
  screenshots, console, and crash checks remain blocked because this host has
  no Xcode toolchain or configured physical-iPad session.
