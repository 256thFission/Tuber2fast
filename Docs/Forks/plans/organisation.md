# Organisation depth: bookmarks, an outline, folder decoration, drag and drop

A plan, not code. Branch `v2-mvp` (2a8fbf8). Every claim below cites the
file it was read from; paths are relative to that worktree.

**In short.** Four features, three pull requests, cheapest first. Drag and
drop is nearly free: every layer of a move exists and is tested, and
`PageNavigatorSheet.swift:97-102` is a `.draggable`/`.dropDestination` pair
to copy; missing are a `Transferable`, drop targets on two cells, and one
guard in `LibraryStore.move` that `rename` already carries. Folder colour
and symbol go in `.folder.json`, the sidecar whose own doc comment calls it
"A folder's identity and decoration sidecar" (`LibraryStore.swift:6`), at
`FolderFile.currentFormatVersion` 2. The bookmark carries its own title, so
the outline is the marked pages read from the index the notebook already
holds: no page title, no second structure, no scan, and a tab of the
navigator sheet that exists. Nothing here is undoable. Two format bumps,
four `CONTRACT:` hunks.

## 0. Where it stands today

**Drag and drop: the engine is built, the gesture is not.** All three
layers of a move exist: `LibraryStore.move(at:toFolder:)`
(`Modules/TNLibrary/LibraryStore.swift:350-360`), refusing a folder moved
into itself (`:354`) and a name collision (`:356`); `Library.move`
(`Modules/TNLibrary/Library.swift:116-119`), gated on `requireUnlocked`
(`:105-109`), whose `isLocked` (`:55-60`) covers a folder holding an open
notebook; and `LibraryBrowser.move`
(`Modules/TNLibrary/LibraryBrowser.swift:184-189`), which runs inside
`perform` (`:168-178`), sets `refusal` and reloads, `LibraryView` raising it
as a banner (`TuberNotesApp/LibraryView.swift:47-49`).
`destinations(in:excluding:)` (`LibraryBrowser.swift:151-156`) computes the
legal destination set, and two tests cover the move and the destinations
(`TNTests/LibraryBrowserTests.swift:153-170`, `:193-205`). No test covers a
refused move: `:172-191` reads as one but refuses a `trash`. Absent is the
gesture: no `draggable`, `dropDestination`, `onDrag` or `onDrop` appears
anywhere in the library UI, and a move is raised from a menu into a
drill-down sheet whose "Move here" confirms the level showing
(`TuberNotesApp/LibraryMovePicker.swift:59`). The one precedent is the
navigator's page drag (`PageNavigatorSheet.swift:7-23`, `:97-102`).

**Folder decoration: nothing, though the record was named for it.**
`FolderFile` (`LibraryStore.swift:6-15`) is documented as "A folder's
identity **and decoration** sidecar" and holds a version and a `FolderID`,
nothing else; no colour, symbol, tint or cover field exists on any library
record, and the folder glyph is a fixed SF Symbol in one accent colour
(`TuberNotesApp/LibraryCells.swift:184-191`). The sidecar is already read
on every listing: `item(at:url:kind:)` calls `folderID(of:)` for every
folder (`LibraryStore.swift:235-246`, the call at `:242`), which opens and
strictly decodes the file (`:304-311`), so two more keys in it cost no
read. Both cells stack overlays on the artwork, star `:26`, selection check
`:30`, lock badge `:33-41`, so a decorated glyph and a drop highlight have
hosts.

**Bookmarks and an outline: nothing, and no page has a name.** No `.swift`
file mentions either. `PageRecord` is four fields
(`Modules/TNModel/NotebookIndex.swift:7-10`), `PageDescriptor` three
(`Modules/TNModel/Seam.swift:27-31`), `NavigatorPage` six
(`Modules/TNEditor/EditorViewModel.swift:11-23`; the comment at `:64`
calling it five is stale, do not copy it), and a navigator cell draws an
ordinal from an enumeration index (`PageNavigatorSheet.swift:40-41`). There
is no heading model, and deriving one from text layers means reading every
page and layer file, which open does not do (`Docs/Contract.md:359`). The
navigator sheet gives an outline its surface for free: a `NavigationStack`
with a toolbar (`PageNavigatorSheet.swift:37`, `:48-52`) over a `LazyVGrid`
of `editor.navigatorPages` (`:39-44`), a tap that dismisses and scrolls
(`:79-82`), and thumbnails that `Notebook.thumbnail(of:)` answers for an
unloaded page without installing anything
(`Modules/TNNotebook/Notebook.swift:632-639`).

