# TuberNotes — Product Coherence Review Plan

This is the active execution plan for the current review: inspect the product
that actually ships from this checkout, repair behavior that is inconsistent or
confusing, preserve working capability, and make the experience feel direct,
calm, and enjoyable.

The former multi-developer hackathon plan is no longer authoritative here. The
existing `Phase0-*` and `WL-*` documents remain historical implementation and
verification records only. Do not use their ownership split, status board, or
merge sequence to choose current work.

Authority chain: `SPEC.md` (product contracts) → `AGENTS.md` (operating and
device contract) → this plan (current review).

## Branch router

Always confirm `git branch --show-current` before using this plan.

| Branch | Product entry point / purpose | Plan to use |
|---|---|---|
| `sive/dev` | Current integrated product: `LibraryView` → `NotebookView`, with the Debug scenario harness retained separately | **This plan.** It is the active review target. |
| `main` | Shared baseline and deterministic scenario history | Use this plan only after rebasing its inventory and status to `main`; consult the old `WL-*` files only for provenance. |
| `claire/bleh` | Separate experimental visual work | This plan does not authorize edits there. Review its branch-local diff and establish a branch-local scope before changing it. |
| `codex-tenative-m0` / other branches | Historical or isolated experiments | Do not infer current behavior from them. Use only when a task explicitly names that branch. |

Do not switch, merge, rebase, commit, or push as part of this review unless the
user explicitly asks. Preserve existing uncommitted work and distinguish it
from review changes in every diff inspection.

## Mandatory plan structure

Every additional planned effort must receive its own clearly labeled section in
this file. Do not silently fold new work into PC-1, a session-log entry, or an
unrelated existing section.

A new section is mandatory whenever work introduces any of the following:

- a new user-visible feature or independently testable behavior;
- a different developer, owner, or collaborator responsibility;
- a branch-specific implementation or integration path;
- a separate subsystem, contract, migration, investigation, or verification
  effort;
- materially different acceptance evidence or stop conditions;
- a follow-up large enough to require more than one bounded edit-and-verify
  cycle.

Each section must have a stable identifier and contain, at minimum:

1. title and status;
2. target branch and responsible developer/owner, when applicable;
3. objective and user-visible outcome;
4. files or subsystems in scope;
5. explicit non-goals and dependencies;
6. ordered work and verification steps;
7. acceptance evidence and stop conditions;
8. a dated session log that distinguishes completed, blocked, and deferred
   work.

If an effort is too large to remain readable here, create one dedicated child
plan and add a section here that links to it, identifies its branch and owner,
and summarizes its current status. One child plan must still represent one
feature, developer-owned effort, or other coherent work line; never use a child
document as a miscellaneous backlog.

Before editing product code, update the applicable section to `in progress`.
Before ending the session, update that same section with evidence and status.
If no section accurately owns the requested work, create one before proceeding.

## Active line — PC-1: end-to-end product coherence

Status: **in progress — planning and inventory**

### Objective

Review the complete normal-use journey on `sive/dev` and repair concrete
inconsistencies without stripping capability or redesigning working systems:

1. launch into the library and create, open, rename, duplicate, import, export,
   and delete notebooks with clear consequences;
2. write and navigate pages without tool, gesture, or chrome conflicts;
3. use layers, Agentic Layers, Pins, notebook analysis, and drawing refinement
   through distinct and understandable entry points;
4. preserve page identity, ink, images, Pins, layer visibility, and navigation
   state across save/export/import/relaunch boundaries;
5. keep empty, loading, active, success, failure, cancellation, retry, and
   destructive states consistent in language, placement, and recovery;
6. retain deterministic Debug scenarios as regression evidence without
   mistaking the harness UI for the shipping product.

### Experience principles

- The notebook and page remain visually dominant; controls recede when idle.
- One concept has one obvious home. Avoid duplicate controls with different
  wording or subtly different behavior.
- Pencil, finger, tap, hold, drag, and keyboard input must not compete for the
  same gesture without visible explanation and reliable cancellation.
- Irreversible or lossy actions explain what will happen and require deliberate
  confirmation. Reversible actions should feel immediate.
- AI features state what they affect, which service/path they use, whether they
  are deterministic or live, and how to cancel or recover.
- Spatial content remains attached to page identity and normalized page
  coordinates; visual layout must never rewrite an anchor.
- Accessibility labels describe the action and current state, not internal
  implementation terminology.

### Scope

Primary product surfaces:

- `TuberNotes/App/TuberNotesApp.swift`
- `TuberNotes/Library/`
- `TuberNotes/Notebook/`
- `TuberNotes/SpatialCanvas/`
- `TuberNotes/Pins/`
- persistence, archive, PDF, and import/export code reached by those surfaces
- product-runtime agent/refinement seams reached from the normal notebook UI

Regression-only surfaces:

- `TuberNotes/App/RootView.swift`
- `TuberNotes/DeveloperSupport/`
- `DeveloperTools/` scenario and device tooling

These are inspected or changed only when a product repair breaks their truthful
regression contract. Development tooling and the in-product agent remain
separate security and responsibility boundaries.

### Non-goals

- architecture rewrites, subsystem ownership changes, or parallel models;
- new cloud/sync/provider scope, credential distribution, or permission bypass;
- speculative feature expansion unrelated to a demonstrated coherence problem;
- polishing historical branches or making the Debug harness the shipping UI;
- broad test-suite construction where a focused check proves the repair.

## Review order

Work in this order. Finish the current stage and record evidence before
expanding the diff.

### 1. Establish the truthful baseline

- Record branch, HEAD, dirty files, and available host/device tooling.
- Identify the Release and Debug entry paths and every user-reachable top-level
  surface.
- Preserve collaborator edits; review them as current behavior but do not
  silently rewrite or discard them.
- Use the last plan-logged green device scenarios only as historical evidence;
  do not claim they verify the current branch if HEAD differs.

Exit evidence: branch snapshot, entry-point map, scoped file inventory, and
named verification limits.

### 2. Audit complete user journeys

For each journey, trace view → state/model → persistence/runtime side effect →
recovery path. Record findings before editing.

| Journey | Required states and consistency checks |
|---|---|
| Library and documents | first launch, empty state, create, open, rename, duplicate, import, export, delete, error recovery |
| Page lifecycle | blank/PDF page, add, reorder if exposed, navigate away/back, relaunch, page identity |
| Writing | tool selection, color/width, Pencil versus finger, erasing, undo/redo, lock, lasso cancellation |
| Layers | create/select/hide/reorder/delete, mode exit, sidebar visibility, persistence |
| Agentic work | ask, selection context, progress, cancel, failure, retry, resulting Pin, follow-up/discoverability |
| Refinement | select, preview/progress, cancel, apply, undo/recovery, distinction from notebook analysis |
| Files and settings | PDF/SPUD semantics, loss disclosure, credential UI, settings discoverability and naming |
| Layout/accessibility | portrait/landscape, keyboard, sidebar, compact widths, clipping/overlap, focus, labels, hit targets |

Severity order:

1. data loss, crash, security/permission confusion, or spatial corruption;
2. unreachable capability, contradictory state, or gesture conflict;
3. broken recovery, misleading copy, clipping, or overlap;
4. discoverability and consistency;
5. visual delight that does not compromise the first four.

### 3. Make bounded repairs

- Repair one coherent finding cluster at a time.
- Prefer consolidation, better state transitions, and clearer copy over adding
  more controls or tutorial chrome.
