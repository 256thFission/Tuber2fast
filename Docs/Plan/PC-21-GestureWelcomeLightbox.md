# PC-21 — Gesture welcome lightbox

Status: **implementation complete — host-checked; Release/device verification blocked**

Target branch: `sive/dev`

Owner: App/Notebook presentation. Existing Pencil, canvas, toolbar, page-turn,
lasso, spatial, and persistence behavior remains owned by its current subsystem.

## Objective and user-visible outcome

Give first-time users a calm welcome lightbox that explains the normal app's
gesture system before they begin writing. The guide appears once, can be
dismissed directly, and remains available from a Help button in the library.

## Scope

- `TuberNotes/Notebook/LibraryView.swift`
- one new Notebook-owned SwiftUI lightbox view
- `TuberNotes.xcodeproj/project.pbxproj`
- this child plan and the PC-21 entry in `Docs/Plan/PLAN.md`

## Non-goals and dependencies

- No changes to PencilKit, gesture recognizers, coordinates, page navigation,
  lasso geometry, toolbar interactions, notebook data, archives, or credentials.
- No Debug scenario, recorded route, fixture UI, or behavioral acceptance
  evidence.
- The copy must describe only gestures that exist in the normal Release app;
  visual taste and gesture discoverability remain Phillip's judgment.

## Work and verification

1. Present an accessible first-launch lightbox over the normal library and
   persist only its dismissed/not-dismissed state.
2. Explain writing and straightening, pinch/pan, directional page turns and
   end-pull creation, hold-and-slide toolbar controls, lasso actions, and
   supported Apple Pencil shortcuts.
3. Add an always-available library Help action that reopens the guide without
   resetting its first-launch state.
4. Run source/project-membership and diff hygiene checks, then perform a fresh
   signed Release build, install, and normal launch on the explicitly pinned
   iPad when available.
5. Mechanically inspect initial presentation, dismissal, reopening, clipping,
   overlap, accessibility labels, and immediate crash/exit state.

## Acceptance evidence and stop conditions

- A fresh first launch presents one readable gesture guide above the library.
- Every described gesture matches reachable normal-app behavior and supported
  hardware is qualified where needed.
- Close and primary actions dismiss the guide; later launches do not reopen it
  automatically; the library Help action always reopens it.
- The lightbox remains scrollable at large Dynamic Type and its primary action
  stays reachable in portrait and landscape.
- The final diff stays within PC-21 and preserves all existing collaborator
  edits.
- Stop after Release delivery and mechanical inspection, when the named iPad
  is unavailable, or after two verification failures without a narrower fix.

## Session log

- 2026-07-21 — Traced the shipping gesture system through `NotebookCanvas`,
  `NotebookView`, `NotebookToolbar`, and the PC-5/PC-14/PC-15 work lines. Began
  an App/Notebook presentation-only implementation; no gesture or shared
  contract change is required. Existing PC-20 and collaborator-owned notebook
  edits are preserved and outside this line.
- 2026-07-21 — Added a first-run, versioned-dismissal gesture lightbox over the
  normal library with six contract-matched cards, direct close/background/
  primary dismissal, reduced-motion handling, a scrollable adaptive layout,
  modal input/accessibility isolation, and an always-available library Help
  action. The new Swift file has one project reference and one Sources entry.
  The focused source check and `git diff --check` pass. Nineteen of twenty
  nearby gesture contracts pass; the one failure is an existing/current-
  worktree refinement-lasso assertion against `NotebookView`, which PC-21 does
  not touch. Evidence is under
  `tmp/verify/pc-21-gesture-welcome-lightbox/summary.txt`.
- 2026-07-21 — Canonical Release build, install, normal launch, screenshot,
  console/crash collection, and mechanical portrait/landscape/Dynamic Type
  inspection are blocked: this Linux host has no Xcode/Swift toolchain,
  `.tubernotes-device-session.json`, or explicitly pinned iPad. Phillip's
  gesture-discoverability and visual-taste verdict remains open.
