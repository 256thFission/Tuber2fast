# Plan: health work before the Macaron UI is promoted

Status: proposal, decisions resolved by an agent on 2026-09-24, not yet
Phillip's. The review it rests on is the read-only architecture review of
`identity/macaron-v2` at `8284e3b` (35 commits on `v2-rewrite` `2618fce`)
and the `v2-rewrite` code under it; the report is
`architecture-review-20260924-104407.html` in the session scratchpad.
This revision re-read every file the review cited, at those commits plus
the uncommitted work in `TuberNotes-postoai`, and corrected the plan where
the code disagreed (the list is at the end). Line numbers are at those
commits. Nothing here is a rule until the Contract says so.

## The goal, and what it rules out

The goal is to promote the Macaron UI to `main` onto a base the next year
of features can build on. Three requirements shape the plan:

1. **The bar will become configurable**: add, remove and reorder tools.
   This plan builds the model for that, not the editing UI. The editing UI
   is a later feature.
2. **Health work that the new UI would otherwise build on comes first.**
   Anything a new view would copy or route around gets fixed before that
   view exists.
3. **The base is not sacred.** `v2-rewrite` code changes wherever the
   evidence says it should.

Out of scope: anything in the parity deferrals, the bar-editing UI itself,
and new features. **Smallest change that proves the item** still applies
to each step.

## Order at a glance

```
Phase 0  land ──────── D4 commit the postoai work · D5 fast-forward main
Phase 1  bugs ──────── B1 trash overwrite · B2 PDF import (via 08)
Phase 2  deepen ────── 14 tests → 07 bar slot → 08 insertion
                       → 10 library (D1) → 09 canvas lifecycle (iPad)
Phase 3  Macaron ───── rebase · restore lost features on 07 · 01 theme seam
                       · 02 keycap · 04 roles · 05 atoms · 06 chrome (D3)
                       · blocker list
Phase 4  promote ───── render all surfaces · one iPad session · PR to main
Later    before selection/text redesign ── 11 PageContent split · 12 selection values
```

Card numbers (01–14) match the review report. Every step is one pull
request, and after D5 every pull request targets `main`.

---

## Phase 0: the decisions, resolved

Each decision below was open in the first draft. Each is now resolved
with the reasoning beside it, so Phillip can strike one by striking the
reasoning. A struck decision reopens only the step it names.

### D1: one policy for an unreadable versioned file

**Facts.** Four files carry a version: the package index at v4
(`TNModel/NotebookIndex.swift:63`), `FolderFile` at v2
(`LibraryStore.swift:46–52`), `FavoritesFile` at v1 (`:118–130`) and
`TrashOrigin` at v1 (`:148–155`). Today each answers a mismatch its own
way:

- Favorites throws (`:483–485`), and the whole library open fails with it.
- A folder sidecar decodes to nil (`:375–388`), so the folder silently
  loses its identity, its star and its trash container name. The comment
  there says the remedy is deleting the dev library.
- A trash origin is skipped from the listing (`:594–596`), so the item
  vanishes from the trash view while its bytes stay on disk. It is also
  the one file decoded non-strictly.

The Contract already states the rule for the package: *Refuse at the
narrowest scope, and say why*, and *Nothing is dropped, adapted, or
written back unread*. It says nothing about the three library sidecars.

**Decision.** The package rule extends to the library, word for word, as
one sentence added to the *Library* section: **a library sidecar this
build cannot read refuses the thing it describes, names the fault, and is
never repaired or written back.** Applied per file:

- **Favorites.** The narrowest thing is the stars. The library opens with
  no stars and `LibraryBrowser` carries the fault the way `Notebook`
  carries `lastSaveError`. Starring anything while the file is unreadable
  is refused, because writing the set would overwrite what could not be
  read.
- **Folder sidecar.** The narrowest thing is the folder. It is listed and
  can be entered, since its contents are ordinary files, but rename, move,
  trash, star and restyle are refused with the fault, because each needs
  the identity. No new `FolderID` is minted; minting one is a repair.