**The mirror refresh, which is the fact the outline turns on.**
`EditorBinding.intention(_:)` runs a mutation then `drain()`
(`Modules/TNEditor/EditorBinding.swift:179-182`), which calls `onDrained`
(`:158`), and that is `refreshMirrors` (`EditorViewModel.swift:97`),
rebuilding `navigatorPages` from `notebook.index.pages` (`:115-127`). It
runs whether or not the mutation queued a change, so a bookmark needs **no**
new `NotebookChange` case (`Modules/TNNotebook/NotebookChange.swift:8-15`)
and no `emitStructure`.

**Four facts that bound everything below.** Every decode is strict and
refuses a missing or extra key by name (`Modules/TNFormat/Codecs.swift:60-63`).
`view.json` is disposable (`NotebookIndex.swift:123`), so a bookmark cannot
live there. `PageRevision` is `ink`, `layers` and `inkIndex` and nothing
else (`Modules/TNNotebook/PageState.swift:137-141`), so nothing here is
undoable. And both format bumps rest on `Docs/Contract.md:14-16`: "**Burn
things down with permission.** There are no users and no data to keep. No
legacy support, no backwards shim, no migrator that reads a shape this
build never wrote."

## 1. What GoodNotes does here, and what this plan matches

Matched: a per-page mark toggled from the page and surfaced as a filter at
the top of the thumbnail panel, where GoodNotes and Notability both put it;
a tap on an entry to go to its page; a folder's colour and symbol set from
the item's own menu; documents and folders dragged onto folder cells.

Not matched, deliberately, the big one first: **this plan merges two
structures into one.** GoodNotes keeps an untitled bookmark flag and a
separate titled outline whose entries come from a PDF's own outline, from
heading styles, from AI, or from a typed title, and which rename, reorder
and nest three deep. Here the mark carries an optional title, so one flag
is both the bookmark and the manual half of the outline: an entry is a
page, its order is the page order, and nothing generates an entry from a
document. Section 5 says what that rules out. One lesson taken rather than
matched: after GoodNotes moved its bookmark icon into a More menu the forum
asked for it back, so the toggle here is a toolbar button that shows
whether the current page is already marked.

## 2. The data shape

Two durable changes: one list on the notebook index, two keys on
`.folder.json`. Drag and drop stores nothing.

### The bookmark carries the title

```swift
// Modules/TNModel/NotebookIndex.swift

/// One marked page and what it is called. Presence is the mark: there is
/// no "bookmarked: false". `title` may be empty, a mark nobody named; the
/// outline then shows that page's number, computed from the order.
package struct PageBookmark: Codable, Sendable, Equatable {
    package let page: PageID
    package let title: String
}

// On NotebookIndex, beside `pages`. Order here is insertion order and means
// nothing: the outline reads `pages` and picks out the marked ones, so it
// is in page order without this list being kept in it.
package let bookmarks: [PageBookmark]
package static let currentFormatVersion: UInt32 = 3
```

Owner: `Notebook`, in `NotebookIndex`, which is Custody's second row.

**Why a list and not a field on `PageRecord`.** `JSONEncoder` omits a nil
optional, while `TNTests/FormatTests.swift:15` asserts
`Set(page.keys) == DurableKeys.pageRecord` exactly and `IndexFile.decode`
checks the same set on read (`Modules/TNFormat/PackageStore.swift:561`), so
a nullable durable field is not representable without a hand-written
encoder. Non-optional instead grows `PageRecord` to six fields and makes
`bookmarked: false, title: "x"` representable. A list makes presence the
flag.

**Why one field does two features.** The outline needs a label per row and
a page to go to, and the mark carries both, so it is
`index.pages.compactMap { r in bookmarks.first { $0.page == r.id } }` over
the index open already read whole. Invalid states refuse: `validated()`
(`NotebookIndex.swift:91-104`) gains two checks and `NotebookIndexFault`
two cases, a bookmark naming a page the index does not hold and two for one
page, each refusing the notebook, the narrowest scope for an index fault
(`Docs/Contract.md:202-203`).

