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

## Active line — PC-10: ephemeral OpenAI account login

Status: **implemented and installed — awaiting Phillip's live token-exchange
verdict**

Target branch: `main`

Child work-line: [`PC-10-EphemeralOpenAILogin.md`](PC-10-EphemeralOpenAILogin.md)

Summary: add an OpenCode-style OpenAI device-code login to the normal Release
provider settings and normal Agentic Layer analysis path. Credentials remain in
process memory only; app relaunch, expiry, sign-out, or 401/403 requires relog.
Preserve explicit API-key/right.codes paths and the Release gateway boundary.
At Phillip's direction, do not use or modify the stale scenario/test harness;
Phillip will manually verify the normal app on the pinned iPad after separately
confirming live account use.

### Session log

- 2026-07-20 — Created the PC-10 implementation plan from `main` at `05d4af3`.
  Selected temporary device-code authorization with relog on launch/expiry,
  memory-only OAuth access, normal-app-only integration, and Phillip-led manual
  verification. No product source or account state was changed.
- 2026-07-20 — Phillip authorized implementation with extensive subagents and
  directed that PC-10 use no verification/review harness while implementation
  is underway. `AGENTS.md` now carries the narrow go-mode override.
- 2026-07-20 — PC-10 implementation is complete. Generic unsigned iOS Debug and
  Release builds succeeded; no harness, device, browser login, or live provider
  call ran. Phillip owns the remaining normal-app behavioral verdict.
- 2026-07-20 — Corrected the target after Phillip clarified that the normal
  Release app—not Debug—is used. Promoted the memory-only temporary login while
  keeping API-key/right.codes controls Debug-only. Exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` passed preflight; signed Release build,
  install, and normal no-scenario launch succeeded. Phillip owns behavioral
  verification.
- 2026-07-20 — Reopened for Phillip's requested in-app Safari presentation.
  Device auth, polling, credential lifetime, and provider routing remain
  unchanged; only the normal login presentation is in scope.
- 2026-07-20 — Embedded the device sign-in page in an in-app
  `SFSafariViewController` sheet while keeping polling independent of sheet
  presentation. Exact iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117` passed
  preflight; the fresh signed Release build succeeded, installed, and normally
  launched. No Debug build, scenario/test harness, visual verifier, automated
  login, or provider request ran. Phillip owns the remaining live sign-in
  verdict.
- 2026-07-20 — Rebuilt once more at Phillip's request from fresh DerivedData,
  then installed and normally launched that second signed Release artifact on
  the same pinned iPad. No Debug or verification harness ran.
- 2026-07-20 — Reopened after shared Safari cookies made an accidentally chosen
  OpenAI account sticky. Adding a user-triggered ephemeral system-auth route
  that preserves the active device-code poller and cannot reuse those cookies;
  no harness verification is authorized.
- 2026-07-20 — Added the explicit cookie-isolated different-account route,
  rebuilt signed Release from fresh DerivedData, installed it on the pinned
  iPad, and normally relaunched. The shared Safari route remains for ordinary
  SSO. Phillip owns the live account-selection verdict.
- 2026-07-20 — Reopened at Phillip's direction to make cookie-isolated
  authentication automatic for every primary sign-in/retry. Existing-browser
  session reuse becomes explicit secondary behavior.
- 2026-07-20 — Live browser authorization exposed an over-strict token decoder:
  it rejected a successful response when unused ID/refresh material was absent.
  The bounded repair requires only the access token TuberNotes actually keeps,
  preserves optional account-claim extraction, and retains redacted failures.
- 2026-07-20 — Delivered fresh-by-default sign-in and the tolerant, access-only
  token-establishment repair in a new signed Release build. Exact-device
  preflight, install, and normal launch succeeded; no harness or automated live
  login ran.

Shared-contract log — 2026-07-20: `CONTRACT:` introduce
`AgentRuntimeAccess` so Notebook can select either the existing provider-key
authorization or a request-scoped, memory-only `OpenAICodexAccess` without
owning endpoints or authorization headers. This changes only the internal
Notebook/AgentHarness handoff; no persisted document, Pin, coordinate, archive,
or Release authentication contract changes.

Shared-contract log — 2026-07-20: `CONTRACT:` revise `SPEC.md` section 10.1 so
the normal hackathon Release app may use the ephemeral, memory-only OpenAI
device-authorization route. The production gateway remains required for a
distributable service; reusable secrets, refresh persistence, and credential
reuse from other applications remain forbidden.