- **Trash origin.** The narrowest thing is the entry. It is listed by its
  container name with the fault, recover is refused, and delete forever is
  allowed, which is the "user removes that layer" exit the package rule
  already has. The decode becomes strict, like the other two.
- **NotebookID stability.** IDs are stable with one exception the Contract
  already states: two packages sharing an identity means the second one
  found gets a new one. That stays. It is not a repair of a file this
  build cannot read; it is the resolution of a collision this build can
  read completely, and the alternative (refusing both) punishes a copy
  made in Files. The schema-freeze question "is `NotebookID` stable?" is
  therefore answered: yes, except on collision, and the first-found
  package keeps it.

**Why this and not the alternatives.** Repairing (minting a new identity,
or replacing the file with the built-in default) is what the preference
rule allows for `UserDefaults` and what the Contract forbids for anything
durable; a sidecar is durable. Refusing the whole library, which favorites
does today, refuses far more than the unreadable thing. Refusing nothing
and logging is the bucket the Queue's failure taxonomy deliberately does
not have.

**Proof.** `TNTests/MigrationProbeTests.swift`, untracked today, joins the
target as part of D4. Its `trashCollisionKeepsBoth` is B1's test. Its two
paper tests assert what the Contract already says about the package and
fail today; they are wrapped in `withKnownIssue` until 10 lands, and the
wrapper is removed in the same commit that makes them pass. A test per
sidecar is added under 10: unreadable favorites opens the library with no
stars and a named fault; an unreadable folder sidecar lists the folder and
refuses its rename; an unreadable trash origin lists the entry and refuses
recovery.

**Blocks:** 10. **Contract:** yes, one sentence, `CONTRACT:` subject.

### D2: removing the slot in hand

**Facts.** `ToolPalette.lastKind` is a `Kind` that names an ink, the
eraser or text (`ToolPalette.swift:18`, `:160–203`) and cannot name lasso,
so "the last used" is undefined when the removed slot is lasso or when
the last used slot is the one removed.

**Decision.** When a layout change removes the slot in hand, the slot in
hand becomes **the first writing slot in the new layout**, in layout
order, where a writing slot is one with an ink kind. A layout with no
writing slot is invalid and is a `TNPrecondition`, so a person can never
be left holding nothing. `lastKind` becomes a reference to a slot in the
layout, so every slot including lasso can be the one in hand, and the
"last ink tool" the eraser and lasso return to is derived from the layout
rather than stored beside it.

**Why.** The first writing slot is the one the person put first, which is
the closest thing to a stated preference; picking the most recent is
undefined for lasso and surprising when the removed slot was itself the
most recent. Refusing the removal would make the editing UI explain a
refusal for something a person will rarely do.

**Blocks:** 07. **Contract:** covered by 07's Custody row.

### D3: the right edge belongs to the seat while it is docked

**Facts.** The seat docks to the right edge (`Macaron.md` §4.3,
`MacaronSeat.swift:5–12`; placed `.topTrailing` in `EditorView.swift:58`).
The writing bar's vertical default is `.trailing` (`WritingBar.swift:129`)
and three of its eight snap points are on the right edge. Opening the seat
with the bar standing on the right stacks one over the other.

**Decision.** **While the seat is open and docked, the seat owns the right
edge.** The bar's three right-edge snap points are unavailable then: a bar
already there moves to the nearest available point when the seat opens,
and a drag toward that edge lands on the nearest available point. When the
seat closes or floats, the points return and the bar stays where it is,
because a bar that jumps back on its own moves under a hand. Both facts
live in one chrome-layout value owned by `Workspace` (06), not in two
views reading each other.

**Why the seat and not the bar.** The seat is 250 × 300 and has one place
to dock; the bar is 56 wide and has seven other places to be. Yielding
the bar costs the person nothing they cannot undo with one drag.

**Blocks:** 06. **Contract:** 06's Custody row names the owner; this rule
goes in `Macaron.md` §4.3, not the Contract.

### D4: commit the uncommitted work first, as separate commits

