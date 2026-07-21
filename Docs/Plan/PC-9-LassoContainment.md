# PC-9 — Drawing-refinement lasso containment

Status: **mechanically accepted — ready to merge**

Target branch: `phil/lasso-containment`

Owner: `SpatialCanvas` owns lasso geometry; `Notebook` owns applying the
refinement to persisted page drawing state.

## Objective and user-visible outcome

Applying drawing refinement removes only strokes fully enclosed by the user's
closed lasso. Strokes that merely cross or graze the selection remain intact.

## Scope

- `TuberNotes/SpatialCanvas/LassoGeometry.swift`
- `TuberNotes/SpatialCanvas/DrawingRefinementOverlay.swift`
- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/Notebook/NotebookViewModel.swift`
- `TuberNotes.xcodeproj/project.pbxproj`
- `DeveloperTools/tests/test_lasso_containment_contract.py`
- this child plan and the PC-9 parent status entry

## Non-goals and dependencies

- No change to Pencil capture, drawing-refinement providers, image placement,
  persisted archive types, Pins, or Agentic Layers.
- No shared-contract or architecture-ownership change.
- Apple Pencil feel and freehand interaction quality remain human-only checks.

## Work and verification

1. Preserve a valid closed lasso polygon in page-normalized coordinates.
2. Delete only strokes whose transformed points are all inside that polygon;
   keep a containment-based rectangle fallback for non-lasso selections.
3. Add a focused source contract test for the containment behavior.
4. Build, install, and launch the `lasso-crop` scenario on the pinned physical
   iPad; inspect the retained crop artifact.
5. Inspect the final diff and exclude unrelated local files.

## Acceptance evidence and stop conditions

- Focused lasso-containment contract tests pass.
- `lasso-crop` passes physical-device build/install/launch and nonce-matched
  runtime/crop assertions.
- The retained crop contains the expected PDF and ink content without visible
  clipping or corruption.
- Stop after evidence is collected, after two failed device runs without a
  narrower repair, or if a shared contract or architecture change is needed.

## Session log

- 2026-07-20 — Implemented deterministic closed-path validation and point-in-
  polygon containment, passed the exact lasso path through refinement apply,
  and changed stroke removal from region intersection to full containment.
  `python3 -m unittest DeveloperTools.tests.test_lasso_containment_contract`
  passed 3 tests. Exact physical iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` passed preflight and the `lasso-crop`
  verifier. Build, install, launch, scenario marker, runtime evidence, and crop
  assertions passed under `tmp/verify/20260720-190651-lasso-crop/`. The crop
  was mechanically inspected and contains the expected ruled PDF content.
  Physical screenshot, attached console, crash diagnostics, Apple Pencil feel,
  and visual-taste review were not collected. `.claude/settings.json` remains
  excluded as unrelated local state.