Shared-contract log — 2026-07-21: `CONTRACT:` at Phillip's direction, replace
relogin-on-every-launch with a device-only Keychain refresh grant. Access tokens
and account routing remain memory-only; launch, expiry, and matching 401/403
silently refresh; rejected refresh and explicit sign-out delete the Keychain
item and require normal sign-in. No password, 2FA value, identity token,
authorization code, verifier, copied credential, or provider API secret is
persisted.

- 2026-07-21 — Implemented the device-only Keychain refresh grant, rotated-token
  replacement, launch/expiry/authorization-rejection refresh, and destructive
  cleanup on sign-out or rejected refresh. Fresh sign-in clears an older grant
  before account selection. Generic unsigned Release build succeeded under
  `tmp/build/pc10-keychain-refresh/`; no harness, device action, automated
  account login, or provider request ran. Phillip owns the live refresh verdict.
- 2026-07-21 — Product commit `44c06f2` passed exact-device preflight, fresh
  signed Release build, install, and normal launch on Phillip's iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Evidence is under
  `tmp/build/pc10-keychain-refresh-device/`. No scenario, automated account
  action, provider call, or visual verifier ran; Phillip owns the live refresh
  verdict.

## Active line — PC-11: OpenAI-backed drawing refinement

Status: **stopped — private Codex route rejected image generation; lasso hero redirected to guidance Pins**

Target branch: `main`

Child work-line: [`PC-11-OpenAIDrawingRefinement.md`](PC-11-OpenAIDrawingRefinement.md)

Summary: connect the existing preview-first lasso refinement boundary to the
temporary OpenAI session when no dedicated backend is configured. Preserve all
lasso, stroke-containment, page-normalized placement, persistence, and explicit
Apply behavior. The private Codex route's image-generation capability remains a
live manual gate; no Debug or stale verification harness is authorized.

### Session log

- 2026-07-20 — Created PC-11 after Release surfaced the missing
  `TuberRefinementEndpoint`. Scoped the experiment to AgentHarness transport and
  decoding plus truthful copy; spatial and document contracts remain frozen.
- 2026-07-20 — Implemented the temporary-session Release refinement fallback.
  The exact pinned iPad passed preflight; a fresh signed Release build succeeded,
  installed, and normally launched from
  `tmp/build/pc11-openai-refinement/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness or automated provider call ran. Reinstalling
  clears the memory-only login, so Phillip owns the fresh-login and live
  image-tool verdict.
- 2026-07-21 — Phillip manually established that the private Codex route rejects
  `image_generation`. This line stopped at its planned capability boundary; the
  normal Release sparkle-lasso must not mutate ink or images and is now covered
  by the PC-12 structured guidance-Pin path.

## Planned line — PC-12: Release AI runtime unification and interaction hardening

Status: **in progress — corrected P0 lasso-to-guidance-Pins path implemented; manual gate pending**

Target branch: `main`

Child work-line: [`PC-12-ReleaseAIRuntimeUnification.md`](PC-12-ReleaseAIRuntimeUnification.md)

Summary: consolidate temporary OpenAI authorization, capability routing,
bounded transport, and generation-scoped invalidation inside AgentHarness;
make the normal sparkle-lasso produce structured, spatially anchored guidance
Pins without generating or replacing drawings; make normal requests cancellable
and stale-result safe; then separately decide whether to add local
`search_textbook` retrieval. Debug/scenario tooling is explicitly excluded.

### Session log

- 2026-07-21 — Screenshot feedback exposed shallow OCR narration (“This is
  labeled test”) and expanded-card overlap. Generation now permits only 1–4
  concise teaching moves, explicitly rejects transcription/meta-label filler,
  and locally filters known shallow patterns. Compact expanded cards are
  228×126 points, omit the drag-help row, and temporarily hide sibling labels
  while retaining their Pin dots. Generic unsigned Release build succeeded
  under `tmp/build/pc12-instructional-pins/`. Commit `2a84f84` then passed
  exact-iPad preflight, fresh signed Release build, install, and normal launch
  from `tmp/build/pc12-instructional-pins-device/`. No automated provider call
  or scenario ran; Phillip's regenerated-result verdict remains pending.
- 2026-07-21 — Made hero guidance labels smaller and spatially stable during
  zoom. The hero overlay now uses fixed compact screen-point dimensions and a
  deterministic offset from each page-normalized Pin anchor, with no viewport
  clamping or collision-driven side switching; adaptive behavior elsewhere is
  unchanged. Generic unsigned Release build succeeded under
  `tmp/build/pc12-stable-compact-pins/`. Commit `da2b93d` then passed exact-iPad
  preflight, fresh signed Release build, install, and normal launch from
  `tmp/build/pc12-stable-compact-pins-device/`. No scenario or automated
  provider call ran; Phillip's visual zoom verdict remains pending.
- 2026-07-20 — Three user-requested `gpt-5.6-terra` subagents independently
  inventoried Release/dormant AI surfaces, designed the smallest unification
  seam, and audited user-visible AI lifecycle/safety. Their read-only findings
  were synthesized into a six-phase patch plan with exact ownership, files,
  dependencies, manual gates, risks, and stop conditions.
- 2026-07-21 — Corrected the Release hero interaction to lasso crop vision,
  strict `place_pins` output, crop-to-page coordinate conversion, and immediate
  Agentic Layer Pin persistence. Central temporary route/transport and
  generation checks are in scope; image generation, raster Apply, and
  stroke deletion are excluded. No build, device action, harness, or provider
  call ran during this implementation session.
- 2026-07-21 — Removed the rejected image-generation client and completed the
  structured-Pin integration with bounded SSE/complete response handling and
  crop bounds matching the transmitted pixels. Exact-device preflight and a
  fresh signed Release build/install/normal launch succeeded from
  `tmp/build/pc12-guidance-pins/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness or automated provider call ran. Phillip owns
  the live Pin-placement verdict after a fresh sign-in.