**Facts.** The worktree holds 15 modified files and 7 untracked. Six of
the modified files are ones Macaron rewrites (`LibraryCells`,
`LibraryView`, `PageSetupSheet`, `Workspace`, `PagedCanvasController`,
`Unproven.md`). The work is four unrelated things:

1. **Compact on leaving the foreground**: a Contract rule under *One
   save*, `Library.compactOpenPackages`, the `Checkout` struct that holds
   the store, the call from `Workspace.flushUnderLease`, and tests.
2. **Library naming and browsing**: `LibraryStore.freeName`, changes to
   `LibraryBrowser`, `LibraryView`, `LibraryCells`, `PageSetupSheet`, and
   their tests.
3. **The scroll view ignores the Pencil** (`PagedCanvasController.swift:105`,
   `allowedTouchTypes`). This is a `TNCanvas` change and needs iPad
   evidence; today it has none.
4. **Docs**: `Queue.md` cut to its open items, `Unproven.md` rewritten
   without line numbers, and a `HistoryEntryCostTests` note.

Of the untracked files, `MigrationProbeTests.swift` is real work (D1) and
this plan is real work. `premerge-revision.md` is the August plan for a
different stack with its verdicts already applied, so it is history that
`git log` holds. `tool-picker.md`, `page-size-and-paper.md`,
`page-navigator.md` and `text-editing.md` describe features that exist on
`v2-rewrite` (`ToolPalette`, `PageSetupSheet`, `PageNavigatorSheet`,
`EditorTool.text`), were never tracked on this branch, and are listed in
`plans/README.md` only because that file predates their deletion.

**Decision.** Commit 1, 2 and 4 to `v2-rewrite` now, one commit each so
Macaron rebases over them one at a time. Commit 3 separately with the PR
template's "required but not done" box ticked and an `Unproven.md` line,
because it is the one hunk a rebase must not lose and the one hunk CI
cannot prove; it is checked in the phase 4 iPad session. Commit
`MigrationProbeTests.swift` with the `withKnownIssue` wrappers from D1 and
this plan. Delete the five stale documents and drop their rows from
`plans/README.md`; do not commit them.

**Why.** Every later phase rebases over this work, so the six overlapping
files get resolved once, here, by the person who wrote both sides. The
first draft proposed one commit; four unrelated changes in one commit make
the Macaron rebase resolve all of them at once.

**Blocks:** everything.

### D5: fast-forward `main` to `v2-rewrite` first

**Facts.** `main` is 24 commits behind `v2-rewrite` and has no commits of
its own; the promotion is a fast-forward. Macaron touches 38 files, 26 of
them in the app target.

**Decision.** After D4 lands, open one pull request that fast-forwards
`main` to `v2-rewrite` on `v2-rewrite`'s own evidence. From then on every
step in this plan is a pull request to `main`, `v2-rewrite` is retired,
and `identity/macaron-v2` rebases onto `main` in phase 3. The phase 4
pull request is then UI only.

**Why.** A pull request that carries 24 base commits, five refactors and
a UI rewrite cannot be reviewed as any one of them. Fast-forwarding first
costs nothing (there is no diff to review that CI has not already run)
and turns each later step into a pull request a reviewer can read in one
sitting. The alternative in the first draft, landing phases 1 and 2 on
`v2-rewrite` and promoting everything at once, has no advantage now that
`main` is a pure ancestor.

**Blocks:** where phase 1 pull requests point.

---

## Phase 1: bugs on the base

Both bugs lose data, so they go before any refactor.

### B1: Trash deletes whatever already sits under the same ID

`LibraryStore.trash` names the trash container after the notebook or
folder ID and then runs `if fm.fileExists(atPath: container.path) { try
fm.removeItem(at: container) }` (`LibraryStore.swift:576`).

