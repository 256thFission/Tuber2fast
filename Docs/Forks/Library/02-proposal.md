# The library layer — proposal

Status: written by the overnight managing agent, before code. Phase 1's spec
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
  touches document contents. Names are sanitized at the UI (path separators
  and leading dots refused), and a name collision on create/duplicate/move is
  auto-suffixed (" 2", " 3" — GoodNotes shows the same "(1)" pattern in
  Phillip's own screenshots). The FS enforces the uniqueness the suffix
  resolves. `documentID` stays inside `document.plist` and remains the
  identity durable state uses; the name is presentation.
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
  next favorites write. Why paths, not IDs: folders have no durable ID and
  inventing one just for favorites is a new identity scheme for one feature.
  The cost is honest: **moving or renaming an item drops its favorite** unless
  the move path rewrites the entry — so the move/rename operations do exactly
  that, in the same user action, ordered favorites-last so a crash between
  the two leaves a pruned favorite, never a dangling one. (The alternative —
  `documentID`-keyed favorites for documents — survives moves for free but
  cannot cover folders and costs one `document.plist` read per favorite per
  browse. Rejected for asymmetry; worth overruling if favorites-lost-on-move
  ever bites a real user.)
- **`library.plist`** holds the browser's presentation preferences: grid/list,
  sort key, sort direction — global, not per-folder, exactly as GoodNotes
  behaves (and is complained about; parity wins over the complaint tonight).
  Written by the library store on user action. Not `UserDefaults`, which is a
  forbidden token outside the store and would put durable state outside the
  library's own directory.
- **Trash** is a sibling directory. *Move to Trash* is one directory move plus
  one sidecar write (`<name>.origin.plist`, recording the original
  library-relative parent path). *Recover* moves it back to that path if it
  exists, else to the root — GoodNotes' documented behavior. The sidecar is
  orphan-class: missing sidecar → recover to root. Name collisions inside
  `Trash/` auto-suffix like anywhere else. There is **no retention window and
  no auto-empty** — GoodNotes' documented semantics — so nothing ever deletes
  user data on a timer. *Empty Trash* and per-item *Delete Permanently* are
  the only permanent deletions in the whole design, and both confirm.
- **The existing document is adopted, not migrated.** On first run of this
  build, if `<Application Support>/JustACanvas.tubernotes` exists it is moved
  into `Documents/` (one rename; contents untouched; name "Just a Canvas").
  This is not a compatibility shim — it is one line of adoption for Phillip's
  own test data, and it is deletable the day it stops mattering.

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
  degrade to their default (no favorites / default sort / recover-to-root),
  loudly, and are rewritten whole on next write. None of them can dangle into
  anything.
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
| The library tree on disk (folders, package placement, names) | `LibraryStore` | user action | across launches |
| Folder metadata (`.folder.plist`) | `LibraryStore` | user action | across launches |
| Favorites (`favorites.plist`), browser prefs (`library.plist`), trash origin sidecars | `LibraryStore` | user action | across launches |
| The in-memory listing of the folder being shown | `LibraryViewModel` | navigation / store reply | browser session |
| Which document is open (the live editor session + lifecycle) | `AppRoot` (SwiftUI root) | user action | open-document session |
| In-memory thumbnail cache | `LibraryThumbnailStore` | render | browser session, bounded |

Golden rules, restated one level up:

1. **`LibraryStore` is to the library what `DocumentStore` is to a document**:
   the sole file-system writer at its level, an actor, receiving values and
   returning values. It never reaches inside a `.tubernotes` package — the
   package boundary is the boundary between the two stores. It moves, renames,
   creates, and deletes packages as opaque directories; only `DocumentStore`
   reads their contents.
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

The ban stands and nothing needs amending, because **the thumbnail cache is
in memory only**. `LibraryThumbnailStore` renders page 1 (static composite
via the existing render path's approach + `PKDrawing` ink render) off-main,
per visible cell, cancellable on scroll-away, into a cache that states its
owner (`LibraryThumbnailStore`), its bound (32 MB — a 160×212pt @2x thumbnail
is ~550 KB; ≈60 cells), and its eviction (LRU) at its declaration — which is
exactly the cache the *Performance* section already permits. Nothing is ever
written to disk; a cold launch re-renders. A7's narrowing is **not** invoked:
that amendment covers *disposable renders of immutable assets on disk*, and a
page-1 render includes ink, which is mutable — durably caching it is banned
under both the current rule and A7. The cost is honest: every launch pays a
decode per visible cell, masked by placeholder cells (GoodNotes masks its own
loading the same way). If that cost is ever measured to matter on device, the
*then*-needed amendment is a new argument for a new narrowing — deliberately
not staged tonight, because no code needs it.

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
  debounced.
- **Opening a document** = `EditorLifecycle(session: EditorSession(store:
  DocumentStore(directoryURL: tappedPackage)))` — the codebase map confirms
  the session needs nothing else. `RootCanvasView` is reused as-is.
- **Closing needs the teardown that does not exist yet.** New:
  `EditorSession.close() async` — cancel the debounce, await any in-flight
  save, run one final `saveIfNeeded` pass, and refuse further edits. `AppRoot`
  awaits `close()` before releasing the lifecycle (a brief "Saving…" state on
  the Back transition). This is `flushForBackground` with finality; the
  save-path protections (protected tasks, single save in flight) are reused,
  not duplicated. Releasing the session releases the runtime graph — the map
  confirms ownership is session-rooted, so the canvas count returns to zero.
- **Back does not lose ink by construction**: close() completing is the same
  guarantee backgrounding gives, made synchronous with the transition.
- Accessibility identifiers follow the existing convention: `library.grid`,
  `library.item.<name>`, `library.new`, `library.back`, `library.trash`, etc.
  — these are what the morning's hand-walk (and any future XCUITest) grips.

## 5. Building / deliberately not building

**Building (spine first, then breadth in this order):**

1. `LibraryStore` + durable form above; multiple documents enumerated,
   persisting across launch; adoption of the existing document.
2. Browser grid; tap-to-open into the existing editor; Back with real close.
3. Create notebook (modal shell: name; canonical geometry), create folder
   (name, color, icon subset); rename (inline, in the chevron popover, per
   the observed GoodNotes menu); delete → Trash.
4. Folders: enter/leave (push, small centered title, back chevron, no
   breadcrumb — matching observed GoodNotes); nesting unbounded; contextual
   + New creating into the current folder.
5. Move: the expandable-tree destination picker.
6. Then: list view; sort menu (Date Created / Last Modified / Name / Type,
   direction toggle, global persistence); All/Documents/Folders filter;
   multi-select (Select All / Done, action bar: Duplicate / Move / Trash);
   duplicate (fresh `documentID`); Trash screen (Recover / Delete
   Permanently / Empty, confirmations on the permanent ones); favorites
   (star on cell, Favorites collection: flat, cross-parent, no + New);
   thumbnails (in-memory, placeholders first); title search; empty states
   (designed empty-folder state, first-run state); drag & drop if the night
   allows (UIKit spring-loading is INFERRED-FROM-PLATFORM, lowest priority).

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

- **Move preserves the modified date** (GoodNotes bumps it; its users file
  that as a bug; parity with the complaint, not the defect).
- **Folders sort by their own activity** (directory mtime), not created date.
- **Favorites do not survive a move/rename losing a race with a crash**
  (pruned, never dangling) — GoodNotes' behavior here is unknown.
- **No starter document on first run** — the empty-state illustration and
  copy carry first-run (web GoodNotes ships empty too).
- **Trash lives behind the browser's toolbar menu**, matching iPad GoodNotes
  (gear/menu → Trash), not the web's sidebar row.

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