- 2026-07-21 — Restored Phillip's exact hero flow after the first P0 wiring had
  incorrectly repurposed the ordinary selection interaction: Pencil-only Magic
  Eraser circle → retained pulsing halo → structured short guidance Pins → hold
  any Pin for the full-width Pin Chat tab. Crop-relative outputs still map
  through the existing page-normalized spatial transform; ink is untouched.
  Fresh exact-device signed Release build/install/normal launch succeeded from
  `tmp/build/pc12-magic-eraser-hero/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness or automated provider call ran.
- 2026-07-21 — Live manual feedback showed the restored flow still activated a
  page-wide rainbow and silently rejected ordinary circles. Removed that glow
  and automatic send. Magic capture now accepts Pencil/touch with forgiving
  closure and visible rejection feedback, retains a local halo, then presents
  Explain / Check / Ask before sending the polygon-masked crop and chosen
  prompt. Fresh exact-device signed Release build/install/normal launch
  succeeded from
  `tmp/build/pc12-magic-prompt-flow/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness or automated provider call ran.
- 2026-07-21 — Replaced the bottom-anchored post-circle chooser with an
  automatically visible context menu attached to the halo and clamped within
  the page. A valid circle now keeps its selection/menu even when no ink or
  image layer was recognized, and no provider request begins until Explain,
  Check, or Ask is chosen. Fresh exact-device signed Release
  build/install/normal launch succeeded from
  `tmp/build/pc12-attached-context-menu-v2/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness, visual verifier, automated login, or provider
  request ran.
- 2026-07-21 — Fixed retained selection drift across zoom by reprojecting the
  saved page-normalized lasso whenever its page viewport changes and reporting
  the final recentered viewport after zoom. Fresh exact-device signed Release
  build/install/normal launch succeeded from
  `tmp/build/pc12-zoom-stable-selection/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness or visual verifier ran.
- 2026-07-21 — Fixed the silent post-Explain failure path: provider/decoder
  errors now appear directly in the attached selection menu with retry actions,
  and the bounded single-call decoder accepts Codex-compatible
  `response.output_item.done` completion. Fresh exact-device signed Release
  build/install/normal launch succeeded from
  `tmp/build/pc12-visible-pin-result/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness, visual verifier, automated login, or provider
  request ran.
- 2026-07-21 — Manual retry confirmed the private Codex endpoint was not
  returning the forced function-call dialect. Switched Pin generation to a
  strict Responses `text.format` JSON schema, which matches the actual need for
  structured UI data while preserving the same masked image, prompt, validation,
  and crop-to-page placement. Fresh exact-device signed Release
  build/install/normal launch succeeded from
  `tmp/build/pc12-structured-pin-text/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness, visual verifier, automated login, or provider
  request ran.
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

## Active line — PC-16: drawing-tool width selection borders

Status: **follow-up implemented — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Owner: App/Notebook toolbar UI; `SpatialCanvas` retains ownership of Pencil
input, canvas coordinates, and rendered ink.

### Objective and user-visible outcome

Make every selected drawing-tool button use a restrained circular border whose
thickness grows with the tool's actual selected point width, so Pen, Pencil,
Highlighter, and Eraser all give a useful preview without overwhelming the
glyph or toolbar.

### Scope

- `TuberNotes/Notebook/NotebookToolbar.swift`
- the focused toolbar source regression check
- this PC-16 plan section and session log