How it loses data: a folder copied in Files keeps its `.folder.json`, and
a package copied before `scanIdentities` runs keeps its ID. Trashing both
permanently deletes the first. That breaks **One save** ("only `compact()`
deletes"). The same function force-unwraps `UUID(uuidString:
containerName)!` (`:585`), which traps on a folder whose sidecar could not
be read and got a fresh ID.

- **Fix:** an existing container is an invalid state under **Invalid
  states fail loud**, reached by a duplicate ID. Re-mint the second item's
  ID the way `scanIdentities` does (the collision rule D1 keeps), then
  trash it. Never remove the existing container. The force-unwrap goes;
  the container name is built from the typed ID, not parsed back out of a
  string.
- **Proof:** `MigrationProbeTests.trashCollisionKeepsBoth`, which already
  exists and fails today. It is the only probe test that is not wrapped
  in `withKnownIssue`, because this step makes it pass.
- **Evidence:** none beyond CI; `TNLibrary` is settled by a test.

### B2: A failed PDF import abandons its pages

This is the KNOWN DEFECT at `TNNotebook/Notebook.swift:865`. `importPDF`
throws past `emitStructure`, `emitContent` and `markDirty`, which leaves
pages in the index that the canvas was never told about and that are
never saved.

- **Fix:** step 08. Don't patch this copy; delete it.
- **If 08 slips,** the stopgap is the `defer`-publish that `importScan`
  already has (`:941`), as its own one-commit pull request that also
  deletes the KNOWN DEFECT block.

---

## Phase 2: deepen the base

The steps run in this order. Test hygiene goes first because every later
step runs the suite many times.

### 14: Test hygiene

- `TNTests/NotebookTests.swift` (2,104 lines) and `EditorViewModelTests`
  hold ten fixed `Task.sleep` waits of 60–100 ms between them. Replace
  each with an await on the condition it was waiting for. The injected
  clock the save schedule already has is the model.
- `HistoryEntryCostTests` is a benchmark (100 runs × 2) that runs in every
  test action. It is also the `signal kill` flake under load, and its own
  KNOWN DEFECT says a red result is not evidence. Move it behind an
  opt-in: its own scheme, or a `.enabled(if:)` trait keyed on an
  environment variable, whichever `project.yml` expresses more plainly.
  `AGENTS.md`'s build command stays as it is.
- `ContractStructureTests` (1,322 lines) only parses source, yet it sits
  in the hosted bundle. Move it to the unhosted target if its
  source-root lookup allows; otherwise leave it and record why in the
  file.
- Write the target rule down in `CONTRIBUTING.md`: `TuberNotesTests` is
  for tests that need UIKit, the app host or the source tree; everything
  else goes in `TNTests`.
- The file-I/O allowlist (`ContractStructureTests.swift:855`) names three
  files, and the Contract's *Structure* names those three plus
  `ToolPaletteDefaults` and `LibraryViewDefaults` as preference writers.
  Make the checker say what the Contract says: a fourth and fifth
  allowlist entry, each restricted to the `UserDefaults` token.
- **Proof:** CI time before and after, recorded in the pull request, and
  three consecutive green runs.

### 07: One bar slot, one owner

**Why it comes first among the refactors:** it is the configurability
requirement, it sits under both UIs, and it is `TNEditor` logic, so it
can be tested without a host.

**Today:**
- The tool kinds are switched over about 7 times in `TNEditor`
  (`EditorTool.swift:~191`, `:~211`; `ToolPalette.swift:~169`, `:~185`,
  `:~194`; `EditorViewModel.swift:148–202`).
- `ToolStrip.swift` (434 lines, deleted outright on Macaron) switches
  about 8 more times, and its order is `EditorToolButton.allCases` (`:11`).
- Macaron switches about 8 more times across two enums:
  `WritingBar.Instrument` (`:7`), and `MacaronBand.BandAction` (`:241`),
  which mixes lasso and text with insert and export.
- The tool rules live in views. `WritingBar.widthApplies` and
  `colourApplies` (`:319–345`) repeat rules that `setWidth` enforces with
  a trap (`EditorViewModel.swift:178`). `take` (`:348`) silently turns the
  object eraser into the pixel eraser. `fourColours` (`:411`) is now the
  only place colours are de-duplicated.
- Nothing saves the order.

**Shape.** This is only the direction. The interface gets designed in a
grilling session before any code.

- `ToolSlot` in `TNEditor` covers pen, pencil, highlighter, eraser, lasso
  and text. It replaces `EditorToolButton` and `Instrument`.
- A capability table on the slot says whether it takes a width, whether
  it takes a colour, whether it has options, and how selecting it maps to
  an `EditorTool`. The existing traps stay; the table becomes the only
  thing that decides when they are reached.
- `ToolPaletteRecord.layout: [ToolSlot]` is added with `decodeIfPresent`
  falling back to the built-in layout, the same way `gestures` was added
  (`ToolPalette.swift:62`). `ToolPalette` gains `move`, `insert` and
  `remove`, each saved. A duplicate slot, or no writing slot at all, is a
  `TNPrecondition`. Removing the slot in hand follows D2.
- `lastKind` becomes a slot reference (D2).
- The one-line forwarders in `EditorViewModel` that fail the deletion
  test (`select*`, `bind`; `:148–162`, `:208`) go away where the slot
  takes over their job.
- Views only map a slot to an icon and a label.

**Contract:** a Custody row saying `ToolPalette` owns the bar layout,
beside the existing row for presets and recents. The commit subject
starts with `CONTRACT:`. No format change, since this is a preference in
`UserDefaults` and the preference rule already covers an unreadable one.

**Proof:**
- Unhosted tests at the `ToolPalette` and `EditorViewModel` interface:
  reorder survives a relaunch; removing the slot in hand follows D2; a
  width change is reachable only for slots that take a width; an
  unreadable layout is replaced by the built-in one; a layout with no
  writing slot traps.
- Old tests that only exercise the forwarders are deleted, not kept
  alongside.
- `ToolStrip` is ported onto the slot in this step, so `main` stays
  shippable and phase 3 has a worked example to port `WritingBar` from.

**iPad:** none. `EditorViewModel` is not on the PR template's list;
`EditorBinding` is, and this step does not touch it. If the design
session moves a line into `EditorBinding`, the step joins the phase 4
iPad session.

### 08: One page-insertion primitive

**Today:** `appendPage` (`Notebook.swift:492`, `:505`), `insertPage`
(`:542`), `importPDF` (`:886–890`) and `importScan` (`:984–993`) each
repeat the same steps by hand: `withPages`, a new `PageContent`,
`edited()`, `states = .ready`, `wanted.insert`, `bumpContentVersion`, then
publish. The new UI adds templates, paste and flatten, which would be
three more copies.

**Shape:**
- One notebook intention inserts N pages with their content at a position.
  It publishes structure and content and marks dirty on every exit,
  including a throw.
- Imports and append become callers that only build the pages.
- `EditorViewModel.append` (`:286`) and `importScan` (`:528`) shrink to
  match.

**Proof:**
- A PDF import whose third page is out of bounds leaves the notebook
  dirty, and the canvas has been told about pages 1–2. This is B2's test,
  and it fails first.
- The existing import tests pass unchanged.
- Delete the KNOWN DEFECT comment in the same commit.

**iPad:** none; `Notebook` is settled by a test.

**Follow-up (not in this plan):** imports can then move out of the
1,422-line `Notebook` into their own file. Do it only if 11 doesn't make
it unnecessary.

### 10: Library changes enforce their own rules

**Today:**
- `LibraryView.run {}` (`LibraryView.swift:447–452`) re-scans identities
  after every change. That rule lives only in the view, so a redesigned
  view can drop it silently.
- `LibraryStore` goes around `PosixFileSystem` by calling `FileManager`
  directly (`:201`), so library writes get no fsync and no fault
  injection.
- It reads package files itself: `notebook.json` (`:288–293`), the
  modified time from the package layout (`:278`), and the cover through
  `load()` (`:450–466`).
- It has two name-suffix algorithms (`freeName`, added by D4's commit 2,
  and duplicate's loop `:672`) and two parent-path parsers (`:561`,
  `:681`).
- `Library.swift:83` polls `Task.sleep(10ms)` while waiting on a checkout.
- The three sidecars answer a version mismatch three ways (D1).

**Shape:**
- `LibraryBrowser.perform(_:)` runs the change and then re-indexes, so
  the view only calls it.
- Library writes go through the file-system seam.
- `PackageStore` gains a narrow facts query (id, createdAt, version,
  modified).
- One `freeName`, used by duplicate as well.
- The checkout wait becomes a continuation.
- Split out of `LibraryStore`: favorites, trash and identity, each in its
  own file, behind one writer.
- The three sidecars follow D1: strict decode, refuse the narrowest thing,
  carry the fault, never write back.
- The view rules `parentWhileSearching`, `shownDate`, `dragged`
  (`LibraryCells.swift:9–47`) and `parentFolder`, `nameOrDefault`
  (`LibraryView.swift:413`, `:457`) move onto the browser as properties
  that can be tested.

**Contract:** D1's sentence under *Library*, `CONTRACT:` subject.

**Proof:**
- Fault-injection tests for favorites and for a trash write interrupted
  midway.
- A browser test asserting the identity index is current after each kind
  of change.
- D1's three sidecar tests, and the two paper probes lose their
  `withKnownIssue` wrappers if this step is where they pass; otherwise
  they keep them and the wrapper names the step that will.

**iPad:** none.

### 09: One lifecycle per canvas page, and one path for reports

**Today:**
- A page's retire lifecycle is spread over five flags in two classes:
  `retiring`, `pagesToRetireWhenStrokeEnds` and
  `pagesAwaitingRetireReport` (`PagedCanvasController.swift:43–50`, with
  branches at `:259`, `:286`, `:342`), and `isStrokeInFlight` and
  `hasRetired` (`PageCanvasController.swift:125`, `:143`, `:527–544`).
- A report passes through `PageCanvasOwner` (`Page…:12–30`), then seven
  `pageDid*` functions that each repeat `guard retiring[page] == nil`
  (`Paged…:649–745`), then `ReportForwarder` (`EditorBinding.swift:30–66`).
- The echo latch is held in three places: `PageContent.pendingEcho`,
  `PageCanvasController.pendingEcho`, and the `inkSeq` check at
  `Paged…:659`. The two most recent commits on both branches
  (`a7f8279`, `1e07b67`) are fixes to this latch, which is the evidence
  that three holders is one too many.
- The tool is held three times.

**Shape:**
- `PageLife` (live → retire after stroke → retired → released) becomes a
  value with its transitions, owned by the paged runtime.
- The page controller reports `CanvasReporting` through a single retiring
  filter, and `PageCanvasOwner` is deleted. `ReportForwarder` stays; it
  breaks a retain cycle.
- The echo latch gets one owner. The Custody table names it.

**Proof and evidence:**
- Unhosted tests of `PageLife`'s transitions, including a retire that
  arrives mid-stroke.
- Existing `PagedCanvasControllerTests` pass, including the two echo tests
  from `1e07b67` and `b6c34ee`.
- **A physical iPad run** (`TNCanvas`, `EditorBinding`): fast scrolling
  while writing across a page edge, then close with a stroke in flight.
  This is the same session that checks D4's commit 3.
- A `CONTRACT:` commit for the echo owner.

---

## Phase 3: rebase Macaron and fix it on the new base

Rebase `identity/macaron-v2` onto `main` after phase 2, one phase-2 step
at a time (the steps are separate commits for this reason). The bar code
conflicts, and that is intended: `WritingBar` and `MacaronBand` are
rewritten against `ToolSlot`, not merged. The rebase is its own pull
request with no behaviour change, so the review that follows reads only
3a–3c.

### 3a: Restore what deleting ToolStrip removed

The deletion took these with it:
- Text style and alignment.
- The Pencil gesture bindings.
- The colour picker.
- The eraser-mode picker. Today one tap saves `.pixel`, and the object
  eraser can't come back.
- The camera. `isTakingPhoto` is never set to true.
- Page setup. `Macaron-build.md` says it is "not reachable at all on this
  branch"; paper and bookmarks are reachable only through Insert.

With 07, each is a slot's options panel, not a one-off view; page setup
returns as an entry in the band's Insert menu. **Proof:** a test for each
at the slot interface, plus a screenshot of each panel in the pull
request.

### 3b: The cards that belong to Macaron

- **01: Tell the canvas the theme through the seam.** Replace
  `Theme.current` and `Theme.changed` inside `TNCanvas` with the existing
  `apply(CanvasEnvironment)`. That fixes the stale selection frame and the
  "canvas is told, never asks" violation. Proof: a `RecordingSurface`
  test; iPad evidence (`TNCanvas`), in the phase 4 session.
- **02: Make the keycap a look, not a tap.** `Keycap` becomes a
  `ButtonStyle`, and `action()` stops running 60 ms late in a `Task`. That
  also fixes double-fire on quick taps and makes it visible to VoiceOver.
  Three views stop redrawing the cap themselves. Evidence: tool-switch
  latency on the iPad, in the phase 4 session.
- **04: Theme answers in roles, not colour maths.** Views stop mixing
  colours; `Theme` exposes named roles. This fixes the dirty-dot ring,
  which is invisible in Teenage Enamel because `secondary` and `ink` are
  both `#1A1A1A` (`MacaronBand.swift:142`). Proof: a test that every
  theme's role pairs are distinct.