**`withPages` drops the bookmarks of pages it does not carry.** One line,
and load-bearing. Publish 3 of a save writes `intended.withPages(present)`
when a page failed to stage (`PackageStore.swift:355-360`), so without it
one page that fails to stage while holding a bookmark writes an index this
build's own `validated()` refuses, and the notebook never opens again.
`Docs/Contract.md:202-203` says the opposite: a missing page file refuses
that page only. With the line, `deletePage` needs no filter of its own.

`Notebook` gains `bookmark(_ page: PageID, titled: String)` and
`removeBookmark(_ page: PageID)`, not one call taking `String?`: an
optional there would be a command argument shaped like a durable value.
Each body is `index = index.withBookmarks(...)`, `indexSeq += 1`,
`markDirty()`: `setPaper`'s shape (`Notebook.swift:594-612`) minus the
asset checks, the geometry and the re-render. Neither emits a structure
change, neither is undoable, and a page the index does not hold traps.
`movePage` needs nothing, since order comes from `pages`; `duplicatePage`
does not copy the mark, because it ends in `insertPage`
(`Notebook.swift:573`) and `insertPage` touches no index field but `pages`
(`:486`); `withNotebookID` (`NotebookIndex.swift:85-87`) carries the list,
so a duplicated notebook keeps its outline.

In `TNEditor`, `NavigatorPage` gains `bookmark: String?`, nil unmarked and
`""` marked and unnamed. That is a read model, not the tri-state above: nil
is absence from the list, the presence-is-the-flag shape the durable side
has. `EditorViewModel` gains `bookmark(_:titled:)` and
`removeBookmark(_:)`, each one `binding.intention { }` in the shape
`deletePage` uses (`EditorViewModel.swift:319-321`); `refreshMirrors`
(`:107-128`) builds one `[PageID: String]` from `notebook.index.bookmarks`
beside its existing `records` local (`:115`). No new observed property on
`Notebook`, whose observed surface is five (`Docs/Contract.md:78-82`).

### Folder colour and symbol

```swift
// Modules/TNLibrary/LibraryStore.swift

/// Both named, not bytes or free strings: a colour name maps to something
/// the app can draw differently in light and dark, a symbol's raw value
/// *is* its SF Symbol name, and a name this build does not ship refuses
/// the sidecar rather than falling back. `.neutral` is the colour every
/// folder draws today and is what "undecorated" means: a value, not an
/// absence (Contract.md:209-210).
package enum FolderColor: String, Codable, Sendable, CaseIterable { /* neutral + 7 */ }
package enum FolderSymbol: String, Codable, Sendable, CaseIterable { /* folder + 5 */ }

/// The pair a cell draws with. Not `Codable`: the two durable keys are
/// flat on `FolderFile`, so the flat `decodeStrict` at :307 pins them with
/// no nested check. The precedent for nested objects, when one is needed,
/// is `IndexFile.decode` pinning page records in the reader
/// (`PackageStore.swift:560-568`), which PR 3 follows.
package struct FolderDecoration: Sendable, Equatable {
    package let color: FolderColor
    package let symbol: FolderSymbol
}

/// `.folder.json` at version 2: identity and decoration, which is what the
/// doc comment already said it was.
package struct FolderFile: Codable, Sendable, Equatable {
    package let formatVersion: UInt32
    package let folderID: FolderID
    package let color: FolderColor
    package let symbol: FolderSymbol
    package static let currentFormatVersion: UInt32 = 2
}
```

Owner: `LibraryStore`, Custody's ninth row and the file-I/O allowlist's
second entry (`Docs/Contract.md:377-378`).

The cost of the bump, plainly: a `.folder.json` this build cannot read
makes `folderID(of:)` answer nil, so the folder's `LibraryItem.identity` is
nil (`LibraryStore.swift:55-59`), its star stops resolving
(`LibraryBrowser.swift:85-87`), and trashing it mints a fresh container
name (`LibraryStore.swift:458`), with nothing surfaced. That path already
exists for a corrupt sidecar; the bump widens the window from corrupt to
corrupt-or-old. The remedy the Contract names is deleting the dev library.

