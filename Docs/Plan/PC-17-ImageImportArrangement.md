# PC-17 — Image import arrangement

Status: **implemented — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Owner: App/Notebook owns import presentation and document persistence;
`SpatialCanvas` owns image gestures and page-relative placement.

## Objective and user-visible outcome

Let imported images rotate while they are being arranged, and offer an
at-import option that removes a photo's background before placing it on the
page.

## Scope

- `TuberNotes/Notebook/Notebook.swift`
- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/Notebook/NotebookViewModel.swift`
- `TuberNotes/Notebook/NotebookCanvas.swift`
- one focused source regression check under `DeveloperTools/tests/`
- this child work-line and the PC-17 parent status/log in `PLAN.md`

## Non-goals

- No drawing-refinement backend or product-agent contract change.
- No per-subject selection, crop editor, image-layer coordinate rewrite, or
  recompression of ordinary imports. Transparent-background imports may be
  bounded to a demo-safe pixel dimension before their required PNG encoding.
- No Pencil input, drawing, Pin, conversation, or page-navigation change.

## Work and verification

1. Persist a backward-compatible rotation angle on `PlacedImage` and render it
   consistently on canvas, thumbnails, selection snapshots, and PDF workspace
   backgrounds.
2. Add free two-finger rotation plus a visible clockwise 90-degree action while
   arranging the selected image.
3. Insert an import-options sheet after photo selection with an off-by-default
   transparent-background toggle.
4. Use iOS 17 Vision foreground-instance masking off the main thread and keep
   the original import available when no subject can be isolated.
5. Run focused and nearby host checks plus diff hygiene; then run
   `blank-notebook` and `notebook-pages` on the explicitly pinned iPad.

## Acceptance evidence and stop conditions

- Existing notes decode absent rotation as zero; a changed angle survives save
  and reload.
- Twist and Rotate update the same selected image, while move and pinch continue
  to work.
- Rotation appears consistently in the page, thumbnail, AI selection artifact,
  and opt-in PDF workspace background.
- Transparent-background import preserves all detected foreground subjects as
  PNG alpha, communicates progress/failure, and does not contact a backend.
- Stop after evidence is collected, when the exact-device prerequisite is
  unavailable, or after two verification failures without a narrower fix.

## Session log

- 2026-07-21 — Traced imported images from `PhotosPicker` through
  `PlacedImage`, `ImageLayerView`, thumbnails, selection snapshots, and PDF
  background export. Confirmed current arrangement supports only pan and pinch
  and current import places original bytes immediately. Began the smallest
  rotation plus on-device foreground-mask path; no refinement-backend contract
  change is required.
- 2026-07-21 — Added backward-compatible persisted rotation, a simultaneous
  two-finger rotation recognizer, a visible clockwise Rotate action, and
  rotation-aware canvas hit testing and composition for thumbnails, selection
  snapshots, and PDF workspace backgrounds. Photo selection now opens a compact
  import sheet with an off-by-default transparent-background option; iOS 17
  Vision preserves all detected foreground instances as PNG alpha on a
  background queue and reports no-subject or render failures without placing a
  bad image. Focused and nearby image/notebook/export checks pass 28/28;
  `git diff --check` passes. The complete host suite passes 70/71, with only the
  previously logged unrelated verifier-truthfulness fixture mismatch (19
  expected runtime fields, 13 supplied). Evidence is under
  `tmp/verify/pc-17-image-import-arrangement/summary.txt`. Canonical Xcode
  build, `blank-notebook`, `notebook-pages`, screenshots, console/crash
  collection, transparent-edge inspection, and physical twist quality remain
  blocked because this Linux host has no Xcode toolchain or pinned iPad
  session.
- 2026-07-21 — Stability follow-up: completed transforms now bypass the drawing
  debounce and persist immediately; pan, pinch, and twist constrain transformed
  views so an image cannot become unreachable; simultaneous transforms still
  commit only after the final recognizer ends; and button rotation normalizes
  its angle. Import work is identity-guarded and cancellation-aware so a late
  Vision result cannot mutate a closed or replaced import. The foreground
  worker now reuses one thread-safe `CIContext`, applies source orientation
  metadata, and bounds the longest processed dimension to 2,560 pixels before
  PNG encoding to control peak memory and notebook payload growth. Strengthened
  focused/nearby checks pass 30/30; the complete host suite passes 72/73 with
  only the previously logged unrelated 13-versus-19-field verifier fixture
  failure. Diff hygiene passes. Device verification remains blocked by the same
  unavailable Xcode/pinned-iPad prerequisite.

Shared-contract log — 2026-07-21: `CONTRACT:` extend persisted `PlacedImage`
with `rotationRadians` so canvas arrangement survives save, reload, archive,
and export. Missing values decode as zero; image bytes, normalized rects, page
coordinates, and archive version are unchanged.