- Keep stable data and contract representations. If a shared contract must
  change, use the repository's `CONTRACT:` commit/log rule when committing.
- After each cluster, inspect the diff for unrelated churn before continuing.
- Stop after two verification failures without a narrower diagnosis.

### 4. Verify proportionally

Host-safe checks:

- project/source membership and compile-reference inspection;
- focused persistence/archive/export and state-machine checks;
- `git diff --check` and final ownership/scope inspection.

Canonical user-visible verification when an Apple host and explicitly pinned
physical iPad are available:

1. run `DeveloperTools/device-preflight.sh --device <device-id>`;
2. run only scenarios selected by `Docs/Development.md` for changed surfaces;
3. launch the normal library/notebook path and inspect the repaired journey;
4. mechanically check content, clipping, overlap, crashes, deterministic Pin
   placement, and spatial drift where applicable;
5. use `human-device-loop` only for Pencil feel, gesture discoverability,
   animation feel, and visual taste.

Compilation and scenario evidence are necessary but do not substitute for
physical inspection. On a non-Apple host, stop at the host evidence boundary
and leave build, launch, touch, screenshot, and human judgments explicitly
open.

## Acceptance evidence

PC-1 is complete only when the evidence packet contains:

- a journey matrix with every row reviewed and each finding marked repaired,
  accepted, deferred with reason, or blocked;
- changed files and a concise diff summary confirming unrelated collaborator
  work was preserved;
- focused test/check results and clean source/diff hygiene;
- canonical build/install/launch results on the explicitly pinned iPad;
- scenario names, expected state, and artifact paths for affected surfaces;
- normal-product-path inspection, including portrait/landscape and keyboard or
  sidebar composition when affected;
- crash/console status and mechanical clipping/overlap/spatial checks;
- human-only judgments collected or listed honestly as outstanding;
- unresolved risks and the exact stop reason.

## Stop conditions

Stop and report when any of these is true:

- all acceptance evidence is collected;
- the next change would alter architecture ownership or require new external
  authority;
- an exact-device or host prerequisite is unavailable;
- verification fails twice without a narrower repair;
- the next step would bypass security, permission, or credential boundaries;
- a collaborator's uncommitted change overlaps the required repair and intent
  cannot be preserved safely.

## Session log

- 2026-07-20 — Replaced the obsolete cross-developer hackathon coordination
  plan with PC-1, a branch-aware review of the integrated `sive/dev` product.
  Historical `WL-*` documents remain provenance only. Initial known constraint:
  this Linux host has no Xcode/device execution, so physical-device acceptance
  will require continuation from the named Apple/iPad environment.

## Active line — PC-2: adaptive notebook toolbars

Status: **follow-up implemented — host-checked; awaiting pinned-iPad verification**

Target branch: `sive/dev`

Child work-line: [`PC-2-AdaptiveNotebookToolbars.md`](PC-2-AdaptiveNotebookToolbars.md)

Owner: App integration, preserving `SpatialCanvas` ownership of Pencil and
coordinate behavior.

### Objective and user-visible outcome

Make the normal notebook chrome feel ordered and proportional: the top bar
keeps navigation, page/document actions, and configuration in a predictable
sequence; the working toolbar hugs the controls that are currently enabled,
scrolls only when space is genuinely constrained, fades its overflow edges,
and presents a visible compact pen-width editor above the bar. Notebook
analysis API-key access belongs inside settings rather than as top-bar chrome.

### Scope

- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/Notebook/NotebookToolbar.swift`
- `TuberNotes/SpatialCanvas/DrawingRefinementOverlay.swift`
- `DeveloperTools/tests/test_notebook_tool_selection_contract.py`
- `Docs/Plan/PC-2-AdaptiveNotebookToolbars.md`
- this PC-2 plan section and session log

### Non-goals and dependencies

- No changes to PencilKit tools, width ranges, persisted notebook settings,
  canvas coordinates, page identity, or subsystem ownership.
- No new toolbar preferences or broad visual redesign.
- Physical launch and inspection depend on an explicitly named, pinned iPad.

### Work and verification

1. Order top-bar actions as navigation, page setup/content, page state/export,
   then configuration.
2. Order working controls as instruments, appearance, working modes/layers,
   then page navigation; remove duplicated navigation chrome.
3. Use a content-hugging layout with a bounded scroll fallback, edge fades,
   unclipped long-press feedback, and a compact proportional hold editor;
   retire the separate line-weight button once the hold gesture has priority.
4. Inspect the final diff and run host-safe source/hygiene checks.
5. On the explicitly pinned iPad, build and inspect the normal notebook path
   at wide and compact widths; check clipping, overlap, scrolling, width
   adjustment, popover sizing, and active-group resizing.

### Acceptance evidence and stop conditions

- The working toolbar shrinks when page navigation, writing tools, or layers
  are disabled and never grows beyond the available width.
- Overflow is discoverable without permanently fading controls that fit.
- Long-press width feedback is reachable, proportionate, and unclipped; the
  redundant explicit size button is absent and adjustable accessibility
  actions preserve non-drag width control.
- API-key access is available from settings and absent from the top bar.
- Both bars retain every existing capability in a coherent order.
- The refinement lasso bubble remains centered directly above its Magic Lasso
  toolbar button instead of moving with page content.
- Stop after evidence is collected, after two failed device verifications
  without a narrower repair, or when the exact-device prerequisite is absent.

### Session log

- 2026-07-20 — Started from clean `sive/dev` at `74d69db`. Confirmed the
  working toolbar's unconditional `maxWidth: 820` and scroll clipping made the
  bar oversized and hid its offset long-press width indicator. Began the
  bounded adaptive-layout repair; device verification remains dependent on an
  explicitly pinned iPad.
- 2026-07-20 — Implemented the adaptive working bar and ordered controls as
  instruments → color → selection/refinement → layers → page navigation. The
  bar now hugs visible groups and uses a faded horizontal scroll fallback only
  when constrained. Promoted the 0.45-second hold-then-drag width gesture above
  scrolling, moved its proportional feedback outside the clipped viewport,
  faded it on release, removed the redundant line-weight button, and retained
  VoiceOver adjustable width actions. Moved notebook-analysis API-key access
  from top-bar chrome into Notebook Controls settings and separated working-
  versus top-toolbar visibility settings. `git diff --check` and the three
  archive/export contract tests pass. No Xcode/Swift compiler or pinned device
  session is available on this host, so build, launch, compact/wide layout,
  Pencil hold, screenshot, console, and crash checks remain open.
- 2026-07-20 — Follow-up: anchored the refinement lasso bubble to the live
  Magic Lasso toolbar-button bounds and lifted only its active state through
  `NotebookView`. The canvas continues to own lasso capture and normalized
  selection geometry. All 20 focused host contract tests and diff hygiene pass;
  evidence is under `tmp/verify/pc-2-refinement-lasso-anchor/summary.txt`.
  Physical wide and compact inspection remains blocked by the unavailable
  Apple/iPad host.

## Active line — PC-4: synchronized unlocked zoom

Status: **implementation complete — physical-device verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-4-SynchronizedZoom.md`](PC-4-SynchronizedZoom.md)

Summary: the bounded implementation is complete and host hygiene/coordinate
checks pass. Canonical build, `pin-drift`/`fake-pin`/`multi-pin`, live pinch,
and visual inspection remain blocked because this Linux host has no Swift/Xcode
toolchain or explicitly pinned physical iPad session.

## Active line — PC-5: branch logic integration

