# The library layer — proposal

Status: written by the overnight managing agent before code, then **revised
through one full adversarial review cycle** — five reviewers, findings and
dispositions in `03-review.md`. This is the post-review version; the review
file is the diff's "why". Phase 1's spec
(`01-goodnotes-spec.md`) says what GoodNotes does; this says what TuberNotes
will do, in this codebase, under this contract. Where the two differ, the
difference is listed in *Deliberately not building* or argued inline.
Reviewed adversarially in `03-review.md`; amendments staged in
`Docs/Contract.proposed.md` (nothing there is in force).

The four foreseeable contract collisions the brief names are each argued in
their own section: *Thumbnails*, *File I/O confinement*, *Page deletion*, and
*Nothing synchronous*.

---

## 1. The durable form

### The decision: the file system is the library's single truth

A library is a directory tree. A folder is a directory. A document is the
existing `.tubernotes` package, unchanged, sitting inside whatever folder
contains it. There is **no library index file** — no `library.plist` naming
members, no manifest, no tree file.

```text
<Application Support>/TuberLibrary/
  Documents/                          the root folder
    Bayes Exam.tubernotes/            a document: the existing package, unchanged
    Chinese/                          a folder = a directory
      .folder.plist                   the folder's own metadata: color, icon
      Vocab.tubernotes/
      HSK 5/                          nesting = directory nesting, unbounded
        .folder.plist
  Trash/                              trashed items, moved here whole
    Old Notes.tubernotes/
    Old Notes.tubernotes.origin.plist sidecar: where it was, for Recover
  library.plist                       browser preferences: view mode, sort key+direction
  favorites.plist                     ordered list of favorited item paths
```

**Why no index.** The same principles *Durable form* applies inside a
document, one level up:

- **No duplicated truth.** An index holding names and membership is a second
  copy of what the directory tree already states. The tree cannot disagree
  with itself; a tree plus an index can.
- **No dangling refs, by construction.** Inside a document, a dangling page
  ref is fatal because the index is the authority and a missing page file
  means ink is gone. At the library level an index would import that failure
  mode — an entry naming a deleted package makes the *library* refuse. With
  the file system as truth the class does not exist: there is nothing to
  dangle. Everything that can be inconsistent is a sidecar, and every sidecar
  is orphan-class (below).
- **Write order and atomicity for free.** Create, rename, move, trash, and
  restore are each **one directory operation** — `FileManager.moveItem` /
  `createDirectory` — atomic on APFS. There is no multi-file commit anywhere
  in the library layer, so there is no write order to get wrong and no
  torn state to recover. This is a strictly stronger position than the
  document format's, which needs leaf-to-root ordering because it has
  multiple files per commit.
- **No whole-library read.** Opening the browser enumerates **one folder**,
  the one being shown — names and file attributes, not contents. Navigation
  enumerates the next folder when it is entered. Nothing ever walks the whole
  tree except Trash emptying and a future orphan sweep. (GoodNotes itself
  loads per-level behind its push animation — the complaint corpus pins this.)

### What each piece is

