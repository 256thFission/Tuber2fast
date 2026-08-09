# Overnight brief — the library layer

You are the managing agent for one overnight run. You direct subagents, you
do not do all the work yourself. Your job is to arrive at morning with a
**working, human-testable library and folder system** on its own branch,
plus the documents that make your reasoning auditable.

Nobody will be awake to unblock you. Every ambiguity is yours to resolve and
to record. Do not stop to ask.

---

## The goal

TuberNotes today opens exactly one hardcoded document. Everything below that
point is deep — ink, images, PDFs, per-page geometry, layer selection with
transform and undo, a lens renderer, per-layer granular saves. There is no
library, no second document, no folders, and no browser.

Build that layer, modelled closely on GoodNotes, which is the interaction
design this project is explicitly targeting parity with.

**The deliverable is a person tapping through a library in the simulator in
the morning.** This feature is unusual for this codebase in that it needs no
Apple Pencil: the whole thing is verifiable in the pinned simulator, so
"untestable without hardware" is not available to you as an excuse here.

---

## Read first

- `AGENTS.md` — the agent contract, and the build commands.
- `Docs/Contract.md` — the rules in force.
- `Docs/Contract.proposed.md` — **read this too, and understand its status.**
  Roughly thirteen amendments are marked FORCED, meaning the code implements
  them and `Contract.md` has not caught up. The contract lags the code in
  exactly the places that file lists. You must reason against the union of
  both documents.
- `CONTRIBUTING.md` — the loop and the evidence standard.
- `Docs/Unproven.md` — what this project has not earned.

**Ignore `Docs/Queue.md`.** It is known to be stale and is being restructured.
Do not treat it as a description of current state and do not update it.

---

## Hard constraints

1. **No agent authors a rule — but you do write the staging area.** You may
   not edit `Docs/Contract.md`. You **should** edit
   `Docs/Contract.proposed.md`, which exists precisely for this: a staging
   file written by an agent so Phillip can edit, cut, and adopt in the
   morning. Add your amendments there, in that file's existing format —
   the section edited, what is there now, the proposed replacement, why,
   and which phase forces it. Nothing you write there is in force, and
   saying so in the file is part of the format.

   The line an agent crossed once before: it wrote its amendments straight
   into `Contract.md` and tagged the commit `CONTRACT:`. Its code was kept
   and its contract edit was reverted. Stage; never adopt.

   **Expect to write a lot here.** The contract in force was written for a
   single hardcoded document, and most of it has never had to mean anything
   at the library level. `Durable form` describes one package. `Owners`
   settles ownership inside one document. `Lifecycle` opens and closes one
   thing. A library does not merely add rules to that — it changes what
   several existing rules are *about*, and some will read as wrong once
   there is more than one of everything. Rewriting them in the staging area
   is the expected outcome of this run, not a sign something went sideways.
   Follow the file's own convention and mark each amendment FORCED (code
   written), AHEAD (no code yet), or LANDED, so the morning reader can tell
   which ones are already load-bearing.
2. **Work on your own branch**, cut from `canvas-feature-complete`. Never
   merge to `main`. Never force-push anything you did not create.
3. **`project.yml` is the only project source.** The `.xcodeproj` is
   generated and gitignored; an edit to it is silently lost. Change
   `project.yml`, then `xcodegen generate`.
4. **CI must be green**: build and full test suite against the simulator
   pinned in `Tools/pinned-simulator`. A red suite at morning is a failed run
   regardless of how much was built.
5. **Do not weaken an existing test or a structural rule to make your code
   fit.** If a machine-checked rule blocks you, that is a finding to write
   up, not an obstacle to route around. Widening
   `ContractStructureTests` counts as authoring a rule.
6. **Do not report anything as working that you have not observed working.**
   This codebase's entire culture is earned evidence. "It compiles" is not
   "it works", and CI is explicitly silent about feel.

---