`folderID(of:)` (`:304-311`) becomes `folderFile(of:) -> FolderFile?` with
`folderID(of:)` as `folderFile(of:)?.folderID`, and its `expectedKeys`
literal at `:307` gains `"color"` and `"symbol"`. `createFolder` (`:294`)
writes `.neutral` and `.folder`, which is what every folder draws today
(`LibraryCells.swift:189`). `LibraryItem` gains
`decoration: FolderDecoration?`, nil for a notebook exactly as `folderID`
is, filled in `item(at:url:kind:)` beside it (`:242`). One
`setDecoration(_:at:)` reads the sidecar, replaces the two fields and
writes the file whole and atomically, the way `setFavorite` does
(`:407-431`). The browser needs no map and no join: the decoration is on
the item the listing already answers with.

### Where the outline appears

A two-value `Picker` in the toolbar `PageNavigatorSheet` already has
(`:48-52`), switching the same grid between every page and the marked ones.
The sheet already owns the thumbnail fetch, the dismiss-then-scroll tap,
the context menu and the delete confirmation, which a separate surface
would restate for the same pages.

**The filter is over the enumerated pairs, not the array.** The grid
numbers cells from the enumeration index of what it is given,
`cell(page, number: position + 1)` (`:40-41`), and the tap uses that number
as an absolute index, `editor.scroll(toPageIndex: number - 1)` (`:81`).
Filtering the array would label the third bookmark of a 40-page notebook
"Page 3" and scroll to page 3. So the `ForEach` filters
`Array(editor.navigatorPages.enumerated())` and `number` stays the page's
own position. The reorder pair (`:97-102`), whose `before:` is meaningless
in a filtered list, and `addTile` (`:124-147`) are both gated on the picker
being on All.

## 3. The steps

Three pull requests, cheapest and least risky first, so a night that stops
early still lands something. The order follows the blast radius: PR 1
changes no file format, PR 2 bumps a one-file sidecar, PR 3 bumps the
package format. Neither PR 2 nor PR 3 depends on PR 1.

**PR 1. Drag and drop in the library.** Commit 1 is a pre-existing defect
found on the way: moving an item into the folder it is already in throws
`.alreadyExists` and banners "already exists: Foo.tubernotes" for a no-op.
`LibraryMovePicker` reaches it today, because "Move here" confirms the
level showing (`LibraryMovePicker.swift:59`) and
`destinations(in:excluding:)` does not exclude the current parent. Fix it
at the source, in `LibraryStore.move`: after `target` is computed at
`:355`,
`guard target != source else { return item(at: relativePath, url: source, kind: kind) }`,
which is `rename`'s own line at `:342` word for word. That fixes the
picker, the drag, and every future caller, and leaves the drop handler
nothing to guard. A folder dropped on itself is already
`.destinationInsideSource` at `:354`.

Commit 2 makes a multi-item move survive one refusal. `LibraryBrowser.move`
loops inside `perform` and throws on the first failure with the earlier
paths already moved (`:184-189`); with drag and drop, dragging a selection
that contains an open notebook is the ordinary gesture. It stops using
`perform` and gathers instead: a `do`/`catch` per path, the descriptions
joined into `refusal`, `selection = nil`, then `reload()`. One banner line,
every movable item moved.

Commit 3 is the drag. `LibraryCells.swift` gains
`import UniformTypeIdentifiers` and, not `private` because both cells and
`LibraryView` need it, `struct DraggedLibraryItems: Transferable, Codable`
holding `paths: [String]` over `CodableRepresentation(contentType: .data)`.
It carries the navigator's `KNOWN DEFECT:` across by cross-reference
(`PageNavigatorSheet.swift:10-16`): `public.data` lights every folder cell
up for any dragged-in data item. Both cells gain `.draggable`, carrying
`browser.selection?.contains(item.relativePath) == true ? selection : [item.relativePath]`,
and, on the folder arm, `.dropDestination(for:isTargeted:)` drawing the
highlight through the overlay stack already there (`:29-42`, `:96-102`).
Each cell takes a `drop: (Set<String>) -> Void` beside its existing
`menu:`, because the move must go through `LibraryView.run`, which clears
the refusal and rebuilds the identity index afterwards (`:359-365`); the
call sites at `:294` and `:306` pass
`{ paths in run { await browser.move(paths, toFolder: item.relativePath) } }`.
The closure returns true and nothing else: every refusal is the store's or
the ledger's, including `Docs/Contract.md:324-325`'s, that moving a folder
above an open notebook is refused with the notebook's name. `LibraryView`
also puts a `.dropDestination` on the back chevron (`:103-112`), moving to
the parent path when inside a folder.