Status: **follow-up implemented — host-checked; physical visual verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-5-BranchLogicIntegration.md`](PC-5-BranchLogicIntegration.md)

Summary: adapt the behavior from `origin/feat/pencil-pro-compat` and the latest
available `origin/claire/bleh` to the current notebook architecture without
merging branch histories, replacing newer files, or reverting current zoom,
export, toolbar, persistence, and visual repairs. Forward turns now move the
complete current page left and insert the next page from the physical right;
backward turns apply the inverse. The redundant always-forward layer transition
was removed. The two lasso actions now occupy a divider-bounded toolbar
subsection matching the Undo/Redo grouping. Host checks pass; canonical device
visual verification remains blocked by the absent Apple/Xcode host and pinned
iPad session.

Shared-contract log — 2026-07-20: `CONTRACT:` extend persisted type
`PageTemplate` with the three dotted-paper sizes required to carry Claire's
dotted template behavior through current notebook save/load flows. No existing
case, raw value, page identity, coordinate, or archive representation changes.

## Active line — PC-3: reliable notebook export presentation

Status: **implementation complete — host-checked; awaiting pinned-iPad verification**

Target branch: `sive/dev`

Owner: App integration; archive encoding remains with the existing notebook
and persistence implementation.

### Objective and user-visible outcome

Restore both notebook export tools after their toolbar move: choosing PDF must
reliably show compression options, and confirming PDF or choosing SPUD must
reliably open the system file exporter.

### Scope

- `TuberNotes/Notebook/NotebookView.swift`
- `DeveloperTools/tests/test_archive_export_contract.py`
- this PC-3 plan section and session log

### Non-goals and dependencies

- No changes to PDF rendering, SPUD format/contents, persistence contracts,
  filenames, import behavior, or toolbar layout beyond export presentation.
- Physical launch and inspection depend on an explicitly named, pinned iPad.

### Work and verification

1. Trace the PDF and SPUD actions through their SwiftUI presentation states.
2. Remove the competing menu-to-popover/file-exporter transitions with the
   smallest shared presentation repair.
3. Run host-safe source and diff hygiene checks.
4. On the explicitly pinned iPad, build and open both export paths from a
   normal notebook; confirm the PDF options and both system file exporters
   appear without clipping, overlap, crash, or presentation warnings.

### Acceptance evidence and stop conditions

- The export control exposes both PDF and SPUD.
- PDF options open every time; PDF confirmation opens a `.pdf` save page.
- SPUD opens a `.spud` save page every time.
- Cancellation returns to the notebook without an error or stuck state.
- Stop after evidence is collected, after two failed device verifications
  without a narrower repair, or when the exact-device prerequisite is absent.

### Session log

- 2026-07-20 — At `74d69db`, traced the regression to the export controls'
  move from direct working-toolbar actions to a top-bar `Menu`: PDF now asks
  SwiftUI to present a popover while the menu is still dismissing, and SPUD
  similarly asks for the system file exporter during that dismissal.
- 2026-07-20 — Replaced the competing menu transition with one export popover
  containing PDF compression and SPUD actions. Both formats now use a shared
  delayed handoff from popover dismissal to `fileExporter`; archive failures
  use the same guarded handoff to the error alert. `git diff --check`, project
  membership, state-reference, UTType, and `.spud` extension checks passed.
  Build and interaction verification are blocked on this Linux workspace:
  Xcode is unavailable and no physical-device session is pinned.
- 2026-07-20 — Reopened after export remained unstable at `bf62422`. The prior
  repair still depends on a fixed 0.35-second delay between dismissing the
  export popover and presenting `fileExporter`. An earlier stable implementation
  also kept separate PDF and SPUD exporter states. This session is restoring
  that separation and sequencing the current options sheet through its
  `onDismiss` completion plus one main-actor yield, without a guessed delay.
- 2026-07-20 — Restored independent, statically typed PDF and SPUD
  `fileExporter` presentations. Export preparation now records the requested
  presentation before dismissing the options sheet; the sheet's `onDismiss`
  callback and one `Task.yield()` commit dismissal before the selected exporter
  is activated. File-picker cancellation no longer produces an export-failure
  alert. All four focused archive/export contract tests and `git diff --check`
  pass, and the final diff is limited to `NotebookView`, that focused test, and
  this PC-3 log. This Linux host has no `xcodebuild` or pinned device session,
  so canonical build, both save-page interactions, repeated export/cancel,
  screenshot, console, and crash checks remain open.
- 2026-07-20 — Reopened after the PDF path still failed in use. The supposedly
  independent repair still stacked two `fileExporter` modifiers on the same
  `NotebookView`, leaving a remaining competing-presentation risk despite their
  separate Boolean bindings. Collapsed both formats onto exactly one exporter
  while retaining the options sheet's lifecycle-ordered `onDismiss` handoff. The
  selected content type is now committed before sheet dismissal, the exporter
  has one activation site after that dismissal, and no clock delay is used.
  The focused contract check now proves those ordering and uniqueness
  invariants; all four archive/export tests and `git diff --check` pass. Apple
  documents that `FileDocument` defaults writable types to its declared
  readable types, which already include PDF and SPUD here. Canonical build and
  interaction verification remain blocked because this Linux workspace has no
  Swift/Xcode toolchain or explicitly pinned physical-iPad session; no runtime
  success claim is made from host evidence alone.

## Active line — PC-9: complete notebook PDF and SPUD export

Status: **follow-up implemented — host-checked; physical background export verification blocked**

Target branch: `sive/dev`

Owner: App integration; PDF ink emission remains in `SpatialCanvas`, and the
native archive continues to reuse the existing notebook persistence model.

### Objective and user-visible outcome

Export the complete notebook rather than only the selected page: PDF contains
one drawing-only page for every notebook page in order, while SPUD losslessly
contains the complete editable notebook, including page identities, templates,
images, drawing layers, Agentic Layers, cover, settings, and timestamps. The
library can import that SPUD as a new notebook without overwriting an existing
notebook that has the same archived identity. Before Files appears for either
format, the user can export the entire notebook or choose one or more pages.
PDF can optionally include each selected page's working background—its paper
template and placed images—beneath the ink.

### Scope

- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/Notebook/NotebookViewModel.swift`
- `TuberNotes/Notebook/LibraryView.swift`
- `TuberNotes/Notebook/NotebookStore.swift`
- `TuberNotes/Info.plist`
- `TuberNotes.xcodeproj/project.pbxproj`
- `TuberNotes/SpatialCanvas/PDFStrokeCompression.swift`
- `TuberNotes/SpatialCanvas/TuberNoteArchive.swift`
- `TuberNotes/Notebook/README-notebooks.md`
- `DeveloperTools/tests/test_archive_export_contract.py`
- this PC-9 plan section and session log

### Non-goals and dependencies

- Do not change the system file-exporter presentation, redesign the library,
  add PDF import to the normal notebook library, or emit Pins/conversations/
  citations into PDF.
- Preserve compressed vector ink and the default drawing-only PDF behavior;
  workspace background is opt-in and never includes Pins, conversations,
  citations, selection chrome, or ambient app UI.
- This prerelease format supports version 3 only; remove version 1/2 fields,
  encoders, decoders, and migration adapters rather than carrying dead schema.
- Canonical build and interaction inspection require an explicitly named,
  pinned physical iPad and an Apple/Xcode host.

### Work and verification

1. Add ordered multi-page PDF emission without changing stroke compression.
2. Keep SPUD as a version-3-only whole-notebook payload.
3. Route both notebook export entry points through the complete document.
4. Add library import that clones the decoded notebook under a fresh identity.
5. Extend focused source checks for page ordering, completeness, filenames,
   version rejection, importer wiring, and collision-safe persistence.