- **05: Fill in the kit's missing pieces.** Pull out the repeated fixed
  sizes from about 20 call sites, and settle the copies that disagree (a
  title strip 44 tall and 34 tall; section gaps of 16 and 10).
- **06: Give the chrome's layout one owner.** Placement of the bar and the
  seat becomes one `Workspace`-owned value that carries D3's rule and
  survives tab switches. Once 07 exists, the tool half of 06 is already
  done. This needs a `CONTRACT:` Custody row.

### 3c: The blocker list from the review

- The Themes `.sheet` is outside `.environment(\.macaron, …)`
  (`RootView.swift:30–36`), so it always draws in default Macaron. Move it
  inside, and make a missing environment value a precondition failure
  instead of a silent default, so the next sheet cannot repeat it.
- The back chevron is gone while selecting (`1cf36e5`).
- The move picker keeps the previous level's folders.
- Two `.destructive` button roles were dropped.
- The new clamp `max(zoom, 0.0001)` is replaced by a `TNPrecondition`.
- Eleven `-TN*` launch-argument hooks move inside `#if DEBUG`, along with
  `Workspace.openSmokeNotebook` (`Workspace.swift:88`).

---

## Phase 4: prove it and promote it

1. Render every surface in every theme, including the four nobody has
   seen: trash, move picker, folder style and new notebook. Record the
   screenshots in the pull request.