## Phase 1 — Research the target (subagents, web, vision)

Produce a comprehensive specification of exactly how GoodNotes' library and
folder system looks and behaves.

### Start from the primary source

`images/` holds **eight first-party screenshots of GoodNotes on iPad**,
captured from Phillip's own library. They outrank anything on the web.
Read every one of them with vision before you search for anything, and
where a web source contradicts a screenshot, the screenshot wins.

All eight are landscape, dark mode, sidebar open, same session.

| File | Shows | Worth noting |
|---|---|---|
| `01-library-grid-root.png` | Root `Documents` grid, 4 columns | Folders and documents interleave in **one grid sorted by the same key**. Cell = portrait first-page thumbnail (real ink and real PDF covers), title + chevron menu affordance, grey date line, favorite star in the thumbnail's top-right. Folders are a flat saturated folder glyph in the same footprint. |
| `02-library-grid-favorites.png` | `Favorites` smart collection | Flat collection mixing folders and documents from different parents; **no `+ New`** button. Long titles middle-truncate or wrap to two lines, so row heights vary. |
| `03-new-menu-popover.png` | The `+ New` popover | One unified creation entry point: 3 large tiles (Notebook, Whiteboard, Text Doc), 2 wide tiles (Import, Quick Record), a list (QuickNote, Scan Documents, Study Set, Image, Take Photo), then **`Folder` alone in its own card at the bottom**. |
| `04-new-folder-sheet.png` | New Folder modal | Live folder preview, centered `Untitled` placeholder field, `Color`/`Icon` segmented control, **27 swatches (9 hues × 3 tints) plus a custom picker**. Folder model needs name, color, icon. |
| `05-folder-empty.png` | Inside an empty folder | Entering a folder is a **push inside the content pane** — big left title becomes small centered title, back chevron appears, sidebar selection unchanged, **no breadcrumb**. `+ New` is contextual. Designed empty state with illustration and copy, no button. Sync-error cloud plus a bottom banner. |
| `06-new-notebook-sheet.png` | New Notebook modal | Same modal chrome as the folder sheet (circular X left, centered title, blue circular check right) — **build one reusable shell**. Name, Language, Cover toggle, Size, Color; scrollable categorized paper-template catalog. |
| `07-page-size-picker.png` | Size dropdown | **Orientation is orthogonal to size**: Portrait/Landscape segmented control above a closed list (Goodnotes Standard, A3–A7, Letter, Tabloid) plus `Custom` pushing to its own screen. |
| `08-view-options-menu.png` | View-options menu | The grid icon opens a combined menu: `Select Items`, then Grid/List, then four sort keys — **Date Created, Last Modified, Name, Type — defaulting to Last Modified descending**, direction shown as a chevron on the active key. |

Shared chrome across the set: a floating rounded sidebar (~28% width) with
Documents / Favorites / Shared / Marketplace and a collapse toggle; a
floating top-right capsule with search, a badged bell, and an avatar; a
toolbar row carrying a left `All` filter control and, at right, the blue
`+ New` pill, the view-options icon, and a live sync-status cloud.

### Then fill the gaps

The screenshots do **not** cover these, and each is a real hole a builder
would otherwise guess at. Make them the spine of your web research:

list view · multi-select mode and its editing toolbar · the per-item
context menu behind every cell's chevron (rename, duplicate, move, share,
delete — entirely unconfirmed) · the move/destination picker · drag and
drop and drop-target highlighting · trash and delete confirmation · search
UI and whether it searches content or only titles · the `All` filter's
options · the folder `Icon` tab's icon set · editing an existing folder ·
**nesting past one level, and whether a breadcrumb ever appears** · the
root/first-run empty state · light mode · portrait and collapsed-sidebar
layouts · thumbnail loading placeholders · whether the large title
collapses on scroll.

Fan out subagents across independent angles rather than doing one linear
sweep — official documentation and support pages, hands-on reviews, video
walkthroughs, screenshot galleries, teardowns, user complaints about the
system (complaints are unusually informative about interaction detail).