Tests, `TNTests/LibraryBrowserTests.swift`: "Moving an item into the folder
it is already in is a no-op, not a refusal"; "A drop of a folder holding an
open notebook refuses with the notebook's name", which drags the folder and
not a neighbour, because `Library.move` calls `requireUnlocked` on the
source only (`Library.swift:116-119`); "A three-item move with one open
notebook lands the other two and refuses once". All three go through
`browser.move` with a set, since the drag is a view concern and the browser
call is what is pinnable. Plus `TNTests/LibraryTests.swift`: "A move into
the current parent returns the item and moves no files". Verification:
simulator, since neither view file is on either list in
`CONTRIBUTING.md:107-113`; the PR records an iPad pass anyway, because
whether a drag off a grid cell beats the grid's own scroll is a touch fact
(`Docs/Unproven.md:314`).

**PR 2. Folder colour and symbol.** `LibraryStore.swift`: the two enums,
`FolderDecoration`, the two fields and the version on `FolderFile`,
`folderFile(of:)` with `folderID(of:)` over it, the two names in the
`expectedKeys` literal at `:307`, `createFolder` writing the pair,
`decoration` on `LibraryItem` and in `item(at:url:kind:)`, and
`setDecoration(_:at:)` beside the favourites section (`:384-431`).
`LibraryBrowser.swift`: one `setDecoration` intention through `perform`.
`LibraryCells.swift`: `LibraryFolderGlyph` takes a `FolderDecoration?`, and
a table in `LibraryStyle` (`:256-268`) maps `FolderColor` to a `Color`.
`LibraryView.swift`: a "Customize" item in `itemMenu(for:)` (`:316-340`)
shown only for a folder, and a `.sheet(item:)` beside the others
(`:50-69`). New `TuberNotesApp/FolderStyleSheet.swift`: a row of swatches
over a grid of symbols, presented the way `NewNotebookSheet` is (`:55-59`).

Tests, `TNTests/LibraryTests.swift`: "A folder's colour and symbol round
trip, and a new folder is neutral"; "Decoration follows the folder through
rename, move, trash and recovery", the shape of `:261-280`; "A colour name
this build does not know refuses the sidecar, so the folder loses its
identity", which pins the cost section 2 states rather than pretending it
away; "`FolderFile` carries exactly its keys". Plus `LibraryBrowserTests`:
"Setting a decoration reloads the listing and the item carries it".
Verification: simulator only (`CONTRIBUTING.md:121-122`).

**PR 3. The page bookmark and the outline.** `NotebookIndex.swift`:
`PageBookmark`; `bookmarks` on the index and in both initializers;
`withBookmarks`; `withNotebookID` carries the list and `withPages` drops
the bookmarks of pages it does not carry; two `validated()` checks and two
`NotebookIndexFault` cases; `new` passes `[]`; `currentFormatVersion` 3.
`Codecs.swift`: `DurableKeys.index` gains `"bookmarks"` and
`DurableKeys.bookmark` is `["page", "title"]`. `PackageStore.swift`:
`IndexFile.decode` (`:556-571`) pins the nested bookmark objects as it pins
page records at `:561`. `Notebook.swift`: the two intentions.
`EditorViewModel.swift`: `NavigatorPage.bookmark`, one map in
`refreshMirrors`, the two intentions. `PageNavigatorSheet.swift`: the
`Picker`, the filter over the enumerated pairs, the gate on the reorder
pair and `addTile`, a ribbon and the title under the ordinal in
`cell(_:number:)` (`:71-121`), a "Bookmark page" item in the context menu
(`:103-120`), and an `.alert` with a `TextField`, the shape `LibraryView`
uses twice (`:50-54`, `:60-64`), carrying Cancel, Save, and Remove when the
page is already marked. `EditorView.swift`: one button in the `pages` group
(`:137-165`), filled or not from
`editor.navigatorPages[editor.currentPageIndex].bookmark`, opening that
same alert pre-filled, so a page marked from the toolbar can be named
without being unmarked first.

Every notebook on disk is format 2 and lacks the key, so `IndexFile.decode`
refuses it by name with `.missingKey("bookmarks")` (`Codecs.swift:56-59`
says why missing wins over the version), reaching the app as
`.failed(.format(...))` from `Library.checkout` (`Library.swift:82-84`).
Loud on open, silent in the library: decision 2 records what that costs.
No migrator.