- **A document's display name is its directory name** (`Bayes Exam.tubernotes`
  → "Bayes Exam"). One truth; a rename is one atomic FS rename that never
  touches document contents. Names are sanitized at one gate: path
  separators and leading dots refused, the reserved suffixes `.tubernotes`
  and `.origin.plist` refused (a *folder* named `X.tubernotes` would
  otherwise classify as a document and swallow its contents), and a 255-byte
  UTF-8 budget enforced with headroom for the package suffix and a collision
  suffix. A name collision on create/duplicate/move/recover/adopt is
  auto-suffixed (" 2", " 3" — GoodNotes shows the same "(1)" pattern in
  Phillip's own screenshots); **auto-suffixing is a licensed adaptation,
  staged explicitly in L3**, not an unstated correction. Collision detection
  asks the file system (the actual rename result), never string-compares
  listings — the device's data volume is case-sensitive while the pinned
  simulator's is not, so string comparison would pass CI and lie on device
  (recorded for `Docs/Unproven.md` and the device checklist). `documentID`
  stays inside `document.plist` and remains the identity durable state uses;
  the name is presentation.
- **A folder's display name is its directory name**, same rules.
  `.folder.plist` carries only what a directory cannot: `color`, `icon`.
  It is orphan-class: a missing or unreadable `.folder.plist` renders the
  folder with the default color and no icon, surfaces the error, and is
  rewritten whole on the next edit. A folder never refuses to open because
  its *decoration* is broken.
- **Dates are file-system attributes, not durable fields.**
  - *Created* = the package/folder directory's creation date.
  - *Modified* (a document) = the newest modification date among
    `document.plist`, `pages/`, `layers/`, `assets/` — four stats. Every save
    renames a temp file into one of those directories, and a rename into a
    directory updates that directory's modification date, so the derived
    value tracks every save without a single new durable field or write.
    This is asserted by a test (save → derived date moves), so if an OS
    change ever broke the property it fails loud, not stale.
  - *Modified* (a folder) = its own directory mtime (contents added/removed).
    GoodNotes sorts folders by created date and users file bugs about it;
    we deviate deliberately (recorded in *Deviations*).
  - Consequence, deliberate: **moving an item does not change its modified
    date** — the parent directories' mtimes change, the item's own do not.
    GoodNotes bumps it and users call that a defect. Deviation recorded.
- **`favorites.plist`** is one small file: an ordered list of library-relative
  paths. Its writer is the library store; its entries are orphan-class — an
  entry whose path no longer exists renders nothing, and is pruned on the
  next favorites write (the pruning is licensed in L3 alongside the suffix).
  Why paths, not IDs: folders have no durable ID and inventing one just for
  favorites is a new identity scheme for one feature. Move and rename
  therefore rewrite favorites in the same user action: **a prefix rewrite** —
  every entry whose path has the old path as a component prefix is
  substituted, so renaming a folder carries every starred descendant with it
  (the review caught the descendant case; the original draft rewrote only
  the moved item's own entry). The rewrite uses the **post-suffix**
  destination path. Ordering is favorites-last, so a crash between the move
  and the rewrite leaves pruned favorites, never dangling ones. (The
  alternative — `documentID`-keyed favorites for documents — survives moves
  for free but cannot cover folders and costs one `document.plist` read per
  favorite per browse. Rejected for asymmetry; worth overruling if
  favorites-lost-on-a-crash ever bites a real user.)
- **`library.plist`** holds the browser's presentation preferences: grid/list,
  sort key, sort direction — global, not per-folder, exactly as GoodNotes
  behaves (and is complained about; parity wins over the complaint tonight).
  Written by the library store on user action. Not `UserDefaults`, which is a
  forbidden token outside the store and would put durable state outside the
  library's own directory.
- **Trash** is a sibling directory. *Move to Trash* is one directory move plus
  one sidecar write (`<name>.origin.plist`, recording the original
  library-relative parent path), sidecar strictly after the move. The sidecar
  is named after the **post-suffix** trash name, so two same-named items
  trashed from different folders cannot cross origins. *Recover* moves the
  item back to its origin path if it exists, else to the root — GoodNotes'
  documented behavior — and deletes the sidecar (a crash between leaves an
  inert orphan sidecar). *Empty Trash* sweeps sidecars with their items. The
  sidecar is orphan-class: missing sidecar → recover to root. Name collisions
  inside `Trash/` auto-suffix like anywhere else. There is **no retention
  window and no auto-empty** — GoodNotes' documented semantics — so nothing
  ever deletes user data on a timer. *Empty Trash* and per-item *Delete
  Permanently* are the only permanent deletions in the whole design, and both
  confirm.
- **`.staging/` is where multi-file operations happen.** A library mutation's
  *structural* step is one atomic directory operation — but Duplicate is
  inherently a multi-hundred-file copy, so it copies into
  `TuberLibrary/.staging/<uuid>/` first and lands with one atomic move.
  Enumeration ignores `.staging/`; the store sweeps it at startup. Crash
  debris therefore never enumerates as a document — the document format's
  own temp-and-rename discipline, one level up.
- **The existing document is adopted, not migrated.** On first run of this
  build, if `<Application Support>/JustACanvas.tubernotes` exists it is moved
  into `Documents/` (one rename; contents untouched; name "Just a Canvas",
  suffixed if that name is somehow taken). Adoption runs idempotently inside
  `LibraryStore`'s first listing of the root — a single same-volume rename,
  so a crash before it leaves the source to try again and a crash after it
  leaves nothing to do. It is licensed explicitly in L1 as the one write the
  store makes outside a user action and outside its tree, and it is deletable
  the day it stops mattering.
- **Dates degrade honestly at the edges.** The derived modified date tracks
  every save shape (including an index-only rewrite, whose atomic replacement
  refreshes `document.plist`'s own mtime — tested specifically). Missing
  `layers/`/`assets/` directories on a young document are tolerated (ENOENT
  is a date that does not participate, not an error). What the derivation
  does **not** survive: external file transfer and device clock changes,
  which quietly reorder date sorts — accepted, stated, and no worse than the
  app being imitated.

### The failure story

- **A document that will not open cannot break the browser.** A browser cell
  is built from directory facts alone (name, dates) — rendering it never
  opens the package. Tapping a corrupt document opens the editor shell, whose
  existing `.failed` phase already renders the refusal; Back returns to the
  browser, which is untouched. A document whose *thumbnail* render fails gets
  the refusal badge on its cell (GoodNotes shows a warning badge for its own
  sync errors) and stays fully manipulable — a document you cannot open is
  precisely the one you most need to be able to rename, move, or trash.
- **A corrupt `.folder.plist`** decorates the folder with defaults and
  surfaces the error; navigation and contents are unaffected.
- **A corrupt `favorites.plist` / `library.plist` / `.origin.plist`** each
  degrade to their stated default (no favorites / default sort /
  recover-to-root) and are rewritten whole on next write. None of them can
  dangle into anything. "Loud" is defined, not gestured at: a log line plus
  the browser's non-modal banner; a lost sort preference does not alert. The
  corrupt file is **set aside as `<name>.corrupt`**, never overwritten — the
  evidence survives the recovery.
- **A folder that fails to enumerate is refused, not emptied.** Listings are
  Result-shaped; a thrown enumeration renders a distinct refused-folder state
  (message + retry). The designed empty state renders only on a *successful*
  empty listing — showing "create your first notebook" over an I/O error is
  the blank-unreadable-page sin at library scale.
- **There are no fatal library states.** This is the designed difference from
  the document level, where a dangling page ref *is* fatal because ink is at
  stake. The library level holds no user content of its own — every file it
  owns is decoration or preference — so every library failure is survivable
  by construction. The one fatal state remains a document's own, and it is
  contained to that document's cell and editor.
- **Foreign files in the tree** (a stray file in `Documents/`, a directory
  that is neither a package nor readable as a folder) are ignored and logged
  — orphans are inert, one level up.

## 2. Ownership

New rows, in the shape of the *Owners* table:

| State | Sole writer | Frequency | Lifetime |
|---|---|---|---|
| The library tree on disk (folders, package placement, names) | `LibraryStore` | user action (plus the one licensed adoption move at first listing) | across launches |
| Folder metadata (`.folder.plist`) | `LibraryStore` | user action | across launches |
| Favorites (`favorites.plist`), browser prefs (`library.plist`), trash origin sidecars | `LibraryStore` | user action | across launches |
| The in-memory listing of the folder being shown | `LibraryViewModel` | navigation / store reply | browser session |
| Which document is open (the live editor session + lifecycle) | `AppRoot` (SwiftUI root) | user action | open-document session |
| In-memory thumbnail cache | `LibraryThumbnailStore` | render | browser session, bounded |

Golden rules, restated one level up:

1. **`LibraryStore` is to the library what `DocumentStore` is to a document**:
   the sole file-system writer at its level, an actor, receiving values and
   returning values. It never opens, decodes, or writes a file inside a
   `.tubernotes` package — the package boundary is the boundary between the
   two stores. **One stated exception, licensed in L1**: it may *stat* the
   package's four well-known interior paths (`document.plist`, `pages/`,
   `layers/`, `assets/`) for the derived modified date. That is layout
   knowledge leaking one level up, accepted out loud: the path list is one
   named constant, and a document-format change that adds a directory must
   update it (A14 is the dependency that created the current four).
2. **The browser renders snapshots and sends intentions**, exactly as the
   canvas does. `LibraryViewModel` holds the last listing the store returned;
   every mutation is an async store call that returns the new listing (or
   throws). No optimistic mutation of the listing — the FS is the truth and
   the UI shows what the store last proved. At user-action frequency this
   costs nothing.
3. **One document open at a time.** `AppRoot` swaps between the browser and
   the editor. Opening builds the same graph `EditorLifecycle.makeDefault()`
   builds today, pointed at the tapped package. Closing is a real teardown
   (new, §4). The library never manipulates a package that is open, because
   the browser and the editor are never on screen together.

## 3. The four collisions, argued

### Thumbnails (Forbidden patterns: durable derived artifacts)

The ban stands for the *cache*, because **the thumbnail cache is in memory
only**. `LibraryThumbnailStore` renders page 1 off-main, per visible cell,
cancellable on scroll-away, into a cache that states its owner
(`LibraryThumbnailStore`), its bound (32 MB — a 160×212pt @2x thumbnail is
~550 KB; ≈60 cells), and its eviction (LRU) at its declaration — exactly the
cache the *Performance* section already permits. Nothing is ever written to
disk; a cold launch re-renders. A7's narrowing is **not** invoked: a page-1
render includes ink, which is mutable — durably caching it is banned under
both the current rule and A7.

**The read that fills the cache needed its own license, and the review
caught its absence.** Rendering page 1 of a closed document reads the index,
the page file, its layer files, and possibly a large asset — outside any
editor session. The reader is now named: **a read-only, per-package
`DocumentStore`**, constructed for the render and discarded — the only type
allowed to read a package's insides, doing exactly that. L5 licenses the
read and scopes *Lifecycle*'s "the document index loads once, when the
editor session is created" to the editor session it was written about. So
§1's enumeration claim is stated precisely: building a cell's *facts* never
opens the package; rendering its *thumbnail* does, asynchronously, through
`DocumentStore`, and the cell is complete without it. Refusals are
negative-cached under the same bound, so a corrupt package costs one failed
decode, not one per scroll-past.

Costs, priced: an ink-only render is one small `loadPage` + `PKDrawing`
decode; a PDF-backed page-1 is a per-cell asset decode that can reach tens
of MB — which is why the build order ships **paper-colored cover cells
first** (directory facts only — also the failure story's base case),
ink-only renders on the frontier, and static-composite thumbnails not
tonight at all. If a launch-time re-render cost is ever *measured* to matter
on device, the then-needed disk-cache amendment is a new argument — not
staged tonight, because no code needs it.

The render needs `PKDrawing` (PencilKit) and image contexts (UIKit), so it
lives **in the app target**, not `TuberRender` — `TuberRender`'s import policy
is CoreGraphics-only and widening a machine-checked policy for a browser
nicety is A15's mistake again. Off-main is by `nonisolated static async`
funcs, the codebase's documented idiom for heavy value work.

### File I/O confinement (machine-checked: DocumentStore.swift + ImportPickers.swift)

Enumerating a library is file I/O, and it does not belong in
`DocumentStore.swift` — that file is one document's format, and stuffing tree
operations into it would couple two write domains the ownership table keeps
separate. The decision: **`LibraryStore` is a sibling actor in the same
module** (`Modules/TuberStore/LibraryStore.swift`) **with its own entry in
`fileIOAllowlist`**. Adding an entry is the allowlist working as designed —
CONTRIBUTING's fail-closed rule exists so that a new file doing I/O *must*
show up in that diff for review; this is that diff, deliberate and visible.
What is *not* done: widening the rule's tokens, moving the check, or touching
`ContractStructureTests` logic. The contract sentence the check enforces
("file I/O confined to `DocumentStore`") does need its wording generalized —
staged as amendment **L2** in `Contract.proposed.md`: file I/O is confined to
`TuberStore`'s actors, one per storage domain, each named in the allowlist.

### Page deletion and the index-keyed runtime

**Out of scope, and the boundary holds.** The library deletes *documents* —
whole packages, moved to `Trash/` as opaque directories. No operation in this
design removes or reorders a page inside a document, so the append-only page
list the index-keyed runtime depends on is untouched, and the opaque-page-token
work stays not-built, exactly as the Handovers proposal intended. The one new
hazard would be deleting a package that is *open* — impossible in this UI:
the browser and the editor never coexist, and Trash operates only from the
browser. If a future multi-window build breaks that invariant, the token work
comes into scope with it.

### Nothing synchronous on interaction paths

Every library read and write is behind the `LibraryStore` actor; every
thumbnail render is behind `LibraryThumbnailStore`; the browser's SwiftUI
views await listings and render placeholders meanwhile. Specific hot paths:

- **Folder navigation** pushes immediately and fills in when the listing
  lands (a folder listing is one `contentsOfDirectory` + ~4 stats per item —
  tens of milliseconds for hundreds of items, but still never on main).
- **Scroll** touches only the in-memory cache; a miss enqueues a render and
  shows the placeholder. Renders are cancelled when their cell scrolls away
  (structured cancellation + install-site currency check, per CONTRIBUTING).
- **Open** is the existing `.loading` phase; nothing new blocks.
- The browser is SwiftUI throughout — the *Canvas runtime owns the frame
  path* rule is about canvas work, and no library surface hosts a canvas.
  Scrolling a SwiftUI grid is not the Pencil path.

## 4. UI architecture and the editor handoff

```text
AppRoot (SwiftUI)
├── LibraryBrowserView            NavigationStack over folder pushes
│   ├── LibrarySidebar            Documents | Favorites (+ Trash via toolbar menu)
│   ├── LibraryGridView / LibraryListView
│   ├── toolbars: All-filter, + New, view-options menu, Select-mode bar
│   └── sheets: NewNotebookSheet, NewFolderSheet, MovePickerSheet, TrashView
└── EditorContainerView (when a document is open)
    └── the existing RootCanvasView, unchanged, plus a Back affordance
```

- **`AppRoot` replaces `EditorSceneView` as the scene root.** It owns
  `LibraryCoordinator` (`@Observable`): the `LibraryStore`, the current
  `openDocument: (EditorLifecycle, URL)?`, and the open/close transitions.
  Scene-phase events route to the open lifecycle exactly as today; with no
  document open there is nothing to flush — library writes are synchronous
  with their user action (await-complete before the UI proceeds), never
  debounced. The NavigationStack is **scoped to the content column**; the
  sidebar is a sibling outside it, carrying its own collapse toggle — so a
  folder push moves the pane, never the sidebar (hand-walk check: the
  sidebar does not move on push).
- **Opening a document** = `EditorLifecycle(session: EditorSession(store:
  DocumentStore(directoryURL: tappedPackage)))` — the codebase map confirms
  the session needs nothing else. `RootCanvasView` is reused as-is. **The
  open path never creates**: a library-enumerated package whose `load()`
  returns nil is a *damaged document* (index gone, siblings possibly alive),
  not a first launch — the session refuses it (`.failed`, "this document has
  no index") and the package is left byte-identical. Create-on-nil survives
  only on the New Notebook path, which creates the directory itself. This
  closes the review's second blocker: without it, tapping a torn package
  would silently save a fresh empty document into the wreckage.
- **Closing is a real teardown with a specified failure branch.** New:
  `EditorSession.close() async` — **first awaits the protected `startTask`**
  (awaiting protected work is legal; cancelling it is not — without this, a
  Back during `.loading` races the never-cancelled start against the
  browser's mutations: the review's first blocker), then cancels the
  debounce, awaits any save in flight, runs one final `saveIfNeeded` pass,
  and refuses further edits (a private flag checked at the edit/save guards
  — no new `Phase` case, so no view churn). `AppRoot` releases the lifecycle
  only after `close()` returns clean.
- **A session is released only when nothing is dirty.** If the final pass
  fails, `close()` does not return success: the browser is shown but the
  dirty lifecycle is retained off-screen, its existing backoff/retry
  machinery keeps draining, the `save.error` banner pattern surfaces it in
  the browser, and opening another document is blocked until it drains.
  Backgrounding's guarantee is honest because the session survives to retry;
  close() earns the same guarantee the same way — by not destroying the
  retrier while it holds ink. The library never mutates a package whose
  session has not closed clean.
- Accessibility identifiers follow the existing convention: `library.grid`,
  `library.item.<name>`, `library.new`, `library.back`, `library.trash`, etc.
  — these are what the morning's hand-walk (and any future XCUITest) grips.

## 5. Building / deliberately not building

**Building — the reviewed build order.** Three parallel lanes, one
integration choke, then a strictly ordered frontier. Every increment is
independently green and leaves the app tappable if work stops there. No
`project.yml` change is needed anywhere (new files land in existing target
directories — the review confirmed this removes the worst merge choke).

- **Lane A — `Modules/TuberStore/LibraryStore.swift`** + the durable form
  above + adoption + the one `fileIOAllowlist` entry + the honest test set:
  create/list round-trip, rename-collision suffix (via the FS, not string
  compare), move with favorites prefix-rewrite, trash→recover with and
  without origin sidecar, corrupt-sidecar set-aside, derived-date-moves on
  every save shape including index-only, adoption idempotence, `.staging`
  sweep.
- **Lane B — `EditorSession.close()`** per §4 (await startTask → flush →
  refuse edits; retain-if-dirty policy), tested on the `HeldSaveStore`
  precedent: close awaits an in-flight save; edits refused after close;
  a failing final save leaves the session alive and dirty.
- **Lane C — `AppRoot` + the browser spine**: grid of paper-cover cells
  (directory facts only — name, date; the thumbnail base case), tap-to-open
  reusing `EditorLifecycle`/`RootCanvasView` unchanged, Back wired to
  close(), New Notebook / New Folder sheets in the observed modal shell,
  rename + Move to Trash via the chevron popover, folder push navigation,
  contextual + New, a11y identifiers throughout.
- **Integration choke** (serialized): merge, full suite, hand-tap in the
  pinned simulator.
- **Then, in order, each independently green**: Trash screen (Recover /
  Delete Permanently / Empty, confirmations on the permanent ones) → Move
  via **drill-down sheet** (same semantics as the observed picker; the
  expandable tree is a follow-up) → sort menu + grid/list toggle +
  `library.plist` persistence → All/Documents/Folders filter → title search
  as a **filter of the current folder's listing** (recursive search would
  walk the tree the design promises not to walk — a later argument) →
  duplicate via `.staging` (same `documentID` tonight, `KNOWN DEFECT:` at
  the copy site; fresh-ID rewrite is a follow-up through `DocumentStore`) →
  favorites (star on cell; flat cross-parent collection; no + New there) →
  ink-only thumbnails (renders behind placeholders, negative-cached
  refusals) → multi-select (Select All / title / Done bar, check-circle
  overlays, Duplicate/Move/Trash actions) → empty-state and fidelity
  polish.
- **Not tonight, at all** (the review's line, adopted): drag & drop,
  static-composite thumbnails, the expandable-tree picker, fresh-ID
  duplicate.

**Fidelity commitments** (the review found the pixels under-specified;
these are now commitments, not vibes — sources are the first-party shots):

- One grid, one comparator: folders and documents **interleave** under the
  active sort key; only the Type sort groups (folders first, per spec §7.1).
- Cell anatomy: portrait thumbnail (paper-colored cover until renders land),
  favorite star top-right **on the thumbnail** (grey outline / red filled),
  title centered below with the grey chevron-down menu affordance
  immediately right, grey date line beneath; titles wrap to two lines,
  middle-truncated, row heights vary; the refusal badge sits in the observed
  corner-fold position.
- Dates: absolute always, `MMM d, yyyy 'at' h:mm a` — every first-party
  cell uses it, even 18-month-old ones; relative forms are not built.
- The + New popover keeps the observed three-band grammar at reduced
  cardinality: Notebook as a square tile, Import as a wide tile, **Folder in
  its own card at the bottom**.
- New Folder sheet: the observed sheet verbatim — X left / centered title /
  blue check right shell, large live preview tracking selection, centered
  "Untitled" field, Color|Icon segmented control, **26 swatches + custom
  wheel in the 9×3 layout**; the Icon tab ships a chosen SF-symbol glyph set
  (contents unobserved in GoodNotes; our decision, flagged as such).
- New Notebook sheet: the same shell; left paper preview panel, Name row,
  Size row showing the canonical size with its chevron (the size popover
  can defer; the row cannot). Language and Cover rows are cut and declared.
- View options: **one** four-squares menu in the observed order — Select
  Items · Grid/List · four sort keys — with the direction chevron on the
  active key only.
- Select mode: Select All / collection title / Done top bar, blue
  check-circle overlays on cells.
- Trash screen: Empty (red) / Select / Done trio.
- Empty folder: the illustration slot, bold "This Folder is Empty", grey
  "Create a new document or move existing ones here." — and **no button**.
- Grid metrics: 4 columns landscape with sidebar open; cell sizing, gutters,
  and type sizes measured from `images/01` at build time.
- Search entry: a top-right magnifier (the capsule's one earned element —
  bell and avatar have nothing behind them and are cut, declared below).

**Not building, deliberately:**

- Shared, Marketplace, cloud/sync anything (no backend exists; the sidebar
  shows what exists).
- Whiteboard / Text Doc / Study Set / QuickNote / Scan / Quick Record — the
  + New menu offers what TuberNotes has: Notebook, Import (PDF/Image, the
  existing import paths), Folder.
- Content search (no OCR; title/folder-name matching only — GoodNotes' own
  PDF search needs a pre-existing text layer).
- Export, Share Link, Open in New Window (multi-scene is off in project.yml).
- Paper template catalog beyond the canonical page (the sheet's chrome is
  built to grow into it; the catalog is content, not architecture).
- Page-level bookmarks in Favorites (favorites cover documents and folders;
  pages have no browser presence tonight).
- Keyboard shortcuts / pointer polish (whatever UIKit/SwiftUI gives free is
  kept; nothing bespoke).
- Any on-disk render cache (argued in §3).

## 6. Deviations from GoodNotes, deliberate

Behavioral:

- **Move preserves the modified date** (GoodNotes bumps it; its users file
  that as a bug; parity with the complaint, not the defect).
- **Folders sort by their own activity** (directory mtime), not created date.
- **Favorites do not survive a move/rename losing a race with a crash**
  (pruned, never dangling) — GoodNotes' behavior here is unknown.
- **No starter document on first run** — the empty-state illustration and
  copy carry first-run (web GoodNotes ships empty too).
- **Trash lives behind the browser's toolbar menu.** iPad GoodNotes reaches
  Trash from its top-right gear/avatar menu; TuberNotes has no avatar or
  gear, so the toolbar menu is the honest nearest home. A knock-on, not a
  whim.

Chrome (equally spec-visible, so equally declared):

- **No sync cloud icon** — there is no sync.
- **No Shared or Marketplace sidebar rows** — nothing behind them; the
  sidebar shows Documents and Favorites.
- **No bell, no avatar** — the top-right carries only the search magnifier.
- **The + New menu offers Notebook, Import, Folder** — the document types
  TuberNotes does not have would be lying chrome as disabled tiles; omission
  is the honest form (the fidelity reviewer concurred).

## 7. Amendments this forces (staged, not adopted — see Contract.proposed.md)

- **L1** — *Owners*: the library ownership rows and the two-store boundary
  (LibraryStore never reads inside a package; DocumentStore never reaches
  outside one).
- **L2** — the file-I/O confinement sentence generalized to one actor per
  storage domain, allowlist unchanged in mechanism, one entry added.
- **L3** — *Durable form* gains the library level: the tree-as-truth rule,
  sidecars orphan-class, no library-level fatal states, names as directory
  names, dates as FS attributes.
- **L4** — *Lifecycle*: the editor session gains `close()`, and what Back
  guarantees (no ink newer than the last completed save is released).
- **L5** — *Navigation* (browser): the browser is SwiftUI-owned; no canvas
  hosts inside library surfaces; the one-document-open invariant.

Each is FORCED only once its code lands; they are staged AHEAD tonight and
flipped as phases land, per that file's own convention.
