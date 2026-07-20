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