6. Add a pre-export entire-document/selected-pages control shared by PDF and
   SPUD; selected SPUD payloads retain only Pins belonging to exported pages.
7. Add an opt-in PDF workspace-background layer containing the selected pages'
   paper templates and placed images beneath their vector ink.
8. On the pinned iPad, export and re-import a deterministic multi-page notebook;
   inspect PDF page count and imported SPUD page/content identity.

### Acceptance evidence and stop conditions

- A notebook with multiple pages exports the same number of PDF pages in the
  same order; PDF remains drawing-only and contains no Agentic Layer content.
- SPUD round-trips all notebook pages and notebook-owned state; any format
  version other than 3 is rejected.
- Importing SPUD creates and opens a new library notebook, preserves page and
  content identities, and never overwrites an existing notebook ID.
- The export-options sheet defaults to the entire document, can choose pages by
  number, preserves notebook order, and blocks both formats when none are chosen.
- Selected-page PDF contains exactly the chosen pages; selected-page SPUD keeps
  exactly those pages and filters every Agentic Layer to Pins on those pages.
- PDF workspace background defaults off. When enabled, each exported page uses
  its own paper template and placed images under ink, with no Pin/agent content.
- Both exported filenames describe the notebook, not one selected page.
- Existing export presentation/cancellation checks remain green.
- Stop after host and device evidence is collected, after two verification
  failures without a narrower fix, or when the exact-device prerequisite is
  unavailable.

### Session log

- 2026-07-20 — Traced both normal notebook export actions to `currentPage`.
  PDF emits one drawing-only page and SPUD stores only that page's drawing
  layers, despite Agentic Layers spanning the whole notebook; filenames also
  identify the selected page. Began the bounded whole-notebook repair while
  preserving PC-3's single ordered `fileExporter` presentation.
- 2026-07-20 — `CONTRACT:` evolve persisted type `TuberNoteArchive` to carry an
  optional complete `Notebook` payload in format version 3. The optional field
  preserves version 1/2 decoding; the change is required so native SPUD export
  retains every page and all notebook-owned editable state.
- 2026-07-20 — Implemented ordered multi-page drawing-only PDF emission and
  whole-notebook SPUD encoding, updated both export routes and document-level
  filenames, and documented the resulting semantics. Focused archive/export
  checks pass 6/6 and `git diff --check` passes. The broader host suite passes
  43/44; its lone failure is the unrelated existing verifier-truthfulness test,
  whose helper receives 13 arguments while expecting 19. Evidence is under
  `tmp/verify/pc-9-complete-document-export/summary.txt`. Canonical build,
  runtime PDF page-count/SPUD round-trip inspection, save-page interaction,
  screenshots, console, and crash checks remain blocked because this Linux host
  has neither Xcode/Swift nor an explicitly pinned physical-iPad session.
- 2026-07-20 — Follow-up requested for the prerelease format: remove all SPUD
  version 1/2 compatibility and add normal-library SPUD import. Reopened PC-9
  with import UI and collision-safe store persistence in scope.
- 2026-07-20 — `CONTRACT:` replace persisted type `TuberNoteArchive`'s legacy
  single-page/mirror fields with one required complete `Notebook` payload and
  accept format version 3 only. No released data requires migration; the reset
  removes dead prerelease schema before adding the matching import path. The
  same contract declares `com.tubernotes.note` as JSON tagged with the `.spud`
  extension so Files can select archives through the normal importer.
- 2026-07-20 — Removed all version 1/2 archive structures and adapters; version
  3 now contains one required complete `Notebook` and validates every drawing
  layer during decode. Added the registered `.spud` document type and a library
  Files importer. Import uses security-scoped access, assigns a fresh notebook
  ID to prevent overwrite, preserves page/content identities and notebook state,
  saves the result, and opens it. Focused checks pass 8/8, plist parsing and
  `git diff --check` pass, and no legacy SPUD production symbols remain. The
  broader host suite passes 51/52 with the same unrelated verifier-argument
  mismatch. Concurrent out-of-scope unstaged edits appeared during verification
  and were preserved. Updated evidence is under
  `tmp/verify/pc-9-complete-document-export/summary.txt`. Physical Files export,
  re-import, visible content, screenshot, console, and crash evidence remain
  blocked by the absent Xcode/Swift host and pinned iPad session.
- 2026-07-20 — Reopened to add page scope before the system file picker for both
  formats. The bounded design keeps the existing sheet/exporter handoff,
  defaults to the entire document, and derives ordered selected-page payloads
  without changing SPUD v3, import, or PDF privacy contracts.
- 2026-07-20 — Added Entire Document/Choose Pages scope to the export sheet,
  numbered page toggles with All/Clear actions, current-page initialization for
  custom selection, an explicit empty-selection state, and shared disabling for
  both format actions. PDF now receives the selected pages in notebook order;
  selected-page SPUD rebuilds the notebook with those pages and filters every
  Agentic Layer to Pins on exported page IDs. The existing sheet-dismissal →
  single-file-exporter lifecycle is unchanged. Focused checks pass 10/10 and
  `git diff --check` passes. After the concurrent PC-12 contract was updated,
  the broader host suite passes 58/59; the only failure is the pre-existing
  verifier argument mismatch. Concurrent PC-12 edits in `NotebookView` and this
  plan were preserved. Updated evidence
  is under `tmp/verify/pc-9-complete-document-export/summary.txt`. Build, Files
  interaction, selected PDF/SPUD inspection, screenshots, console, and crash
  evidence remain blocked by the absent Xcode/Swift host and pinned iPad.
- 2026-07-20 — Reopened for an optional PDF working-background control. Traced
  the visible notebook background to `PaperSheetView` plus `PlacedImage` content
  beneath PencilKit ink. The bounded implementation will reuse that renderer,
  remain off by default, and leave SPUD and PDF privacy exclusions unchanged.
- 2026-07-20 — Added an off-by-default Include workspace background PDF option.
  For the chosen pages it renders the existing paper template and normalized
  placed images into a page-sized background, then draws compressed vector ink
  above it; Pins, conversations, citations, selection chrome, and app UI remain
  excluded. Focused archive/export checks pass 11/11 and `git diff --check`
  passes. The broader host suite passes 59/60; its sole failure remains the
  unrelated scenario-verifier helper mismatch (13 supplied arguments versus 19
  expected). Concurrent PC-12 edits were preserved. Evidence is under
  `tmp/verify/pc-9-complete-document-export/summary.txt`. Canonical build and
  visible PDF inspection remain blocked because this Linux host has no Xcode or
  Swift toolchain and no explicitly pinned physical-iPad session.

## Active line — PC-6: agent provider unification

Status: **implemented — provider access host-checked; Apple/device/live verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-6-AgentProviderUnification.md`](PC-6-AgentProviderUnification.md)

Summary: adapt provider/model and external Responses-gateway behavior from
`origin/workspace/shaftatron-torture-DONT-MERGE-THIS-SHIT` into the newer
AgentHarness contracts so the normal Agentic Layer sidebar and streamed
Pin/conversation client share one provider-access value. Preserve recorded/demo
defaults, strict spatial validation, credential boundaries, and the separate
image-refinement backend contract.

Host implementation and scoped checks pass. The normal settings and Agentic
Layer routes now expose the selected provider/model, use lifecycle-ordered
presentation, carry explicit accessibility contracts, and show actionable
redacted provider failures. Canonical Swift/Xcode build, physical-iPad
scenarios, normal-product visual inspection, and separately authorized
live-provider evidence remain blocked because this host exposes no Apple or
Swift toolchain or pinned device session.

## Active line — PC-7: Agentic Layer, conversation-tree, and movable-Pin interaction cleanup

Status: **page-edge glow inset repaired — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-7-AgentLayerPinInteraction.md`](PC-7-AgentLayerPinInteraction.md)