Three existing tests move. `TNTests/FormatTests.swift:77-90` sets
`object["formatVersion"] = 3` and expects `unsupportedFormatVersion(3)`
(`:80`, `:82`); at version 3 that cannot hold, so the probe becomes 4. The
memberwise `NotebookIndex(notebookID:createdAt:pages:)` gains
`bookmarks:`, touching `TNTests/FormatSupport.swift:40` and
`FormatTests.swift:97`, `:120`, `:261`, `:547`, each of which passes `[]`.
`indexKeys` (`:8-19`) gains the bookmark array and asserts
`formatVersion == 3` at `:18`. The `indexDeleteEachKey` loop (`:51-75`)
covers the new key with no edit.

New tests, `TNTests/FormatTests.swift`: "A bookmark naming a page the index
does not hold refuses the notebook"; "Two bookmarks for one page refuse the
notebook"; "`withPages` that drops a page drops its bookmark, and the
result validates", which is the save path above.
`TNTests/NotebookTests.swift`: "A bookmark dirties the index, survives a
flush and a reopen, and records no undo entry" (`canUndo` unchanged, the
shape of `:572-603`); "Deleting a bookmarked page takes its bookmark with
it"; "Moving pages reorders the outline without touching the list".
`TNTests/LibraryTests.swift`: "A format-2 package lists with a nil
identity", which writes an index this build will not read and asserts what
`list(folder:)` answers, pinning decision 2's cost.
`TNTests/EditorViewModelTests.swift`: "A bookmark reaches `navigatorPages`
through the drain with no structure change", the one test that pins the
mechanism section 0 describes.

Verification: `TNEditor` is on the definition of done's device list
(`AGENTS.md`), so this PR takes iPad evidence: marking the current page
shows the ribbon with no page turn and no canvas reload; a named mark shows
in the outline tab; the outline is in page order after a reorder and its
ordinals are the pages' own; a row dismisses and lands on its page; a mark
survives backgrounding. Each line not done goes to `Docs/Unproven.md`.
`EditorBinding.swift`, `Workspace.swift` and both canvas controllers are
not touched.

## 4. Contract

Every hunk is Phillip's `CONTRACT:` commit; this is the proposal. Hunk 4
belongs to PR 2, hunks 1 to 3 to PR 3. PR 1 needs none.

**1. Custody, `Docs/Contract.md:44`.** One row, one cell.

```
quoted:       | Page order, paper, geometry | `Notebook` | `NotebookIndex` |
replace with: | Page order, paper, geometry, page bookmarks | `Notebook` | `NotebookIndex` |
```

No hunk for row 51: decoration is inside "the library tree", which that row
already says, and the row does not name `Favorites.json` either.

**2. One save, `Docs/Contract.md:228-230`.** Forced: the paragraph states
an exhaustive list the code will break.

quoted: "- **A save writes only what changed.** An unchanged page file is
not rewritten. The index is rewritten only when order, paper, or geometry
changed. Rewriting an unchanged file is a bug."

replace with: "- **A save writes only what changed.** An unchanged page
file is not rewritten. The index is rewritten only when order, paper,
geometry, or a page bookmark changed. Rewriting an unchanged file is a
bug."

**3. Durable form, `Docs/Contract.md:139`.** The digit alone.

quoted: "**Format version is 2.**"

replace with: "**Format version is 3.**"

The rest of that paragraph stands, including "a round-trip test from a
fixture package checked into the repo". No fixture package exists anywhere
in the tree, so rewriting the sentence would put a rule in force that this
pull request does not satisfy; the tension between it and "no migrator
exists because no users exist" is older than this plan and is Phillip's to
settle on its own.

**4. Library, `Docs/Contract.md:332`.** One clause.

quoted: "A folder has a `.folder.json` holding its `FolderID`."

replace with: "A folder has a `.folder.json` holding its `FolderID`, its
colour, and its symbol."

**No Undo hunk.** "Undo belongs to the notebook. There is one stack per
notebook, holding ink values" (`:265-266`) already excludes a bookmark, a
colour and a move; `PageRevision` is ink, layers and inkIndex; and this
plan adds no record site. Deleting, duplicating and moving pages are
equally not undoable and the Contract lists none of them. The
`bookmark(_:titled:)` doc comment is the right home for the fact.

