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

Status: **implemented — host-checked; physical export verification blocked**

Target branch: `sive/dev`

Owner: App integration; PDF ink emission remains in `SpatialCanvas`, and the
native archive continues to reuse the existing notebook persistence model.

### Objective and user-visible outcome

Export the complete notebook rather than only the selected page: PDF contains
one drawing-only page for every notebook page in order, while SPUD losslessly
contains the complete editable notebook, including page identities, templates,
images, drawing layers, Agentic Layers, cover, settings, and timestamps.

### Scope

- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/Notebook/NotebookViewModel.swift`
- `TuberNotes/SpatialCanvas/PDFStrokeCompression.swift`
- `TuberNotes/SpatialCanvas/TuberNoteArchive.swift`
- `TuberNotes/Notebook/README-notebooks.md`
- `DeveloperTools/tests/test_archive_export_contract.py`
- this PC-9 plan section and session log

### Non-goals and dependencies

- Do not add archive import UI, change the system file-exporter presentation,
  alter toolbar layout, or emit Pins/conversations/citations into PDF.
- Preserve the existing compressed, drawing-only PDF privacy contract.
- Preserve decoding of existing version 1 and version 2 single-page SPUD files.
- Canonical build and interaction inspection require an explicitly named,
  pinned physical iPad and an Apple/Xcode host.

### Work and verification

1. Add ordered multi-page PDF emission without changing stroke compression.
2. Add a versioned whole-notebook SPUD payload with legacy decoding.
3. Route both notebook export entry points through the complete document.
4. Extend focused source checks for page ordering, completeness, and filenames.
5. Build and export a deterministic multi-page notebook on the pinned iPad;
   inspect PDF page count and decode the SPUD payload for complete page state.

### Acceptance evidence and stop conditions

- A notebook with multiple pages exports the same number of PDF pages in the
  same order; PDF remains drawing-only and contains no Agentic Layer content.
- SPUD round-trips all notebook pages and notebook-owned state while version 1
  and version 2 archives remain decodable.
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

Status: **follow-up implemented — host-checked; physical-device verification blocked**

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