2. **One iPad session** covers everything this plan owes the device, in
   this order so a failure early stops the rest:
   - D4 commit 3: a Pencil drag at a page's horizontal edge does not turn
     the page; a finger drag does.
   - 09: fast scrolling while writing across a page edge; close with a
     stroke in flight; ink survives a force-quit.
   - 01: change theme with a layer selected; the frame follows.
   - 02: quick double taps on a keycap fire once each; a tool switch is
     felt, not seen late.
   - D3: open the seat with the bar standing on the right; the bar moves;
     close the seat; the bar stays.
   Use `xcodebuild` and `devicectl` directly; `Tools/device` refuses on
   the current iPadOS. Record what was seen and leave the verdict to
   Phillip.
3. Open the Macaron pull request to `main`. The definition of done is
   green CI plus an approving review.

---

## What each step leaves behind

| Step | Commit subject prefix | Contract edit | Test home | Device |
|---|---|---|---|---|
| D4 (1) | `CONTRACT:` | compact under *One save* (already written) | TNTests | no |
| D4 (2) | none | none | TNTests | no |
| D4 (3) | none | none | none | **owed** |
| D4 (4) | `Docs:` | none | none | no |
| D5 | none (fast-forward) | none | none | no |
| B1 | none | none | TNTests | no |
| 14 | none | none | both | no |
| 07 | `CONTRACT:` | Custody row: layout | TNTests | no |
| 08 | none | none | TNTests | no |
| 10 | `CONTRACT:` | D1 sentence under *Library* | TNTests | no |
| 09 | `CONTRACT:` | Custody row: echo latch | both | **yes** |
| 3a–3c | none | none | both | 01, 02 |
| 06 | `CONTRACT:` | Custody row: chrome layout | TNTests | D3 |