### Non-goals and dependencies

- no PencilKit tool, persisted width, width range, gesture, color, layout,
  spatial-coordinate, or shared-contract changes;
- no changes to non-drawing selection states;
- canonical build and visual inspection require an Apple/Xcode host and an
  explicitly pinned physical iPad.

### Work and verification

1. Map each selected drawing tool's actual width through one monotonic,
   visually bounded scale and use that result for its border.
2. Preserve the existing button frame, tap/hold gestures, color treatment,
   and accessibility value.
3. Add a focused source assertion, run the toolbar check, and inspect the diff.
4. Run `blank-notebook` on the pinned iPad and inspect minimum/default/maximum
   widths for all four tools for clipping, overlap, and a truthful proportional
   preview.

### Acceptance evidence and stop conditions

- each selected drawing-tool border grows monotonically with
  `vm.width(for: tool)` but stays within a compact visual range, without
  altering the canvas width value or selection gesture;
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
- 2026-07-21 — User follow-up clarified that borders should be relative rather
  than literal and should cover every drawing tool. Replaced the Pen-only exact
  width with one monotonic square-root scale for Pen, Pencil, Highlighter, and
  Eraser, bounded to 1.5...7 points so large marker/eraser values do not crowd
  the 17-point glyph or change the 34-point button footprint. Removed the now-
  obsolete color-contrast-only outline path and strengthened the focused check
  to require the shared all-tool mapping. All four toolbar selection tests and
  `git diff --check` pass. Xcode build, `blank-notebook`, screenshots,
  console/crash collection, and visual-taste checks remain blocked because
  this host still has no Xcode toolchain or pinned physical-iPad session. No
  drawing, persistence, spatial, gesture, or shared contract changed.

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

## Active line — PC-18: Reasoning Pins — Calculus Check + Ochem Explain

Status: **implementation complete and Release-delivered — actual normal-app golden interactions and Phillip verdict pending**

Target branch: `main`

Child work-line:
[`PC-18-InstructionalInterventionEngine.md`](PC-18-InstructionalInterventionEngine.md)

Owners: App integration and in-product intervention policy/transport/validation;
Notebook user intent and lifecycle; SpatialCanvas geometry; Pins presentation.

Summary: prove one Reasoning Pin interaction across two prepared learning
problems: Check catches the missing `½` in the handwritten Calc I integral
`∫x e^(x²) dx`, while Explain describes electron flow in a clean SN2 PDF
reaction. The feature set is reverse-derived from those two moments: typed
intent, high-fidelity tight/context crops, Calc and Ochem evidence bases, one
Pin by default, transient correct/missing-context outcomes, retained selection,
and existing page-normalized persistence. Reference-case/evaluator artifacts
document the intended semantics but no longer count as acceptance evidence;
five repeated normal-app runs per golden problem are the behavioral gate.
General CAS/OCR/chemical parsing, broad subjects, multi-call critics, atom-level
anchors, and live follow-up generation remain outside the hackathon scope. The
child plan now supplies one coordinator delivery goal and four fan-out/fold-in
stages: read-only contract/image/eval attacks, non-overlapping implementation
packages, independent Calc/Ochem/product audits, and coordinator-owned device
delivery. Every subagent packet names prerequisites, files, non-goals, checks,
and a concrete return contract.

### Session log

- 2026-07-21 — `CONTRACT:` Phillip specified regional replacement semantics for
  accumulated guidance. Closing a new Magic Lasso now cancels prior analysis
  and persistently removes selected-layer, current-page Pins anchored inside
  the exact lasso polygon, including every descendant branch. Other regions and
  layers are preserved. The signed Release build under
  `tmp/build/pc18-regional-disposal/` succeeded, installed, and normally
  launched on only Phillip's pinned iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`.
- 2026-07-21 — Phillip's current-app screenshot proved the prior schema repair
  did not clear the live provider rejection. `CONTRACT:` PC-18 normal Release
  Check/Explain no longer depends on provider structured output or model Pin
  coordinates. It uses the authenticated multimodal insight route, accepts only
  bounded non-observational teaching Markdown, derives a compact plain-text
  answer title, and anchors one response to the selected region with existing
  crop-to-page geometry. Unreadable/generic/context-seeking results remain
  silent. The signed Release build under `tmp/build/pc18-teaching-route/`
  succeeded, installed, and normally launched on only Phillip's pinned iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`; his repeat live interaction is the
  remaining verdict.
