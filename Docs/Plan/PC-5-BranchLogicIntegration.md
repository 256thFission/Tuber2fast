# PC-5 — Branch logic integration

Status: **implementation complete — host-checked; physical visual verification blocked**

Target branch: `sive/dev`

Owner: App integration coordinates the port; `SpatialCanvas` retains Pencil
and coordinate behavior; Notebook owns its current models, templates, and
normal-use composition.

## Objective and user-visible outcome

Adapt the behavior from `origin/feat/pencil-pro-compat` and the latest
available `origin/claire/bleh` into the current integrated product without
merging their histories or replacing newer implementations. Preserve the
current zoom, export, toolbar, persistence, and archive repairs while adding
only behavior that is still absent.

Expected user-visible outcomes are Apple Pencil Pro shortcut interactions that
fit the current tool/state model, plus Claire's current ripple, scrolling, and
page-template improvements where they remain applicable.

## Scope

- `TuberNotes/Notebook/Notebook.swift`
- `TuberNotes/Notebook/NotebookCanvas.swift`
- `TuberNotes/Notebook/NotebookToolbar.swift`
- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/Notebook/NotebookViewModel.swift`
- `TuberNotes/Notebook/AmbientBackground.swift`
- `TuberNotes/Notebook/PageTemplate.swift`
- new narrowly scoped Notebook support files only when the source behavior
  cannot fit an existing owner cleanly
- Xcode project membership only for any required new source files
- `DeveloperTools/tests/test_notebook_branch_logic_contract.py`
- this child plan and the PC-5 parent status entry

## Non-goals and dependencies

- No Git merge, history transplant, wholesale file replacement, or attempt to
  make current files byte-identical to either source branch.
- No persisted coordinate, page identity, archive, Pin, or subsystem ownership
  contract rewrites. The additive dotted-paper cases extend the persisted
  `PageTemplate` enum and are explicitly flagged under the shared-contract rule.
- No reversion of current zoom, export, toolbar, or visual-repair behavior.
- No local signing-team configuration unless it is required for product logic;
  signing convenience commits are not part of this port.
- Physical build, Pencil Pro gestures, animation feel, and visual inspection
  depend on an explicitly named, pinned iPad on an Apple host.

## Work and verification

1. Compare the source-branch behavior commits against current equivalents and
   classify each delta as already integrated, obsolete, or still applicable.
2. Port the smallest compatible Pencil Pro, ripple/scrolling, and template
   logic while retaining current state and coordinate ownership.
3. Check project membership, references, focused host-safe contracts, and
   `git diff --check`; inspect the final diff for branch-era regressions.
4. On the pinned iPad, run `blank-canvas`, `blank-notebook`,
   `notebook-pages`, and `pin-drift` as applicable, then inspect squeeze/
   double-tap behavior, scrolling, ripple animation, clipping, overlap, and
   spatial stability.
5. Use a human Pencil review only for authentic Pencil feel and gesture/
   animation quality after mechanical device verification succeeds.

## Acceptance evidence and stop conditions

- Useful source-branch behavior is represented through current models and
  views; obsolete duplicate implementations are not reintroduced.
- Pencil input does not persist view coordinates or compete with active canvas
  gestures; page-normalized spatial content remains stable.
- Current zoom/export/toolbar/persistence behavior and project membership stay
  intact.
- Host checks pass and all unavailable device/human checks are named honestly.
- Stop after evidence is collected, after two failed verification attempts
  without a narrower diagnosis, at an architecture-ownership boundary, or
  when the exact-device prerequisite is absent.

## Session log

- 2026-07-20 — Started from clean `sive/dev` at `69efea9`. The source branches
  forked before most of the current integrated history, so the user clarified
  that only their logic should be adapted. The local `claire/bleh` ref is two
  commits behind its remote; this work line uses the latest available remote
  tip and will classify deltas before editing product code.
- 2026-07-20 — Delta classification complete. Port: Pencil double-tap/squeeze,
  hover preview, contextual palette, per-layer undo/redo, passive Pencil-only
  ripple trail, interactive finger page turns, and dotted paper. Preserve the
  current synchronized zoom implementation and overlay-style sidebar; omit the
  source branches' superseded zoom synchronization, sidebar shift, signing
  configuration, and wholesale project-file layout. `CONTRACT:` extend the
  persisted `PageTemplate` enum with `dottedLarge`, `dottedMedium`, and
  `dottedSmall` so the branch's dotted-paper behavior can round-trip normally.
- 2026-07-20 — Adapted the selected behavior to the current code. Pencil
  preferences use app-local settings instead of changing `NotebookSettings`;
  undo/redo follows the active drawing layer; Pencil Pro callbacks retain an
  iOS 17.0 double-tap fallback while 17.5+ receives location-aware tap/squeeze
  objects. The page-space hover preview stays inside the zooming content, and
  interactive page turn offsets the complete canvas/overlay composition while
  leaving the current `applyBoundZoomScale` ownership intact. Added the passive
  Pencil-only ripple trail and three dotted templates. All three new source
  files have one project reference and one Sources entry.
- 2026-07-20 — Eight focused notebook/archive contract checks pass,
  `git diff --check` passes, and the scoped files contain no conflict markers.
  Broader `DeveloperTools/tests` discovery ran 30 tests: 29 passed and the
  unchanged `test_verify_scenario_truthfulness` failed because the unchanged
  verifier's embedded Python unpacks 19 arguments from a 13-argument call.
  That pre-existing tooling mismatch is outside PC-5. This Linux host has no
  `xcodebuild` and no pinned device-session file, so canonical build, scenarios,
  screenshots, console/crash collection, visual checks, and Pencil interaction
  judgments remain blocked. Concurrent collaborator-owned PC-6 plan work was
  preserved and excluded from this line's scope judgment.
- 2026-07-20 — Reopened for explicit directional composition. Acceptance:
  every forward/next page turn moves the complete current page left and brings
  the next page from the physical right; every backward/previous turn moves the
  current page right and brings the previous page from the physical left. Apply
  the same rule to drag, toolbar, strip, overlay, add, and current-page deletion
  paths without changing page data, normalized coordinates, zoom, or gestures.
- 2026-07-20 — Directional repair complete. Navigation records forward or
  backward intent before changing page identity. Programmatic turns apply a
  physical-offset transition to the complete page composition: forward removes
  left/inserts from right, while backward removes right/inserts from left. The
  interactive drag path uses the same direction and distance without also
  activating the programmatic transition. Page identity now wraps the complete
  composition, while drawing-layer identity is limited to the canvas; changing
  layers can no longer trigger a redundant page slide. Cleanup removed the old
  always-forward edge transition and consolidated the shared travel distance.
  Focused notebook/archive checks remain 8/8 passing, `git diff --check` and
  conflict-marker checks pass, and the full host suite remains at 29/30 with
  only the unchanged verifier 19-versus-13 argument mismatch. This host still
  has neither `xcodebuild` nor a pinned device session, so device animation,
  clipping, overlap, tearing, console/crash, and human visual-taste checks remain
  open; no simulator or source-only visual-success claim was substituted.

## Evidence packet — 2026-07-20

### Objective and changed files

- Adapt Pencil Pro gestures/hover/undo and Claire's ripple, page-turn, and
  dotted-paper logic without merging old branch histories or replacing current
  notebook files.
- Product files: `AmbientBackground.swift`, `NotebookCanvas.swift`,
  `NotebookToolbar.swift`, `NotebookView.swift`, `NotebookViewModel.swift`,
  `PageTemplate.swift`, plus new `NotebookUndoBridge.swift`,
  `PencilInteractionController.swift`, and `PencilShortcutPalette.swift`.
- Integration/evidence: `TuberNotes.xcodeproj/project.pbxproj`,
  `DeveloperTools/tests/test_notebook_branch_logic_contract.py`, this child
  plan, and the PC-5 entry in `PLAN.md`.

### Diff summary and scope check

- Current synchronized zoom, export presentation, sidebar overlay,
  persistence, archive, and signing configuration were preserved.
- Page-turn direction is explicit across drag, toolbar, page strip, page
  overlay, add, and current-page deletion paths. The complete canvas/overlay
  composition turns as one unit, while drawing-layer changes remain local to
  the canvas and do not receive page transitions.
- Cleanup removed the redundant always-forward transition and reused one page
  travel distance for gesture and programmatic turns; no duplicate PC-5 support
  type or project membership was found.
- `CONTRACT:` `PageTemplate` gains only the three additive dotted raw values;
  any later commit containing this work must retain the required `CONTRACT:`
  prefix.
- The PC-5 diff stayed within its named files. The overall worktree also
  contains unrelated collaborator-owned PC-6 plan files/edits, which were not
  changed or attributed to PC-5.

### Build and verification

- Build: not run — `xcodebuild` is unavailable on this Linux host.
- Device preflight: not run — no explicitly named/pinned physical iPad and no
  `.tubernotes-device-session.json` are available.
- Focused host checks: 8/8 pass across the new notebook branch-logic contract
  and existing archive/export contract suites; `git diff --check` and conflict-
  marker checks pass.
- Broader host discovery: 29/30 pass; one unchanged verifier-truthfulness test
  fails on its existing 19-versus-13 argument mismatch.
- Required device scenarios: `blank-canvas`, `blank-notebook`,
  `notebook-pages`, and `pin-drift` — not run.
- Screenshots, console, crash diagnostics, and device artifacts: not collected.

### Mechanical and human checks

- Host source checks confirm project membership, iOS 17.0 fallback coverage,
  additive dotted-template rendering, Pencil-only passive ripple input,
  finger-only page turn gating, physical forward/backward page composition,
  complete-overlay movement, and preservation of the current zoom-sync seam.
- On-device intended content, clipping, overlap, crash/exit, animation, and
  spatial-drift checks remain open.
- Human-only Apple Pencil double-tap/squeeze/hover feel, ripple/page-turn
  animation quality, and visual taste remain open.

### Stop reason / unresolved issues

- Stopped at the repository's exact-device prerequisite: no Apple/Xcode host or
  explicitly pinned physical iPad is available. No simulator was substituted.
- The unrelated verifier-truthfulness baseline failure remains unresolved and
  was not expanded into this product-integration scope.