## 5. Out of scope

Bookmarked pages in the library's Favorites section, which GoodNotes does
and which here would need a `.page` case on `ItemIdentity`
(`LibraryStore.swift:26-32`) and give `TNLibrary` knowledge of notebook
interiors it does not have. An outline derived from a PDF's own outline,
from heading styles or from handwriting, which needs either a heading model
this app lacks or the full-notebook read open avoids
(`Docs/Contract.md:359`), and whose handwriting arm is a deferred feature
twice over; with it go nesting, reordering, renaming an entry independently
of its page, and one page under two entries. A persistent outline panel
instead of the sheet's tab, which is a layout change to `EditorView` rather
than a navigator change, and the sheet was chosen over a full-screen cover
for a stated reason (`EditorView.swift:67-71`). A colour or symbol on a
notebook, which has no sidecar and would make decoration a package format
change. Also out: an emoji as a folder icon, folder covers as imported
artwork, a bookmark as a link target, dragging onto the sidebar rows or the
trash, spring-loading a hovered folder, dropping a file in from another
app, which is import, undo for any of the four, and the ten deferred
features.

## 6. Decisions

1. **The mark carries a title, or is a bare flag.** Recommendation: the
   title, because an all-unnamed outline is the thumbnail grid filtered and
   nothing more, and the title is the whole reason this plan needs no
   second structure. It costs one `String` in a record that would otherwise
   be one `PageID`, plus an alert with a text field on two surfaces. The
   alternative is both reference apps' shape: drop `title` from
   `PageBookmark`, the alert, the text field and the label under the
   ordinal, and the marked tab shows thumbnails only. Choosing that now
   costs nothing already built; choosing it after marks are on disk costs a
   format bump. This is the plan's one real departure from GoodNotes, which
   is why it is a decision and not an assertion in section 1.
2. **The index bump is loud on open and silent in the library.**
   `IndexFile.decode` refuses a format-2 package by the key it is missing,
   but `LibraryStore.indexFacts(ofPackageAt:)` decodes the same index with
   `try?` and returns nil on any fault (`LibraryStore.swift:224-229`). So
   after the bump every pre-existing package lists with `notebookID: nil`
   (`:241`), its identity nil (`:55-59`), which drops its star
   (`LibraryBrowser.swift:85-87`), makes `toggleFavorite` a silent no-op
   (`:209`), skips it in `scanIdentities` so links to it cannot resolve
   (`LibraryStore.swift:592`), re-mints its trash container name (`:457`),
   falls back to the file creation date for the sort (`:243`), and draws a
   blank cover (`Library.swift:151`, `LibraryCells.swift:169-171`). The
   notebook looks healthy in the grid until you tap it. Recommendation:
   accept it, delete the dev library, and pin the behaviour with the
   store-level test PR 3 adds, so it is known rather than discovered. The
   alternative, making `indexFacts` throw, makes `item(at:url:kind:)`
   throwing (`:235-246`) and one unreadable package refuse a whole listing,
   a larger change than the feature.
3. **The `public.data` drag defect.** Recommendation: defer, carrying the
   `KNOWN DEFECT:` block across with a cross-reference. The fix is one
   exported `UTType` serving both call sites, needing a
   `UTExportedTypeDeclarations` array, which has no `INFOPLIST_KEY_` form,
   and the app target generates its plist from build settings
   (`project.yml:220`) and carries four `INFOPLIST_KEY_*` values (`:203`,
   `:207`, `:215`, `:219`).

Closed, not decisions. Colour is a named palette and not `RGBA8`, because
`TNLibrary` may not import SwiftUI (`Docs/Contract.md:379-380`), so the
mapping is the app's either way, and a name fails loud at decode for free.
A hover highlight may promise a drop that is then refused, because
`dropDestination` exposes a `Bool` and no payload during hover, so a cell
cannot know whether the dragged item is an open notebook or its own
ancestor; the refusal lands in the banner that exists. A duplicated page
does not carry its mark, because `duplicatePage` ends in `insertPage` and
`insertPage` touches no index field but `pages`.

## 7. Cross-plan