---

## Later: before the selection and text redesign

These don't block promotion. They do block any redesign of selection or
text.

- **11: Split `PageContent`** (`PageState.swift:25–60`) into three owned
  values: the page content, the save ledger, and the render session. Then
  pull the save schedule (`Notebook.swift:13–21`, `:1235–1400`) into a
  module whose input is the dirty captures and whose output is the saved
  sequence numbers. Unproven.md's save-timing gap can then be tested
  directly.
- **12: Selection and transform as values.** The hit-testing and
  `OverlayPhase` machine (`PageCanvasController.swift:38`, `:639–740`) and
  the affine maths (`LayerSelectionView.swift:211–390`) become page-space
  values that can be tested without a host. Unproven.md's "object locked"
  item depends on this.
- **Watch:** `StrokeGestures` bindings reach `Notebook.inkChanged` as a
  `[:]` default parameter on every ink report (`Notebook.swift:279–336`).
  Name the seam in the Contract, or pass the bindings once at bind time.

## What was checked and found healthy

- `Renderer`'s bounded caches: each states its owner, limit and evictor.
- `Workspace` (281 lines).
- The gesture recogniser's own logic.
- `ReportForwarder`'s reason to exist.
- The `CanvasRuntime`, `AssetReading` and `PackageStoring` seams: each has
  a real adapter plus a test fake.