- 2026-07-21 — Phillip's first normal Release test found that the live
  structured-Pin request could be rejected before inference and that generic
  clarification/observational copy violated the learning interaction. PC-18's
  bounded correction changes the structured-output wire schema to a supported
  closed root object while preserving strict local outcome validation, silences
  needs-input/no-action toasts, and requires useful teaching guidance rather
  than transcription, context requests, or generic follow-up labels. The
  signed Release build under `tmp/build/pc18-live-correction/` succeeded,
  installed, and normally launched on only Phillip's pinned iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`; his repeat live interaction is the
  remaining verdict.
- 2026-07-21 — Phillip declared the Debug/fixture verification surface
  non-representative and paused PC-18. Its prior results are invalidated as
  acceptance evidence. `AGENTS.md` now requires the actual normal Release app;
  Debug scenario routing and the scenario, structured-review, and Pencil
  fixture entry points are disabled. No further PC-18 verification ran.
- 2026-07-21 — Status audit after the pause: PC-18 implementation, integration,
  bounded correction, signed Release build, installation, and ordinary launch
  remain valid completed work. Debug/fixture/evaluator results do not. The line
  is therefore implementation-complete and Release-delivered, but not
  behaviorally accepted: five real Calc runs, five real Ochem runs, live
  latency, actual-app spatial/visual/crash inspection, and Phillip's verdict
  remain the only completion gate.
- 2026-07-21 — `CONTRACT:` extend `SelectionArtifact` with an optional,
  orientation-only context crop and introduce the versioned
  `InterventionOutcome`/typed Calculus and Organic Chemistry evidence contract.
  Provider coordinates remain bound exclusively to the tight crop. Only
  `spatialGuidance` persists one Pin/chat root; confirmation, needs-input, and
  no-action are successful nonpersistent outcomes. This is required to prevent
  forced Pins and make academic claims mechanically rejectable without changing
  page-normalized persistence or subsystem ownership.
- 2026-07-21 — Fold-in 2 completed: strict intervention decoding, lossless
  tight/context evidence, typed Notebook persistence/transient handling,
  twelve-case assets/evaluator, project membership, and SPEC integration.
  Generic Debug build, focused contract checks, evaluator self-test, and diff
  hygiene pass; independent Fold 3 audits started.
- 2026-07-21 — Fold 3 findings drove the one bounded correction pass: exact
  academic predicates plus app-owned visible copy, full narrow prompt support,
  transport image-boundary checks, selection/page/sign-in/retry lifecycle
  repairs, retained-crop Ask, and timed confirmation. Host checks and generic
  Debug build pass; Fold 4 device/scenario delivery began.
- 2026-07-21 — Final mechanical delivery: contract/evaluator/asset/secret/diff
  host gates pass; exact-device `pin-drift` and `edge-pins` pass. Legacy
  `hero-recorded` and `agent-recorded-failure` launch but fail missing runtime
  evidence, retained as explicit failed artifacts. A fresh signed Release build
  succeeded, installed, and ordinarily launched on Phillip's pinned iPad.
  Phillip's normal-app five-run Calc and Ochem streaks, live latency and visible
  quality/crash verdict remain the only delivery-gate evidence not mechanically
  obtainable without his Pencil and device-owned OpenAI session.