Summary: make the normal notebook's Agentic Layer read as one of two honest
user-visible states—hidden or active—without conflating an open layer picker
with active page content. Reuse the existing page-normalized Pin contract to
make conversation Pins draggable and persisted; render those durable Pins as
cycle-safe conversation history in the normal Agent sidebar; remove dead follow-up
affordances; and route supported Pin follow-ups into the matching tree node.

Shared-contract log — 2026-07-20: `CONTRACT:` add
`PinOverlayEvent.moved(annotationID:target:)` so the Pins-owned drag gesture can
hand one page-normalized final anchor to its coordinator-owned persistence
path. No persisted type, page identity, provider/runtime boundary, or
coordinate representation changes.

Shared-contract log — 2026-07-20: `CONTRACT:` add optional
`PageAnnotation.parentThreadID` so existing persisted Pin annotations can
express lineage topology without a second conversation store. Older notebook
and SPUD payloads decode the missing optional value as a root; page identity,
annotation identity, and existing thread IDs are unchanged.

The bounded follow-up is implemented: same-lineage replies read as conversation
continuation, bounded cycle-safe history is isolated as quoted agent context
with evidence/uncertainty guidance, and Pin drag uses stable overlay coordinates
with a fixed, edge-clamped card offset. Focused checks pass 13/13; evidence is
under `tmp/verify/pc-7-conversation-pin-followup/`. Canonical build, the named
Pin scenarios, normal-product history/drag inspection, screenshots,
console/crash evidence, and human interaction judgment remain blocked because
this Linux workspace has no Apple/Swift toolchain or explicitly pinned
physical-iPad session.

The additional bounded visual follow-up now carries the active Agentic Layer's
cyan/blue/indigo/purple/pink glow into the existing animated notebook
background gradients and Pencil ripple while leaving the hidden-layer
background neutral. Focused checks pass 13/13; evidence is under
`tmp/verify/pc-7-agentic-ambient-glow/`. Physical-device visual/taste evidence
remains blocked by the same unavailable Apple host and pinned-iPad prerequisite.

The unsigned-IPA build regression reported at `PinOverlayView.swift:197` is
repaired with the missing explicit `return` and a focused regression assertion.
PC-7 plus nearby archive/export and notebook branch-logic checks pass 15/15;
evidence is under `tmp/verify/pc-7-ipa-build-regression/`. This Linux host has
no Xcode tools or pinned-device session, so the reporting Apple host must rerun
the IPA build and the named PC-7 physical-device scenarios.

The bounded page-edge follow-up removes the 4-point horizontal and 10-point
vertical view-space inset from the active Agentic Layer glow, so its rendering
frame now matches the reported page viewport bounds. The focused and nearby
host checks pass 21/21; evidence is under
`tmp/verify/pc-7-agentic-page-edge-glow/`. This Linux host has no Xcode tools
or pinned-device session, so build, screenshot, crash/console, and physical
visual evidence remain blocked.

## Active line — PC-8: drawing tool recovery after erasing

Status: **implemented — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-8-DrawingToolRecovery.md`](PC-8-DrawingToolRecovery.md)

Summary: the main toolbar now observes a short tool tap simultaneously with its
existing high-priority hold-and-drag width gesture, routing both the button and
tap paths through one idempotent selection helper. The focused contract plus
the four nearby notebook/Pencil checks pass (5/5), as does `git diff --check`;
evidence is under `tmp/verify/pc-8-drawing-tool-recovery/`. Canonical build,
`blank-canvas`, and physical eraser-to-drawing interaction proof remain blocked
because this Linux host has no Xcode or explicitly pinned iPad session.

## Active line — PC-9: drawing-refinement lasso containment

Status: **mechanically accepted — ready to merge**

Target branch: `phil/lasso-containment`

Child work-line: [`PC-9-LassoContainment.md`](PC-9-LassoContainment.md)

Summary: drawing refinement now retains the validated closed lasso path and
removes only strokes fully enclosed by it; crossing or grazing strokes survive.
The focused containment contract passes 3/3. Exact physical iPad
`2DD98ECC-A26A-5730-943B-01DD63DC4117` passed preflight and the `lasso-crop`
build/install/launch, runtime-evidence, and crop assertions under
`tmp/verify/20260720-190651-lasso-crop/`. The retained crop contains the
expected ruled PDF content. Human Pencil feel and visual-taste review remain
uncollected.

## Active line — PC-10: codebase stability audit

Status: **host audit complete — high-risk findings open; Apple/device verification blocked**

Target branch: `sive/dev`

Owner: product-wide investigation coordinated through App integration; no
product implementation changes are authorized by this audit line.

### Objective and user-visible outcome

Trace the shipping library/notebook path, its persistence and asynchronous
boundaries, spatial and export code, project membership, and development
verification tooling for crash, data-loss, stale-state, interaction, and
non-determinism risks. Produce prioritized evidence rather than treating host
source checks as proof of physical-iPad stability.

### Scope

- all Swift sources under `TuberNotes/` and their Xcode source membership;
- notebook lifecycle, drawing, images, layers, Agentic work, Pins, export, and
  persistence reached from the normal product entry path;
- `DeveloperTools/` host checks, verifier truthfulness checks, and harness
  source contracts;
- repository diff hygiene and the current `sive/dev` working-tree snapshot.

### Non-goals and dependencies

- no product fixes, refactors, architecture changes, external writes, or new
  test-suite construction;
- canonical build, launch, visual inspection, console/crash collection, Pencil
  feel, and viewport interaction require an Apple/Xcode host plus an explicitly
  pinned physical iPad;
- preserve concurrent collaborator edits and distinguish them from audit work.

### Acceptance evidence and stop conditions

- prioritized findings include exact source locations and reproducible impact;
- all available host suites, syntax checks, secret scans, project membership,
  and diff hygiene are reported with failures separated from unavailable
  prerequisites;
- stop after host evidence is recorded because the exact-device prerequisite
  is unavailable; do not claim the app has no unstable behaviors.

### Session log

- 2026-07-20 — Audited 16,323 lines across 51 Swift files at
  `59d3fadd5d2403ce3291eb6edab16af12015fa04`. Found open high-risk defects:
  debounced drawing saves are not flushed on app backgrounding; persistence
  errors are silently presented as successful in-memory saves/deletes; an
  Agentic request can outlive its editor and later overwrite newer whole-note
  state; and page lock leaves Pencil drawing enabled. Also found destructive
  page deletion without confirmation/undo and unbounded photo payloads being
  re-encoded synchronously on the main actor. No product files were changed.
- 2026-07-20 — Main host suite: 46/47 pass; the verifier truthfulness test is
  stale (13 supplied runtime fields versus 19 unpacked). Focused product source
  contracts otherwise pass 43/43, agent-layer checks pass 5/5, OpenCode auth
  reproduction and secret scans pass 16/16, and all Python/Shell syntax checks
  pass. The PencilFixtureMCP UI source suite passes 15/16 because one assertion
  depends on single-line Swift formatting; remaining MCP integration tests are
  unavailable without the declared `mcp` dependency. CodexAdapter Swift checks,
  Xcode build, physical scenarios, screenshots, console, and crash diagnostics
  are blocked because this Linux host has no Swift/Xcode tools or pinned iPad.
- 2026-07-20 — During the audit, concurrent collaborator edits appeared in
  `PinOverlayView.swift` and its focused contract test. They add the explicit
  `return` required by the multi-statement placement helper and pass their 5/5
  focused checks. The audit preserved those edits and did not attribute them to
  this work.

## Active line — PC-11: baseline notebook lasso stability

Status: **implemented — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Owner: `SpatialCanvas` owns gesture geometry and canvas-local movement;
`Notebook` owns visible lasso mode and selection state.

### Objective and user-visible outcome

Make the normal notebook lasso predictable: abandoned or cancelled selections
must not remain actionable, intentional Agent/refinement handoffs must retain
their chosen region, degenerate gestures must clear stale state, and moved ink
must remain recoverable inside the logical page.

### Scope

- `TuberNotes/Notebook/NotebookCanvas.swift`
- `TuberNotes/Notebook/NotebookToolbar.swift`
- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/Notebook/NotebookViewModel.swift`
- one focused host regression check under `DeveloperTools/tests/`
- this plan section