- `ToolPalette`'s preference exception: the Contract's *Structure*
  already names `ToolPaletteDefaults` and the Custody table already has
  the row, so 07 extends a settled rule rather than opening one.

## Risks

- **Phase 3's rebase is large.** Keep the phase 2 steps as separate
  commits, so Macaron can rebase one step at a time, and make the rebase
  its own pull request with no behaviour change.
- **iPad evidence is the pacing item.** Five things owe it (D4's commit 3,
  09, 01, 02, D3). They are batched into one phase 4 session. If the
  device stays unavailable, each ships with "required but not done" and
  an `Unproven.md` line, which the PR template allows; none is silently
  skipped.
- **The device install gate:** `Tools/device` refuses on the current
  iPadOS; use `xcodebuild` plus `devicectl` directly.
- **D1 widens 10.** Three refusal paths with UI for each is the largest
  piece of 10. If it makes 10 too big for one pull request, D1 lands as
  its own pull request before the rest of 10, with the Contract sentence.
- **07's design session may move a line into `EditorBinding`**, which
  puts it on the device list. Decide that in the session, not after.

## Corrections to the first draft

Each was found by re-reading the cited code:

- `FolderFile` is v2 and `FavoritesFile` is v1, not the reverse.
- `tool-picker.md` is not a live plan. `ToolPalette`,
  `ToolPaletteDefaults`, the Custody row and the *Structure* sentence are
  all on `v2-rewrite`; the file was never tracked here. The same holds
  for the other three untracked plans. The risk row about folding it into
  07 is gone.
- The file-I/O allowlist does not disagree with the Contract about
  `LibraryViewDefaults` alone; it names neither preference writer, and the
  Contract names both.
- The uncommitted work is four unrelated changes, one of which touches
  `PagedCanvasController` and owes device evidence. The first draft called
  it one commit.
- `main` is a pure ancestor of `v2-rewrite`, so D5's alternative is a
  fast-forward with no review cost.
- The writing bar's vertical default is the right edge, which is also
  where the seat docks, so D3 is a collision on the default and not only
  on a drag.
- There are ten fixed sleeps across the two test files, not nine.
- The echo latch has been patched twice in the last two commits, which is
  new evidence for 09.