Use vision on every screenshot you can actually retrieve. Where you cannot
retrieve an image, say so rather than describing from memory — a
confabulated UI detail is worse than an acknowledged gap, because it will be
built.

The spec must cover at minimum:

- The document browser: grid and list presentations, what a cell shows,
  covers and thumbnails, sizing, spacing, typography.
- Folder model: nesting, depth limits, how a folder cell differs from a
  document cell, what happens to an empty folder.
- Navigation: entering and leaving folders, breadcrumbs, back behavior,
  where the current location is displayed.
- Creation: the new-document and new-folder flows, naming, defaults,
  templates, where the affordance lives.
- Manipulation: rename, move, duplicate, delete, multi-select, drag and
  drop, long-press menus, swipe actions.
- Sort and filter: available orders, where the control lives, persistence.
- Search: scope, what is matched, results presentation.
- Trash / recently deleted, if present, and its retention behavior.
- Favorites, tags, or starred, if present.
- Empty states, loading states, and error states.
- iPad-specific structure: sidebar, split view, multi-column behavior,
  keyboard and pointer support.

For each element, record **what it is, how it behaves, and how confident you
are**, with the source. Distinguish observed-in-a-screenshot from
described-in-prose from inferred. This distinction is load-bearing for
whoever reads it next.

Write this to `Docs/Forks/Library/01-goodnotes-spec.md`.

---

## Phase 2 — The proposal

Translate the spec into a proposal for *this* codebase. Not a port — a
design that fits the architecture and the contract that already exist.

It must include:

- The durable form. What a library is on disk, how documents are
  enumerated, where folder structure lives, what file is read at open.
  Reason from the same principles `Durable form` already applies one level
  down: no whole-library read, no duplicated truth, write order leaf to
  root, orphans inert and dangling refs fatal.
- Ownership. Every new piece of state, its single writer, its frequency,
  its lifetime — in the shape of the table in `Owners`.
- The failure story. What a corrupt library index does, what a document
  that will not open does to the browser around it, what a dangling
  document ref means.
- The UI architecture, and how it hands off to the existing editor session.
- What you are building and what you are deliberately not building.

**Four collisions with the contract are foreseeable. Reason about each
explicitly rather than discovering them in code:**

- **Thumbnails.** GoodNotes shows page thumbnails and covers. `Forbidden
  patterns` bans a durable derived artifact, and A7's proposed narrowing
  permits only a disposable render of an *immutable asset*. A thumbnail of a
  page containing ink is derived from something mutable and is still banned.
  Either the browser shows something other than page content, or this needs
  an amendment with a real argument behind it.
- **File I/O confinement.** A machine-checked rule confines file I/O to
  `DocumentStore`. Enumerating a library is file I/O. Decide whether the
  library store *is* `DocumentStore`, a sibling with its own allowlist
  entry, or a rule that needs amending — and argue it.
- **Page deletion and the index-keyed runtime.** The runtime is index-keyed
  while the session is identity-keyed, which is correct today only because
  the page list is append-only. A library brings document and page deletion.
  If your scope touches deletion of pages, the opaque-page-token work is in
  scope with it; if it does not, say so and say why the boundary holds.
- **Nothing synchronous on interaction paths.** Enumerating documents,
  reading a library index, and rendering any cell imagery are all
  file-and-decode work. None of it may land on main or on a scroll path.

Write this to `Docs/Forks/Library/02-proposal.md`.

---

## Phase 3 — One full adversarial review cycle

Spawn a review panel of **fresh subagents with no authorship stake** in the
spec or the proposal. Do not let the agents who wrote a document review it.

Give reviewers distinct lenses rather than the same lens repeated — at
minimum: contract compliance, durable-form and failure design, interaction
and UX fidelity against the Phase 1 spec, and buildability within the
remaining hours.