### Non-goals and dependencies

- no drawing-refinement lasso redesign, shared coordinate-contract change,
  toolbar redesign, Pencil capture change, or Pin behavior change;
- physical interaction and Pencil feel require an Apple/Xcode host and an
  explicitly pinned iPad.

### Work and verification

1. Clear model selection whenever lasso mode exits or a gesture cannot produce
   a usable selection.
2. Clamp visible selection bounds and drag deltas to the logical page before
   moving or persisting strokes.
3. Add focused source checks for clearing and page-boundary behavior.
4. Run nearby notebook/lasso host suites and diff hygiene; run the canonical
   device scenario only when the exact-device prerequisite is available.

### Acceptance evidence and stop conditions

- abandoned lasso rectangles cannot feed later actions, while explicit Agent
  and refinement handoffs retain their selected region;
- moved selected ink and its selection frame remain within page bounds;
- focused host checks pass and unrelated collaborator edits remain untouched;
- stop after host verification when the Apple/device prerequisite is
  unavailable, or after two failed device attempts without a narrower fix.

### Session log

- 2026-07-20 — Reopened after a device-side report that the regular lasso
  appears broken. Traced its toolbar input path and found that its
  high-priority hold gesture can consume a short tap; unlike the adjacent
  writing-tool buttons, the lasso button had no simultaneous tap observer.
  Began the smallest activation-path repair and focused regression check; no
  coordinate or shared-contract change is required.
- 2026-07-20 — Routed both the lasso Button action and a simultaneous short-tap
  observer through one idempotent activation helper, matching the established
  adaptive-toolbar gesture pattern. Added a focused regression assertion.
  Lasso stability passes 6/6, toolbar selection passes 2/2, and nearby notebook
  contracts pass 15/15. The complete host suite passes 61/62; its sole failure
  is the previously logged unrelated verifier-truthfulness fixture supplying
  13 runtime fields to a 19-field assertion. `git diff --check` passes and the
  diff remains limited to lasso activation, its focused test, and this log. No
  shared contract changed. Xcode build, normal-notebook launch, screenshot,
  console/crash collection, and physical tap/Pencil verification remain
  blocked because this Linux host has no Xcode tools or pinned iPad session.
- 2026-07-20 — Traced normal notebook lasso state and movement. Confirmed that
  mode exit and degenerate gestures can leave `NotebookViewModel.lassoRect`
  stale after the UIKit overlay clears, and that drag deltas are not bounded to
  the page. Began the smallest state/geometry repair; no contract type changes.
- 2026-07-20 — Implemented explicit lasso activation/deactivation semantics so
  toolbar, drawing-layer, image-arrangement, Agent, and refinement transitions
  either clear or intentionally preserve the selected region. Degenerate loops
  now clear model and overlay state. Removed the update-loop defect that cleared
  every active, not-yet-completed loop whenever SwiftUI refreshed—a path made
  especially visible by Pencil-driven ambient updates. Page-edge selection
  rectangles and drag deltas are clamped to logical page coordinates; locked
  pages reject lasso input; cancelled loops clear instead of selecting, and
  cancelled moves restore the pre-drag drawing rather than committing partial
  movement. Focused lasso and nearby notebook suites pass 19/19; the complete
  host suite passes 53/54, with only the separately logged unrelated stale
  verifier-truthfulness test failing. Python
  and shell syntax plus `git diff --check` pass. No shared contract changed.
  Canonical Xcode build, `blank-canvas` interaction, screenshots, console/crash
  collection, and Pencil feel remain blocked on this Linux host without an
  explicitly pinned physical iPad session.

## Active line — PC-12: selectable page scroll direction

Status: **implementation complete — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Owner: App/Notebook integration; `SpatialCanvas` retains ownership of page
coordinates, Pencil input, and zoomed-page panning.

### Objective and user-visible outcome

Let a user choose Vertical or Horizontal in notebook Settings and use that axis
for one-finger page navigation. Preserve Horizontal as the default for existing
notebooks and persist the selection with the notebook.

### Scope

- `TuberNotes/Notebook/Notebook.swift`
- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/Notebook/NotebookCanvas.swift`
- `TuberNotes/Notebook/NotebookToolbar.swift`
- one focused host regression check under `DeveloperTools/tests/`
- the existing page-turn source contract updated for axis-aware transitions
- this PC-12 section and session log

### Non-goals and dependencies

- no continuous multi-page canvas, page-coordinate change, Pencil gesture
  change, zoom/pan redesign, toolbar redesign, or global app preference;
- canonical build and interaction inspection require an Apple/Xcode host and an
  explicitly pinned physical iPad.

### Work and verification

1. Add an archive-compatible per-notebook scroll-direction setting.
2. Expose a labeled Vertical/Horizontal picker in Notebook Controls.
3. Apply the selected axis to page-swipe recognition, interactive offset, and
   page transition while leaving zoomed-page panning unchanged.
4. Run focused persistence/source checks, nearby host tests, and diff hygiene.
5. On the explicitly pinned iPad, run `notebook-pages` and inspect both axes in
   the normal notebook Settings path, including clipping, overlap, crashes, and
   Pin stability.

### Acceptance evidence and stop conditions

- the setting is discoverable, defaults to Horizontal, persists per notebook,
  and older notebook data decodes to Horizontal;
- both axes turn forward/backward in the expected physical direction and use a
  matching transition; perpendicular swipes do not turn pages;
- zoomed-page panning, Pencil input, page coordinates, and Pins remain unchanged;
- stop after evidence is collected, when the exact-device prerequisite is
  unavailable, or after two device verification failures without a narrower
  repair.

### Session log

- 2026-07-20 — Started from clean `sive/dev` at `b33a040`. Confirmed current
  page navigation is horizontal-only and owned by the notebook canvas gesture
  seam. Began the smallest per-notebook persisted-axis change; no coordinate or
  architecture ownership change is planned.
- 2026-07-20 — Added the per-notebook Horizontal/Vertical segmented setting,
  tolerant legacy decoding, debounced setting persistence, axis-aware page
  offsets/transitions, matching navigation glyphs, and vertical edge arbitration
  that preserves ordinary within-page panning. Focused and nearby notebook/
  archive checks pass 27/27, Python syntax and `git diff --check` pass, and the
  final PC-12 diff stayed in scope. Evidence is under
  `tmp/verify/pc-12-scroll-direction/summary.txt`. Canonical Xcode build,
  `notebook-pages`, physical Settings/swipe inspection, screenshots, console,
  crash diagnostics, and interaction quality remain blocked because this Linux
  host has no Xcode/Swift toolchain or explicitly pinned physical iPad. The
  concurrent PC-9 export edits were preserved and are not attributed here.

Shared-contract log — 2026-07-20: `CONTRACT:` extend persisted
`NotebookSettings` with `pageScrollDirection` and add
`NotebookPageScrollDirection` so a notebook can retain the user's chosen page
navigation axis. Missing values decode as Horizontal; page identity, spatial
coordinates, archive version, and existing setting keys are unchanged.

## Active line — PC-17: image import arrangement

Status: **implemented — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-17-ImageImportArrangement.md`](PC-17-ImageImportArrangement.md)

