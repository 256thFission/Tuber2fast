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

Status: **implemented — host-checked; awaiting pinned-iPad verification**

Target branch: `sive/dev`

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

## Active line — PC-4: synchronized unlocked zoom

Status: **implementation complete — physical-device verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-4-SynchronizedZoom.md`](PC-4-SynchronizedZoom.md)

Summary: the bounded implementation is complete and host hygiene/coordinate
checks pass. Canonical build, `pin-drift`/`fake-pin`/`multi-pin`, live pinch,
and visual inspection remain blocked because this Linux host has no Swift/Xcode
toolchain or explicitly pinned physical iPad session.

## Active line — PC-5: branch logic integration

Status: **implementation complete — host-checked; physical visual verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-5-BranchLogicIntegration.md`](PC-5-BranchLogicIntegration.md)

Summary: adapt the behavior from `origin/feat/pencil-pro-compat` and the latest
available `origin/claire/bleh` to the current notebook architecture without
merging branch histories, replacing newer files, or reverting current zoom,
export, toolbar, persistence, and visual repairs. Forward turns now move the
complete current page left and insert the next page from the physical right;
backward turns apply the inverse. The redundant always-forward layer transition
was removed. Host checks pass; canonical device visual verification remains
blocked by the absent Apple/Xcode host and pinned iPad session.

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

## Active line — PC-6: agent provider unification

Status: **implemented — host-checked; Apple/device verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-6-AgentProviderUnification.md`](PC-6-AgentProviderUnification.md)

Summary: adapt provider/model and external Responses-gateway behavior from
`origin/workspace/shaftatron-torture-DONT-MERGE-THIS-SHIT` into the newer
AgentHarness contracts so the normal Agentic Layer sidebar and streamed
Pin/conversation client share one provider-access value. Preserve recorded/demo
defaults, strict spatial validation, credential boundaries, and the separate
image-refinement backend contract.

Host implementation and scoped checks pass. Canonical Swift/Xcode build,
physical-iPad scenarios, normal-product visual inspection, and separately
authorized live-provider evidence remain blocked because this host exposes no
Apple or Swift toolchain.

## Active line — PC-7: Agentic Layer, conversation-tree, and movable-Pin interaction cleanup

Status: **implementation complete — host-checked; physical-device verification blocked**

Target branch: `sive/dev`

Child work-line: [`PC-7-AgentLayerPinInteraction.md`](PC-7-AgentLayerPinInteraction.md)

Summary: make the normal notebook's Agentic Layer read as one of two honest
user-visible states—hidden or active—without conflating an open layer picker
with active page content. Reuse the existing page-normalized Pin contract to
make conversation Pins draggable and persisted; render those durable Pins as
a branchable tree in the normal Agent sidebar; remove dead follow-up
affordances; and route supported Pin follow-ups into the matching tree node.

Shared-contract log — 2026-07-20: `CONTRACT:` add
`PinOverlayEvent.moved(annotationID:target:)` so the Pins-owned drag gesture can
hand one page-normalized final anchor to its coordinator-owned persistence
path. No persisted type, page identity, provider/runtime boundary, or
coordinate representation changes.

Shared-contract log — 2026-07-20: `CONTRACT:` add optional
`PageAnnotation.parentThreadID` so existing persisted Pin annotations can
express branch topology without a second conversation store. Older notebook
and SPUD payloads decode the missing optional value as a root; page identity,
annotation identity, and existing thread IDs are unchanged.

Host implementation and scoped checks pass. Canonical build, the named Pin
scenarios, normal-product tree/drag inspection, screenshots, console/crash
evidence, and human interaction judgment remain blocked because this Linux
workspace has no Apple/Swift toolchain or explicitly pinned physical-iPad
session.

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