- 2026-07-21 — Phillip authorized overnight PC-18 implementation-first
  execution. Gate 0 confirmed `main` at `e79abb4`, preserved existing work, and
  pinned only iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`. The normal
  structured-Pin route exists; device-owned live account transport proof is
  deferred to the delivery gate while host-safe folds continue.
- 2026-07-21 — Freeze 1 accepted the closed typed outcome/evidence contract,
  2x lossless tight/context image contract, and frozen twelve-case manifest
  with C5/C6/O5/O6 holdouts. Fold 2 began with non-overlapping AgentHarness,
  selection-evidence, and DeveloperSupport/DeveloperTools file leases.
- 2026-07-21 — Created the distinct PC-18 proposal after repeated live shallow
  narration demonstrated that forced Pin generation and phrase filtering were
  structurally insufficient. No product code or runtime state changed.
- 2026-07-21 — Product/demo, multimodal-systems, and one-week-delivery reviewers
  independently returned revise. Narrowed the proposal to a one-call,
  Check-first hero; recorded accepted, deferred, and partially accepted
  objections in the child plan. No implementation or device action ran.
- 2026-07-21 — Rewrote PC-18 backward from two golden problems: a missing-factor
  substitution integral and a canonical SN2 electron-flow explanation. The
  child plan now derives every required feature, fixture, and cut from those
  demonstrations. No product code or runtime state changed.
- 2026-07-21 — Added the orchestration layer: explicit coordinator goal and
  authority boundary, four dependency folds, bounded subagent assignments with
  non-overlapping file leases and return contracts, fold-in gates, and
  coordinator-only device/live-provider/final-judgment work.

## Active line — PC-19: coherent Pin Chat and safe Markdown

Status: **implementation complete and Release-delivered — awaiting Phillip's current-app verdict**

Target branch: `main`

Child work-line:
[`PC-19-PinChatMarkdown.md`](PC-19-PinChatMarkdown.md)

Owner: coordinator-owned Notebook/App integration; Pins spatial behavior and
AgentHarness provider/auth routing remain unchanged.

Summary: preserve complete bounded assistant responses as the existing
`PageAnnotation.body` text, render assistant-only safe Markdown through a
bounded reusable block renderer, derive syntax-free compact/accessibility
projections, and give the narrow Agentic Layer sidebar and full Pin Chat
distinct navigation/reading roles. Existing notebook/SPUD compatibility,
thread lineage, page identity, Pin anchors, retry/cancel behavior, credentials,
and provider routing remain intact. Deprecated review/feedback/scenario
conversation surfaces are prohibited and provide no acceptance evidence.

### Session log

- 2026-07-21 — Fold 1 completed read-only against `main` at `15f27ea`.
  Architecture, Markdown safety, and current-product iPad reviewers independently
  identified the lossy `AgentInsight` transform, synthetic-teaser semantics,
  duplicated sidebar/full-chat composition, raw Markdown preview/accessibility
  leakage, and scroll-away composer. The coordinator froze one source-preserving
  Markdown contract and one split UI contract in the child plan; Fold 2 begins
  with non-overlapping file leases. No prohibited deprecated tooling was used.
- 2026-07-21 — `CONTRACT:` add optional persisted
  `PageAnnotation.userPrompt` so new turns can distinguish literal user text
  from provider-authored Pin teasers without migrating existing notebooks or
  SPUD archives. Missing values are context-only; body source, IDs, lineage,
  page-normalized geometry, credentials, and provider routing are unchanged.
- 2026-07-21 — Folds 2/3 and the coordinator correction pass are complete.
  Complete assistant Markdown now persists unchanged; compact/accessibility
  projections are syntax-free; sidebar/full Pin Chat roles are distinct; send,
  cancellation, stale completion, pending prompt, page deletion, and lineage
  state are ownership-safe. Focused checks pass 12/12, generic Release passes,
  and commit `7f58de2` carries the required `CONTRACT:` prefix. Exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` passed preflight, signed Release
  build, install, normal no-scenario launch, and a live-process query. Evidence
  is under `tmp/build/pc19-pin-chat-markdown*/`. No deprecated review surface
  was used. Phillip's current normal-app interaction/visual verdict is the only
  remaining gate.

## Active line — PC-20: calm, content-preserving Pin cards

Status: **follow-up Release-delivered — awaiting Phillip's verdict**

Target branch: `main`

Child work-line: [`PC-20-CalmPinCards.md`](PC-20-CalmPinCards.md)

Owner: Pins spatial UI; Notebook integration, AgentHarness content, persistence,
page-normalized anchors, Pin Chat, and Pencil/canvas ownership remain unchanged.

Summary: collapsed Pins become a single unobtrusive anchor instead of a text pill;
expanded Pins use one connected, edge-aware, high-contrast card with readable
hierarchy, explicit dismissal, sufficient content room, and the existing direct
Continue path. Final visual and interaction judgment remains Phillip's in the
normal Release app.

### Session log

- 2026-07-21 — Created PC-20 from Phillip's normal-app screenshots and explicit
  request to revise the complete Pin presentation. Scoped the repair to Pins
  layout/presentation and preserved the unrelated untracked `.claude/` content.