Owner: App/Notebook owns import presentation and document persistence;
`SpatialCanvas` owns image gestures and page-relative placement.

### Objective and user-visible outcome

Let imported images rotate while they are being arranged, and offer an
at-import option that removes a photo's background before placing it on the
page.

### Scope and non-goals

- Limit product edits to `Notebook.swift`, `NotebookView.swift`,
  `NotebookViewModel.swift`, and `NotebookCanvas.swift`, plus one focused host
  check and this work-line documentation.
- Do not change the drawing-refinement backend, product-agent boundary, Pencil,
  Pins, conversations, page navigation, or normalized image-placement
  coordinates.

### Acceptance evidence and stop conditions

- rotation persists backward-compatibly and renders consistently in every
  placed-image composition;
- arrangement supports a two-finger twist and visible clockwise Rotate action;
- import offers off-by-default, on-device foreground extraction that stores PNG
  alpha and reports progress or failure;
- stop after focused/nearby host evidence and the required notebook scenarios,
  or when the exact-device prerequisite is unavailable.

### Session log

- 2026-07-21 — Confirmed rotation and import-time transparency are both absent.
  Began a bounded implementation using persisted rotation plus the iOS 17
  on-device Vision foreground-instance mask; the existing refinement provider
  and normalized image rect remain unchanged.
- 2026-07-21 — Implemented backward-compatible rotation with free twist and a
  visible clockwise action, rotation-aware selection and every placed-image
  composition, plus an import sheet whose off-by-default transparency option
  extracts all foreground instances as PNG alpha off the UI thread. Focused and
  nearby contracts pass 28/28 and diff hygiene passes. The full host suite
  passes 70/71; its sole failure is the separately logged stale verifier test
  supplying 13 fields to a 19-field runtime assertion. Evidence is under
  `tmp/verify/pc-17-image-import-arrangement/summary.txt`. Physical build,
  `blank-notebook`, `notebook-pages`, screenshots, console/crash collection,
  transparency edges, and twist feel remain blocked on this Linux host without
  Xcode or a pinned iPad session.
- 2026-07-21 — Stability follow-up made completed image transforms
  immediate-persistence operations, keeps every transformed image reachable on
  the page, normalizes button rotation, and prevents cancelled/stale foreground
  jobs from placing late results. Transparent imports now honor capture
  orientation, reuse one thread-safe Core Image context, and cap their longest
  processed edge at 2,560 pixels before PNG encoding. Strengthened focused and
  nearby checks pass 30/30; the complete host suite passes 72/73 with only the
  unrelated stale verifier fixture failing. Diff hygiene passes. Physical build
  and interaction/edge-quality checks remain blocked because no Xcode toolchain
  or explicitly pinned iPad is available.

Shared-contract log — 2026-07-21: `CONTRACT:` extend persisted `PlacedImage`
with `rotationRadians` so canvas arrangement survives save, reload, archive,
and export. Missing values decode as zero; image bytes, normalized rects, page
coordinates, and archive version are unchanged.

## Active line — PC-16: pen-width selection border

Status: **implementation complete — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Owner: App/Notebook toolbar UI; `SpatialCanvas` retains ownership of Pencil
input, canvas coordinates, and rendered ink.

### Objective and user-visible outcome

Make the selected Pen button's circular border use the Pen's selected point
width, so the toolbar itself gives an immediate proportional width preview.

### Scope

- `TuberNotes/Notebook/NotebookToolbar.swift`
- the focused toolbar source regression check
- this PC-16 plan section and session log

### Non-goals and dependencies

- no PencilKit tool, persisted width, width range, gesture, color, layout,
  spatial-coordinate, or shared-contract changes;
- no visual redesign of Pencil, Highlighter, or Eraser selection states;
- canonical build and visual inspection require an Apple/Xcode host and an
  explicitly pinned physical iPad.

### Work and verification

1. Bind the selected Pen border line width directly to its current width.
2. Preserve the existing button frame, tap/hold gestures, color treatment,
   and accessibility value.
3. Add a focused source assertion, run the toolbar check, and inspect the diff.
4. Run `blank-notebook` on the pinned iPad and inspect minimum/default/maximum
   Pen widths for clipping, overlap, and a truthful proportional preview.

### Acceptance evidence and stop conditions

- the selected Pen border uses `vm.width(for: .pen)` without altering the
  canvas width value or selection gesture;
- the 34-point button footprint and neighboring tool layout remain unchanged;
- stop after evidence is collected, when the exact-device prerequisite is
  unavailable, or after two device failures without a narrower repair.

### Session log

- 2026-07-21 — Traced the selected writing-tool treatment to
  `NotebookToolbar.toolButton` and confirmed the model already exposes the
  current per-tool point width. Began a Pen-only visual binding; no canvas or
  shared contract change is planned.
- 2026-07-21 — Bound the selected Pen's inset contrast border directly to
  `vm.width(for: tool)` while preserving its 34-point frame, filled selection
  treatment, gestures, and accessibility value. Added a focused source
  regression assertion; all four toolbar selection tests pass and
  `git diff --check` passes. Final diff inspection found only the requested
  toolbar change, its narrow check, and this PC-16 record; unrelated PC-15
  work remains untouched. Xcode build, `blank-notebook` launch, screenshots,
  console/crash collection, and minimum/default/maximum-width visual checks
  remain blocked because this host has no Xcode toolchain or pinned physical-
  iPad session. No shared contract changed.

## Active line — PC-15: end-pull page creation