**One reviewer's whole assignment is your proposed amendments.** Are they
the smallest change that admits a library, or did you rewrite a rule whose
existing wording already covered the new case? Does each one still hold at
the single-document level it was originally written for? Did you weaken a
rule where you meant to generalize it? A staging file is where a bad rule is
cheapest to catch, and it is also where a bad rule looks most reasonable. Instruct each to try to **refute** the proposal, and to
default to sceptical when uncertain.

Then run one amendment pass: for every finding, either fix the proposal or
record why the finding was rejected. A rejected finding stays in the record
with its rejection reasoning. Silently dropping a finding is the one
outcome that is not acceptable.

Write the findings and their dispositions to
`Docs/Forks/Library/03-review.md`.

---

## Phase 4 — Build it

Only after the review cycle closes.

**Go for feature complete.** Build the library system your Phase 1 spec
describes, not a reduced version of it. Work continues in the morning, so
an unfinished frontier is fine — a deliberately narrowed target is not.
Do not descope to protect the deliverable, and do not stop early because
what exists is presentable.

Build the spine first, because everything else is unreachable without it
and because a browser that cannot open a document cannot be tapped through:

1. Multiple documents exist, are enumerated, and persist across launch.
2. A browser lists them and opens one into the existing editor.
3. Create, rename, delete a document.
4. Folders: create, nest, navigate in and out.
5. Move a document between folders.

That is the order of *foundation*, not the extent of the work. Past it,
keep going through the rest of the spec in whatever order your proposal
argues for — grid and list presentations, sort, multi-select, search, drag
and drop, trash, favorites, breadcrumbs, empty and error states, keyboard
and pointer support, the sidebar and split-view structure.

Use the whole night. If you finish the spec, deepen it: fidelity passes
against the Phase 1 screenshots, the interaction details that separate this
from a generic file browser, the states nobody builds until a bug report
arrives.

Commit in coherent increments with real messages, in this project's style —
what the commit proves, what it does not prove, what was found and not
fixed. A defect you find and do not fix becomes a `KNOWN DEFECT:` block at
its own site. Evidence that is missing goes to `Docs/Unproven.md`.

The one thing that is not negotiable: **whatever state the branch is in at
morning, it builds, its tests pass, and the handover says truthfully what
is finished and what is half-built.** A frontier you are still mid-way
through is expected. A frontier described as done is not.

---

## Phase 5 — The morning deliverables

1. **A branch that builds, passes CI, and can be launched in the pinned
   simulator and tapped through.** State the exact command to run it.
2. **`Docs/Forks/Library/04-handover.md`**, containing:
   - **What works.** Specifically, and only what you actually exercised.
     Say how you exercised it.
   - **What does not work, and what is unfinished.**
   - **Design decisions.** Each with its alternative and why the
     alternative lost. The decisions most worth overruling, flagged as
     such — this project values that flag highly.
   - **Blockers.** What stopped you, what you tried, what you would need.
   - **Contract deviations and disagreements.** The amendment text itself
     goes in `Docs/Contract.proposed.md`, not here. What goes here is the
     reader's map to it: which sections you added or rewrote, which
     existing amendments your work invalidated or reopened, and — most
     valuable — every place you think a rule in force is now *wrong* rather
     than merely incomplete, with the argument. Flag the amendments most
     worth overruling.
   - **What a human must check by hand**, as a short ordered list of things
     to tap in the simulator, phrased so it can be walked in ten minutes.

Deviations and disagreements are wanted, not penalized. A run that hit a
rule, thought it was wrong, said so with an argument, and worked within it
anyway is a good run. A run that quietly bent a rule is not.

---

## Standard for the whole run

Say what you did, what you proved, and what you did not. Where you guessed,
say you guessed. Where a subagent reported something you did not verify,
attribute it rather than adopting it. The morning reader's first question
about every claim will be how you know — write so that question is already
answered.