- 2026-07-21 — Completed the Pins-only revision: collapsed text labels are gone;
  expanded normal-notebook cards are larger, opaque, connected, scrollable, and
  expose independent Pin Chat/Close controls. Focused checks pass 8/8 and diff
  hygiene passes. Signed Release build/install/normal launch and live-process
  query pass on exact iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`; evidence is
  under `tmp/verify/pc20-calm-pin-cards/`. Phillip's current normal-app visual,
  touch/Pencil, clipping/overlap, scrolling, and animation verdict remains.

## Active line — PC-21: Magic Lasso compact command strip

Status: **command strip implemented and Release-delivered — awaiting Phillip's verdict**

Target branch: `main`

Child work-line: [`PC-21-MagicLassoRadialMenu.md`](PC-21-MagicLassoRadialMenu.md)

Owner: Notebook presentation for the existing Magic Lasso result. Regular Lasso,
SpatialCanvas, AI runtime, coordinates, Pins, and persistence remain unchanged.

Summary: replace the wide gray Magic Lasso action pill with a compact monochrome
Explain/Check/Ask/Close command strip; Ask expands locally and analysis stays in
the same restrained footprint. No gradients, glows, circles, or pill buttons.

### Session log

- 2026-07-21 — Reopened the chat-sidebar addition after Phillip's major UX
  critique. Removed page/toolbar reflow and the page-blocking full-chat takeover:
  page geometry is invariant, while new, continued, Magic-Lasso-originated, and
  Pin-originated conversations now remain in a narrow trailing overlay without
  dimming or disabling note-taking outside its bounds. The sidebar also no longer
  changes notebook pages when responses arrive or branches are selected. Focused
  checks pass 11/11; signed Release build/install/normal launch/process presence
  pass on exact iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Evidence is under
  `tmp/verify/pc21-noninterrupting-sidebar/`; Phillip's verdict remains.
- 2026-07-21 — Added a direct top-bar open/close button for the existing chat
  sidebar, independent of Magic Lasso and the Layers popover. It activates the
  selected/default Agentic Layer when needed; lasso, AI, Pin, and spatial
  contracts remain unchanged. Focused checks pass 3/3; signed Release
  build/install/normal launch/process presence pass on exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Evidence is under
  `tmp/verify/pc21-chat-sidebar-button/`; Phillip's verdict remains.
- 2026-07-21 — Corrected the earlier misunderstanding after Phillip's screenshot:
  this line changes only the Magic Lasso's post-selection menu and explicitly
  preserves the separate regular and Magic Lasso tools.
- 2026-07-21 — Delivered the actual redesign: a transparent radial composition
  with three compact circular actions, gradient sparkle anchor, explicit Close,
  local Ask card, and progress orb replaces the wide gray pill. Focused checks
  pass 10/10; signed Release build/install/normal launch/process query pass on
  exact iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Artifacts are under
  `tmp/verify/pc21-magic-lasso-radial/`; Phillip's current-app verdict remains.
- 2026-07-21 — Phillip rejected the radial gradient/orb treatment as tacky and
  selected the monochrome command strip. Reopened PC-21 for that presentation-
  only correction; regular and Magic Lasso remain separate and unchanged.
- 2026-07-21 — Delivered the selected monochrome direction: one 48-point charcoal
  Explain/Check/Ask/Close strip with hairline separators, matching local Ask field,
  and in-strip progress. No gradient, glow, circle, badge, or pill remains in the
  Magic Lasso menu. Focused checks pass 10/10; signed Release build/install/normal
  launch/process query pass on exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Current artifacts are under
  `tmp/verify/pc21-magic-lasso-command-strip/`; Phillip's verdict remains.

## Active line — PC-22: Magic Lasso polish and direct-to-chat mode

Status: **implementation complete and Release-delivered — awaiting Phillip's verdict**

Target branch: `main`

Child work-line: [`PC-22-MagicLassoPolish.md`](PC-22-MagicLassoPolish.md)

Owner: coordinator integrates; subagents have non-overlapping SpatialCanvas
animation, NotebookToolbar entry UI, and focused-check leases.

Summary: preserve separate regular/Magic Lassos; add Guidance Pins versus Send
to Chat choices to the bottom Magic Lasso bubble, route the latter through the
existing captured-selection analysis into full Pin Chat, and add a restrained
living trace plus closed-loop seal animation without changing geometry/runtime
contracts.

### Session log

- 2026-07-21 — Started PC-22 at Phillip's explicit request for subagent execution.
  Frozen interpretation: Send to Chat arms the next Magic Lasso and opens full
  Pin Chat around the existing analysis result; it does not combine lasso tools.
- 2026-07-21 — Integrated the bounded toolbar, trace/seal, and source-contract
  slices. Focused checks pass 15/15 and diff hygiene passes. Signed Release build,
  install, normal launch, and process query passed on Phillip's pinned iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` (PID 2596). Regular and Magic Lassos remain
  separate; Phillip's Pencil feel, animation taste, and end-to-end mode verdict remain.

## Active line — PC-23: contextual sidebar agent tools

Status: **implemented — awaiting build delivery and Phillip's verdict**

Target branch: `main`

Child work-line: [`PC-23-SidebarAgentTools.md`](PC-23-SidebarAgentTools.md)

Summary: truthful new-chat copy, bounded previous/current/next page images,
strict locally validated `place_pins` and `switch_page` model tools, and an
inline route-approved model selector in the non-modal chat sidebar.