The sibling wave-4 plan is `capture.md`, camera photo and document
scanning. Two files overlap, both textually: the `EditorView` toolbar
`HStack` (`EditorView.swift:96-115`), where this plan adds one bookmark
button to the `pages` group and `capture.md` adds rows to `insertMenu`; and
`EditorViewModel.swift`, where this plan adds a `MARK: Bookmarks` section
and `capture.md` an import intention beside `importImage` (`:393-399`).
Nothing else is shared and neither plan needs the other: this plan's weight
is in `NotebookIndex.swift`, `Codecs.swift`, `PackageStore.swift` and
`TNLibrary`, `capture.md`'s in `ImportReader.swift`, `Notebook.importImage`
and the asset path.

It assumes what is merged at 2a8fbf8 and nothing else: undo as
`EditHistory` of `HistoryEntry`/`PageRevision` (`PageState.swift:137-181`),
the navigator sheet with its reorder, duplicate and delete, export as
`export.md` left it, and the library browser as `loose-ends.md` left it.

## 8. Review disposition

Three reviewers read this plan on 2026-09-12, two against the simplicity
brief on different models and one against the adversarial brief; the lead
reviewer's consolidated disposition was answered here, and two of its
findings were reached independently by more than one reviewer. Every
finding was adopted. The new durable file is gone, which both simplicity
reviewers reached independently: `FolderDecorations.json`,
`FolderDecorationsFile`, `decorationsURL`, `decorations()`,
`setDecoration(_:for:)`, the browser's `[FolderID: FolderDecoration]` map
and its `decoration(of:)` join are all deleted, because the plan had
rejected a `FolderFile` bump for a silent failure and then bumped
`NotebookIndex` for a louder one and called that sanctioned, and one
Contract sentence cannot answer twice. Colour and symbol are two flat keys
on `.folder.json` at version 2, read by the `folderID(of:)` call every
listing already makes; `FolderColor` carries a neutral case so undecorated
is a value; `LibraryItem` carries the pair; the cost of an unreadable
sidecar is stated in one sentence rather than argued away; and the claim
that `favorites()` was the precedent for not pinning nested keys went with
it, since `FavoritesFile` has no nested objects. Five Contract hunks became
four: the Custody library row went, the Library hunk that would have
promoted an implementation defect into a permanent rule became one clause
on `:332`, the Durable-form hunk is the digit alone because its replacement
kept a fixture-package rule no fixture package in this tree satisfies, and
the Undo paragraph was cut as forcing nothing. Two data-loss defects the
adversarial reviewer found are fixed: `withPages` now drops the bookmarks
of pages it does not carry, without which one page failing to stage writes
an index this build's own `validated()` refuses, and the bump's silence in
`LibraryStore.indexFacts` is decision 2 with a store-level test behind it.
The outline filters the enumerated pairs and not the array, which two
reviewers caught, so an ordinal and its tap target stay the page's own, and
the reorder pair and `addTile` are gated on the All tab.
`DraggedLibraryItems` moved to `LibraryCells.swift` where it compiles; the
same-parent guard moved from the browser and the drop handler into
`LibraryStore.move` beside `rename`'s identical line; `LibraryBrowser.move`
gathers refusals instead of half-moving a selection; the PR 1 refusal test
now drags the folder that holds the open notebook, which is what
`Docs/Contract.md:324-325` actually refuses; and the bump's effect on
`FormatTests.swift:77-90` and five memberwise call sites is listed.
`setBookmark(on:title: String?)` split into `bookmark(_:titled:)` and
`removeBookmark(_:)`, and the toolbar button opens the same titled alert as
the navigator instead of writing an unnameable empty mark; the title itself
survives as decision 1 with the bare flag priced, because the departure
from GoodNotes is real and belongs where Phillip looks for calls. Four
decisions that were facts became three sentences at the end of section 6,
and the vendor survey, the forum vote count, the seventeen-line
`PageRecord` argument, the duplicated out-of-scope list, the restated
navigator paragraph and the `public.data` defect's second and third
statements are gone. Six citations were corrected:
`.destinationInsideSource` at `:354`, `.alreadyExists` at `:356`,
`favorites()` ending at `:403`, `NavigatorPage` having six fields,
`project.yml` carrying four `INFOPLIST_KEY_*` values, and
`LibraryMovePicker`'s "Move here" at `:59`. Rejected: none. One finding was
dropped rather than applied because its evidence did not hold: the review
listed `LibraryItem.identity` as cited at `:41-45` twice, and no such
citation existed in the plan, which already gave `:55-59`, the range the
review itself calls correct.