Status: **implementation complete — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-15-EndPullAddPage.md`](PC-15-EndPullAddPage.md)

Owner: App/Notebook integration; `SpatialCanvas` retains ownership of Pencil,
page coordinates, zoom, and within-page panning.

### Objective and user-visible outcome

On the final notebook page, continuing the configured page-navigation gesture
forward reveals progress. Holding for 0.7 seconds adds exactly one new page;
releasing or moving back early cancels.

### Scope

- `TuberNotes/Notebook/NotebookView.swift`
- one focused source regression check under `DeveloperTools/tests/`
- the PC-15 child work-line and this status/log

### Non-goals and dependencies

- no page model, persistence, template, spatial-coordinate, Pencil, zoom/pan,
  toolbar, or settings-contract changes;
- no continuous multi-page canvas or replacement of explicit add-page buttons;
- canonical build and interaction inspection require an Apple/Xcode host and an
  explicitly pinned physical iPad.

### Work and verification

1. Extend the existing axis-aware page-turn state with a final-page forward
   hold, cancellation, and one-add-per-gesture latch.
2. Show non-intercepting progress at the configured forward edge.
3. Reuse `NotebookViewModel.addPage()` and the existing page-turn animation.
4. Run focused and nearby host checks plus diff hygiene.
5. Run `blank-notebook` and `notebook-pages` on the pinned iPad and inspect both
   completion and cancellation in Horizontal and Vertical modes.

### Acceptance evidence and stop conditions

- the indicator appears only after a deliberate forward pull on the last page;
- completion adds and displays exactly one page, while early release/reversal
  adds none, and a continuous gesture cannot add repeatedly;
- normal page turns, explicit add buttons, zoom/pan, Pencil, and page identity
  remain unchanged;
- stop after evidence is collected, when the exact-device prerequisite is
  unavailable, or after two device failures without a narrower repair.

### Session log

- 2026-07-21 — Traced the current axis-aware `NotebookCanvas` pan into
  `NotebookView`'s interactive page-turn state and confirmed page insertion is
  already App-owned by `NotebookViewModel.addPage()`. Began the smallest
  view-state-only extension; no shared contract or ownership change is planned.
- 2026-07-21 — Added a 72-point final-page forward-pull threshold, a 0.7-second
  visible progress hold, early-release/reversal cancellation, success feedback,
  the existing animated `addPage()` path, and a one-add-per-finger-gesture latch
  that ignores late updates until release. The indicator follows the selected
  Horizontal/Vertical forward edge without intercepting input. The 10 focused
  and nearby notebook checks pass; the complete host suite passes 65/66 with
  only the previously logged unrelated verifier-truthfulness fixture mismatch
  (19 expected arguments, 13 supplied). Python syntax and diff hygiene pass.
  Evidence is under `tmp/verify/pc-15-end-pull-add-page/summary.txt`. Xcode
  build, `blank-notebook`, `notebook-pages`, physical interaction, screenshots,
  console, and crash checks remain blocked because this host has no Xcode
  toolchain or configured physical-iPad session. No shared contract changed.

## Active line — PC-14: favorite color scrub

Status: **implementation complete — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-14-FavoriteColorScrub.md`](PC-14-FavoriteColorScrub.md)

Owner: App integration, using the existing notebook color and favorite-settings
contracts.

### Objective and user-visible outcome

Let the user long-press the working toolbar's color control and slide left or
right through favorited colors, matching the pen tools' hold-and-slide
interaction, while a normal tap continues to open the full color picker.

### Scope

- `TuberNotes/Notebook/NotebookToolbar.swift`
- `DeveloperTools/tests/test_notebook_tool_selection_contract.py`
- `Docs/Plan/PC-14-FavoriteColorScrub.md`
- this PC-14 section and session log

### Non-goals and dependencies

- No favorite-color persistence, palette contents, PencilKit, canvas,
  coordinate, toolbar-order, or shared-contract changes.
- No redesign of the full color picker or notebook settings.
- Physical launch and inspection depend on an explicitly named, pinned iPad.

### Work and verification

1. Add a priority hold-then-horizontal-drag gesture to the color button while
   retaining its short-tap popover action.
2. Select the nearest favorite as the drag crosses each swatch step and show a
   compact live favorite strip above the toolbar.
3. Preserve adaptive scrolling outside the hold and provide adjustable
   accessibility selection through favorites.
4. Run focused host checks and final diff hygiene.
5. Build, launch, and mechanically inspect the normal notebook path on the
   explicitly pinned iPad.

### Acceptance evidence and stop conditions

- Short tap still opens the full color picker.
- Hold-and-slide reaches the first and last favorited colors and shows the
  current selection without clipping or overlap.
- Release dismisses the indicator and restores toolbar scrolling.
- Empty favorites leave tap-to-open intact and do not begin a scrub.
- Focused host checks pass and unrelated collaborator edits remain untouched.
- Stop after evidence is collected, after two failed device verifications
  without a narrower fix, or when the exact-device prerequisite is absent.

### Session log

- 2026-07-20 — Started from the existing adaptive-toolbar implementation.
  Confirmed favorite colors already persist in `NotebookSettings` and the color
  button currently supports only tap-to-open. Began the smallest toolbar-only
  hold-and-scrub addition; no shared contract or ownership change is required.
- 2026-07-20 — Added a priority 0.45-second hold followed by horizontal scrub,
  anchored to the current favorite and clamped through the first/last saved
  colors. A compact live strip shows the nearby favorites and current position;
  release restores adaptive toolbar scrolling. Short tap still opens the full
  picker, empty favorites do not start a scrub, and adjustable accessibility
  actions traverse the same favorites. Focused toolbar/lasso contracts pass
  9/9, the 16-start-index boundary simulation and `git diff --check` pass, and
  the full host suite passes 62/63 with only the already logged unrelated
  verifier-truthfulness argument-count failure. Evidence is under
  `tmp/verify/pc-14-favorite-color-scrub/summary.txt`. Existing lasso, plan,
  project, and app-icon collaborator edits were preserved. Xcode build,
  physical launch, tap/scrub inspection, screenshot, console, and crash checks
  remain blocked because this Linux host has no Xcode toolchain, explicit
  device ID, or pinned iPad session.

## Active line — PC-13: application icon asset

Status: **implementation complete — host-checked; Xcode/device verification blocked**

Target branch: `sive/dev`

Owner: App integration and project resources.

### Objective and user-visible outcome

Turn the supplied `tunotes.JPEG` artwork into the canonical TuberNotes iOS app
icon so installed builds show the intended hand-drawn mark instead of a generic
placeholder.

### Scope

- `tunotes.JPEG` as the source artwork
- `TuberNotes/Assets.xcassets/AppIcon.appiconset/`
- `TuberNotes.xcodeproj/project.pbxproj`
- this PC-13 section and session log

### Non-goals and dependencies

- no redraw, branding change, alternate dark/tinted artwork, launch-screen
  change, or unrelated UI work;
- Xcode asset compilation and installed-icon inspection require an Apple/Xcode
  host and the explicitly pinned physical iPad.

### Work and verification

1. Inspect the source for aspect ratio, color profile, transparency, and edge
   clearance.
2. Normalize it to an opaque 1024×1024 sRGB PNG without changing the artwork.
3. Add a minimal iOS AppIcon set and register the asset catalog with the target.
4. Validate asset metadata, image properties, project references, and diff
   hygiene; build and inspect on the pinned iPad when available.

### Acceptance evidence and stop conditions

- the canonical AppIcon source is square, exactly 1024×1024 pixels, opaque,
  and sRGB;
- the target resource phase includes the asset catalog and both Debug and
  Release select `AppIcon`;
- host checks pass and unrelated collaborator edits remain untouched;
- stop after host evidence is collected when Xcode/device prerequisites are
  unavailable, or after two asset-compilation failures without a narrower fix.

### Session log

- 2026-07-20 — Inspected the supplied 1259×1259 opaque sRGB JPEG. The artwork
  is already square with generous edge clearance, so began a preservation-first
  conversion and project integration rather than a generative redraw.
- 2026-07-20 — Converted the supplied artwork to an opaque 1024×1024 sRGB PNG,
  added a single-size universal iOS AppIcon set, registered the asset catalog in
  the target resources, and selected `AppIcon` for Debug and Release. JSON,
  image-property, project-reference, small-scale preview, and diff-hygiene checks
  pass; evidence is under `tmp/verify/pc-13-app-icon/`. Removed the root source
  JPEG after successful conversion at the user's request. Existing lasso/toolbar
  collaborator edits were preserved. Xcode asset compilation, installation, and
  home-screen inspection remain blocked because this host has no Xcode toolchain
  or pinned iPad session.