### Session log

- 2026-07-21 — Removed the purple focused-turn treatment and simplified the
  transcript toward standard chat composition: neutral right-aligned user
  bubbles, plain assistant responses, and no current-turn glow/badge/border.
- 2026-07-21 — Simplified fresh-chat copy to `Ask a question…`; adjacent page
  images remain model-only request context and are not exposed in sidebar UI.
- 2026-07-21 — `CONTRACT:` extended `ProductToolName` with `switch_page` and
  extended the App-owned insight boundary with bounded page-image context and
  typed tool results. AgentHarness may request actions but cannot mutate the
  notebook; Notebook validates page/count/coordinate/text/staleness bounds before
  applying them.
- 2026-07-21 — Implemented all four requested sidebar changes. Focused checks
  pass 12/12; signed Release build/install/normal launch/process presence pass
  on exact iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Evidence is under
  `tmp/verify/pc23-sidebar-agent-tools/`; Phillip's live model/tool and normal-app
  UI verdict remain.

## Active line — PC-22: universal draggable toolbar dock

Status: **implementation complete and Release-delivered — awaiting Phillip's verdict**

Target branch: `main`

Child work-line: [`PC-22-UniversalToolbarDock.md`](PC-22-UniversalToolbarDock.md)

Owner: App/Notebook toolbar presentation; SpatialCanvas and page content
coordinates remain unchanged.

Summary: move image import into the main toolbar, let a dedicated grip drag and
snap that toolbar to any iPad edge, and persist one app-wide dock across all
notebooks and pages.

### Session log

- 2026-07-21 — Created PC-22 for Phillip's requested toolbar move and universal
  dock behavior. Implementation is scoped to Notebook toolbar presentation and
  its app-wide placement preference.
- 2026-07-21 — Delivered the toolbar image picker, dedicated grip, four-way
  nearest-edge snap, side-aware vertical layout, and universal persisted dock.
  PC-22 checks pass 3/3; signed Release build/install/normal launch/process
  query pass on exact iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Artifacts
  are under `tmp/verify/pc22-universal-toolbar-dock/`; Phillip's current normal-
  app interaction and visual verdict remains.
- 2026-07-21 — Reopened PC-22 to remove page navigation and Pencil from the
  floating toolbar and enforce Phillip's requested compact tool ordering. This
  remains a toolbar-presentation change; drawing and page contracts are intact.
- 2026-07-21 — Delivered Pen → marker/highlighter line → Eraser → Lasso → Magic
  Lasso → Image → Undo → Redo → Layers. Pencil and page navigation are absent
  from the floating toolbar, and the obsolete page-navigation settings toggle
  is removed. PC-22 checks pass 4/4; signed Release build/install/normal launch/
  process query pass on the exact pinned iPad. Phillip's verdict remains.

## Integration — `sive/dev` into `main`

Status: **implementation merged and Release-delivered — Phillip's verdict pending**

- 2026-07-21 — Integrated the gesture welcome lightbox, lasso/image stability,
  and visual page-settings gallery from `sive/dev` while preserving `main`'s
  non-modal chat sidebar, calm Pin cards, draggable toolbar organization, Magic
  Lasso behavior, and contextual agent tools. `CONTRACT:` each spatial Pin now
  owns its conversation messages; ordinary replies and explicit message forks
  append within that Pin. A fork icon beside each agent response selects the
  parent for a message-level branch and never creates another spatial Pin.
- 2026-07-21 — Focused host contracts pass 29/29 and `git diff --check`
  passes. Phillip reported the physical iPad is disconnected and explicitly
  directed a compile-only simulator override. The generic iOS Simulator Release
  build succeeded for arm64 and x86_64; log:
  `tmp/build/merge-sive-dev-simulator/build.log`. No simulator launch or
  behavioral acceptance was performed. Canonical physical-device delivery and
  Phillip's normal-app verdict remain pending. The full host suite
  passes 87/94; seven stale/unrelated assertions remain in agent-content,
  provider-access, Magic-Lasso routing, scroll-direction, tool-selection, and
  verifier-truthfulness contracts. Full log:
  `tmp/merge-sive-dev-host-tests.log`.
- 2026-07-21 — After Phillip reconnected the named iPad, device preflight,
  signed Release build, install, normal no-scenario launch, and live-process
  query all passed on physical device
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` (UDID
  `00008103-000145D91107001E`, PID 2669). Evidence is under
  `tmp/build/merge-sive-dev-device/`. No Debug scenario or behavioral fixture
  was used; Phillip's normal-app visual, interaction, and message-thread/fork
  verdict remains the acceptance gate.
