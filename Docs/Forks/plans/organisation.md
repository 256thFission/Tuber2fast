# Organisation depth: bookmarks, an outline, folder decoration, drag and drop

A plan, not code. Branch `v2-mvp` (2a8fbf8). Every claim below cites the
file it was read from; paths are relative to that worktree.

**In short.** Four features, three pull requests, cheapest first. Drag and
drop is nearly free: every layer of a move exists and is tested, and
`PageNavigatorSheet.swift:97-102` is a `.draggable`/`.dropDestination` pair
to copy; missing are a `Transferable`, drop targets on two cells, and one
guard in `LibraryStore.move` that `rename` already carries. Folder colour
and symbol go in `.folder.json`, the sidecar whose doc comment already
calls it "A folder's identity and decoration sidecar", at version 2. The
bookmark carries its own title, so the outline is the marked pages read
from the index the notebook already holds, shown in a tab of a sheet that
exists. Two format bumps, four `CONTRACT:` hunks, nothing undoable.

## 0. Where it stands today

**Drag and drop: the engine is built, the gesture is not.** A move exists
at all three layers, each refusing for its own reason:
`LibraryStore.move(at:toFolder:)`
(`Modules/TNLibrary/LibraryStore.swift:350-360`), a folder into itself
(`:354`) and a name collision (`:356`); `Library.move`
(`Modules/TNLibrary/Library.swift:116-119`) through `requireUnlocked`
(`:105-109`), whose `isLocked` (`:55-60`) covers a folder holding an open
notebook; `LibraryBrowser.move`
(`Modules/TNLibrary/LibraryBrowser.swift:184-189`) inside `perform`
(`:168-178`), which sets `refusal` and reloads, `LibraryView` raising it as
a banner (`TuberNotesApp/LibraryView.swift:47-49`). Two tests cover the
move and the destinations `destinations(in:excluding:)` (`:151-156`)
computes (`TNTests/LibraryBrowserTests.swift:153-170`, `:193-205`); none
covers a refused move, since `:172-191` reads as one but refuses a `trash`.
No `draggable`, `dropDestination`, `onDrag` or `onDrop` appears in the
library UI, and a move is raised from a menu into a drill-down sheet whose
"Move here" confirms the level showing (`LibraryMovePicker.swift:59`).

**Folder decoration: nothing, though the record was named for it.**
`FolderFile` (`LibraryStore.swift:6-15`) holds a version and a `FolderID`
and nothing else, and the folder glyph is a fixed SF Symbol in one accent
colour (`TuberNotesApp/LibraryCells.swift:184-191`). The sidecar is read on
every listing already, `item(at:url:kind:)` calling `folderID(of:)` for
every folder (`LibraryStore.swift:235-246`, the call at `:242`), which
opens and strictly decodes it (`:304-311`), so two more keys cost no read.
Both cells stack overlays on the artwork, star `:26`, check `:30`, lock
badge `:33-41`, so a decorated glyph and a drop highlight have hosts.

**Bookmarks and an outline: nothing, and no page has a name.** No `.swift`
file mentions either. `PageRecord` is four fields
(`Modules/TNModel/NotebookIndex.swift:7-10`), `NavigatorPage` six
(`Modules/TNEditor/EditorViewModel.swift:11-23`; the comment at `:64`
calling it five is stale, do not copy it), and a navigator cell draws an
ordinal from an enumeration index (`PageNavigatorSheet.swift:40-41`). The
navigator sheet has an outline's whole surface: a toolbar (`:37`,
`:48-52`), a grid of `navigatorPages` (`:39-44`), a tap that dismisses and
scrolls (`:79-82`), and thumbnails `Notebook.thumbnail(of:)` gives for an
unloaded page while installing nothing (`Notebook.swift:632-639`).

**The mirror refresh is the fact the outline turns on.**
`EditorBinding.intention(_:)` runs a mutation then `drain()`
(`Modules/TNEditor/EditorBinding.swift:179-182`), which calls `onDrained`
(`:158`), which is `refreshMirrors` (`EditorViewModel.swift:97`), rebuilding
`navigatorPages` from `notebook.index.pages` (`:115-127`). It runs whether
or not the mutation queued a change, so a bookmark needs **no** new
`NotebookChange` case (`NotebookChange.swift:8-15`) and no `emitStructure`.
Nor is it undoable: `PageRevision` is `ink`, `layers` and `inkIndex`
(`PageState.swift:137-141`).

## 1. What GoodNotes does here, and what this plan matches

Matched: a per-page mark toggled from the page and surfaced as a filter at
the top of the thumbnail panel, where GoodNotes and Notability both put it;
a tap on an entry to go to its page; a folder's colour and symbol from the
item's own menu; documents and folders dragged onto folder cells.

Not matched, deliberately: **this plan merges two structures into one.**
GoodNotes keeps an untitled bookmark flag and a separate titled outline
that is generated, renamed, reordered and nested. Here the mark carries an
optional title, so one flag is both: an entry is a page, its order is the
page order, and nothing generates an entry from a document. Section 5 says
what that rules out. One lesson taken rather than matched: GoodNotes' forum
asked for the bookmark icon back after it moved into a More menu, so the
toggle here is a toolbar button showing the current state.

## 2. The data shape

Two durable changes: one list on the notebook index, two keys on
`.folder.json`. Drag and drop stores nothing. Both bumps rest on
`Docs/Contract.md:14-16`: "**Burn things down with permission.** There are
no users and no data to keep."

### The bookmark carries the title

```swift
// Modules/TNModel/NotebookIndex.swift

/// One marked page and what it is called. Presence is the mark: there is
/// no "bookmarked: false". `title` may be empty, a mark nobody named, and
/// the outline then shows that page's number, computed from the order.
package struct PageBookmark: Codable, Sendable, Equatable {
    package let page: PageID
    package let title: String
}

// On NotebookIndex, beside `pages`, in insertion order, which means
// nothing: the outline reads `pages` and picks the marked ones out of it.
package let bookmarks: [PageBookmark]
package static let currentFormatVersion: UInt32 = 3   // was 2
```

Owner: `Notebook`, in `NotebookIndex`, Custody's second row. A list and not
a field on `PageRecord` because `JSONEncoder` omits a nil optional while
`TNTests/FormatTests.swift:15` and `IndexFile.decode`
(`Modules/TNFormat/PackageStore.swift:561`) pin that record's key set
exactly, and non-optional grows it to six fields and makes
`bookmarked: false, title: "x"` representable. `validated()`
(`NotebookIndex.swift:91-104`) gains two checks, a bookmark on a page the
index does not hold and two for one page, each refusing the notebook, the
narrowest scope for an index fault (`Docs/Contract.md:202-203`).

**`withPages` drops the bookmarks of pages it does not carry.** One line,
and load-bearing. Publish 3 of a save writes `intended.withPages(present)`
when a page failed to stage (`PackageStore.swift:355-360`), so without it a
page that fails to stage while holding a bookmark writes an index this
build's own `validated()` refuses and the notebook never opens again, where
`:202-203` says a missing page file refuses that page only. With the line,
`deletePage` needs no filter of its own.

`Notebook` gains `bookmark(_ page: PageID, titled: String)` and
`removeBookmark(_ page: PageID)`, not one call taking `String?`, which
would be a command argument shaped like a durable value. Each body is
`index = index.withBookmarks(...)`, `indexSeq += 1`, `markDirty()`:
`setPaper`'s shape (`Notebook.swift:594-612`) without the asset checks, the
geometry and the re-render. A page the index does not hold traps,
`movePage` needs nothing, `duplicatePage` does not copy the mark because it
ends in `insertPage` (`:573`) which touches no index field but `pages`
(`:486`), and `withNotebookID` (`NotebookIndex.swift:85-87`) carries the
list. In `TNEditor`, `NavigatorPage` gains `bookmark: String?`, nil
unmarked and `""` marked and unnamed, a read model and not the tri-state
above since nil is absence from the list; `EditorViewModel` gains the two
intentions, each one `binding.intention { }` in `deletePage`'s shape
(`:319-321`), and `refreshMirrors` (`:107-128`) builds one
`[PageID: String]` beside its `records` local (`:115`). No new observed
property on `Notebook`, whose surface is five (`Docs/Contract.md:78-82`).

### Folder colour and symbol

```swift
// Modules/TNLibrary/LibraryStore.swift

/// Named, not bytes: a name maps to something the app can draw for light
/// and dark, a symbol's raw value *is* its SF Symbol name, and a name this
/// build does not ship refuses the sidecar. `.neutral` is the colour every
/// folder draws today: undecorated is a value, not an absence (:209-210).
package enum FolderColor: String, Codable, Sendable, CaseIterable { /* neutral + 7 */ }
package enum FolderSymbol: String, Codable, Sendable, CaseIterable { /* folder + 5 */ }

/// The pair a cell draws with. Not `Codable`: the keys are flat on
/// `FolderFile`, so `decodeStrict` at :307 pins them with no nested check.
package struct FolderDecoration: Sendable, Equatable {
    package let color: FolderColor; package let symbol: FolderSymbol
}

package struct FolderFile: Codable, Sendable, Equatable {
    package let formatVersion: UInt32
    package let folderID: FolderID
    package let color: FolderColor
    package let symbol: FolderSymbol
    package static let currentFormatVersion: UInt32 = 2   // was 1
}
```

Owner: `LibraryStore`, Custody's ninth row and the file-I/O allowlist's
second entry (`Docs/Contract.md:377-378`). The cost of the bump, plainly: a
`.folder.json` this build cannot read makes `folderID(of:)` answer nil, so
the folder's `LibraryItem.identity` is nil (`:55-59`), its star stops
resolving (`LibraryBrowser.swift:85-87`), and trashing it mints a fresh
container name (`LibraryStore.swift:458`), with nothing surfaced. That path
already exists for a corrupt sidecar; the remedy is deleting the library.

`folderID(of:)` (`:304-311`) becomes `folderFile(of:) -> FolderFile?` with
`folderID(of:)` as `folderFile(of:)?.folderID`, and its `expectedKeys`
literal at `:307` gains `"color"` and `"symbol"`. `createFolder` (`:294`)
writes `.neutral` and `.folder`. `LibraryItem` gains
`decoration: FolderDecoration?`, nil for a notebook exactly as `folderID`
is, filled in `item(at:url:kind:)` beside it (`:242`). One
`setDecoration(_:at:)` reads the sidecar, replaces the two fields and
writes it whole and atomically, the way `setFavorite` does (`:407-431`), so
the browser needs no map and no join: the decoration rides the item.

### Where the outline appears

The two-value `Picker` goes in the toolbar `PageNavigatorSheet` already has
(`:48-52`), and **the filter is over the enumerated pairs, not the array.**
The grid numbers cells from the enumeration index of what it is given,
`cell(page, number: position + 1)` (`:40-41`), and the tap uses that number
as an absolute index, `editor.scroll(toPageIndex: number - 1)` (`:81`), so
filtering the array would label the third bookmark of a 40-page notebook
"Page 3" and scroll to page 3. The `ForEach` filters
`Array(editor.navigatorPages.enumerated())`, `number` stays the page's own
position, and the reorder pair (`:97-102`), whose `before:` is meaningless
in a filtered list, and `addTile` (`:124-147`) are gated on the All tab.

## 3. The steps

Three pull requests, cheapest first, so a night that stops early still
lands something. PR 1 changes no file format, PR 2 bumps a one-file
sidecar, PR 3 bumps the package format; neither PR 2 nor PR 3 needs PR 1.

**PR 1. Drag and drop in the library.** Commit 1 is a pre-existing defect
found on the way: moving an item into the folder it is already in throws
`.alreadyExists` and banners a refusal for a no-op, which the move picker
reaches because "Move here" confirms the level showing (`:59`) and
`destinations(in:excluding:)` does not exclude the current parent. Fix it
at the source, in `LibraryStore.move`, after `target` at `:355`:
`guard target != source else { return item(at: relativePath, url: source, kind: kind) }`,
`rename`'s own line at `:342` word for word. That fixes the picker, the
drag and every future caller, and leaves the drop handler nothing to guard.

Commit 2 makes a multi-item move survive one refusal. `LibraryBrowser.move`
loops inside `perform` and throws on the first failure with the earlier
paths already moved (`:184-189`), and dragging a selection holding an open
notebook is the ordinary gesture. It stops using `perform` and gathers: a
`do`/`catch` per path, the descriptions joined into `refusal`,
`selection = nil`, then `reload()`.

Commit 3 is the drag. `LibraryCells.swift` gains
`import UniformTypeIdentifiers` and, not `private` because both cells and
`LibraryView` need it, `struct DraggedLibraryItems: Transferable, Codable`
holding `paths: [String]` over `CodableRepresentation(contentType: .data)`,
carrying the navigator's `KNOWN DEFECT:` across by cross-reference
(`PageNavigatorSheet.swift:10-16`). Both cells gain `.draggable`, carrying
`browser.selection?.contains(item.relativePath) == true ? selection : [item.relativePath]`,
and on the folder arm `.dropDestination(for:isTargeted:)`, the highlight
drawn through the overlay stack already there (`:29-42`, `:96-102`). Each
cell takes a `drop: (Set<String>) -> Void` beside its `menu:`, because the
move must go through `LibraryView.run`, which clears the refusal and
rebuilds the identity index afterwards (`:359-365`); the call sites at
`:294` and `:306` pass
`{ paths in run { await browser.move(paths, toFolder: item.relativePath) } }`
and the closure returns true, every refusal being the store's or the
ledger's. `LibraryView` also puts a `.dropDestination` on the back chevron
(`:103-112`), moving to the parent path when inside a folder.

Tests, `LibraryBrowserTests.swift`: moving an item into the folder it is
already in is a no-op, not a refusal; a drop *of* a folder holding an open
notebook refuses with the notebook's name, dragging the folder and not a
neighbour, because `Library.move` calls `requireUnlocked` on the source
only (`Library.swift:116-119`) and `Docs/Contract.md:324-325` refuses
moving the folder above the notebook, not moving something next to it; a
three-item move with one open notebook lands the other two and refuses
once. Plus `LibraryTests.swift`: a move into the current parent returns the
item and moves no files. Verification: simulator, neither view file being
on either list in `CONTRIBUTING.md:107-113`; the PR records an iPad pass
anyway, because whether a drag off a grid cell beats the grid's own scroll
is a touch fact (`Docs/Unproven.md:314`).

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
for a folder only, and a `.sheet(item:)` beside the others (`:50-69`). New
`TuberNotesApp/FolderStyleSheet.swift`: swatches over a grid of symbols,
presented the way `NewNotebookSheet` is (`:55-59`). Tests,
`LibraryTests.swift`: colour and symbol round trip and a new folder is
neutral; decoration follows the folder through rename, move, trash and
recovery, the shape of `:261-280`; a colour name this build does not know
refuses the sidecar, so the folder loses its identity, which pins the cost
above; `FolderFile` carries exactly its keys. Plus `LibraryBrowserTests`:
setting a decoration reloads the listing and the item carries it. Verify on
the simulator (`CONTRIBUTING.md:121-122`).

**PR 3. The page bookmark and the outline.** `NotebookIndex.swift`:
`PageBookmark`; `bookmarks` on the index and in both initializers;
`withBookmarks`; `withNotebookID` carrying the list and `withPages`
dropping the bookmarks of pages it does not carry; two `validated()` checks
and two `NotebookIndexFault` cases; `new` passing `[]`;
`currentFormatVersion` 3. `Codecs.swift`: `DurableKeys.index` gains
`"bookmarks"` and `DurableKeys.bookmark` is `["page", "title"]`.
`PackageStore.swift`: `IndexFile.decode` (`:556-571`) pins the nested
bookmark objects as it pins page records at `:561`. `Notebook.swift` and
`EditorViewModel.swift`: the two intentions each, plus
`NavigatorPage.bookmark` and one map in `refreshMirrors`.
`PageNavigatorSheet.swift`: the `Picker`, the filter over the enumerated
pairs, the gate on the reorder pair and `addTile`, a ribbon and the title
under the ordinal in `cell(_:number:)` (`:71-121`), a "Bookmark page" item
in the context menu (`:103-120`), and an `.alert` with a `TextField`, the
shape `LibraryView` uses twice (`:50-54`, `:60-64`), carrying Cancel, Save,
and Remove when the page is marked. `EditorView.swift`: one button in the
`pages` group (`:137-165`), filled or not from
`editor.navigatorPages[editor.currentPageIndex].bookmark`, opening that
same alert pre-filled, so a page marked from the toolbar can be named
without being unmarked first.

Every notebook on disk is format 2 and lacks the key, so `IndexFile.decode`
refuses it with `.missingKey("bookmarks")` (`Codecs.swift:56-63` says why
missing wins over the version), reaching the app as `.failed(.format(...))`
from `Library.checkout` (`Library.swift:82-84`). Loud on open and silent in
the library, which decision 2 prices. No migrator.

Three existing tests move. `FormatTests.swift:77-90` sets
`object["formatVersion"] = 3` and expects `unsupportedFormatVersion(3)`
(`:80`, `:82`); at version 3 that cannot hold, so the probe becomes 4. The
memberwise `NotebookIndex(notebookID:createdAt:pages:)` gains `bookmarks:`,
touching `FormatSupport.swift:40` and `FormatTests.swift:97`, `:120`,
`:261`, `:547`, each passing `[]`. `indexKeys` (`:8-19`) gains the bookmark
array and asserts `formatVersion == 3` at `:18`.

New tests. `FormatTests.swift`: a bookmark on a page the index does not
hold refuses the notebook; two bookmarks for one page refuse it;
`withPages` that drops a page drops its bookmark and the result validates.
`NotebookTests.swift`: a bookmark dirties the index, survives a flush and a
reopen and leaves `canUndo` unchanged, the shape of `:572-603`; deleting a
bookmarked page takes its bookmark; moving pages reorders the outline
without touching the list. `LibraryTests.swift`: a format-2 package lists
with a nil identity, written directly and asserted through `list(folder:)`.
`EditorViewModelTests.swift`: a bookmark reaches `navigatorPages` through
the drain with no structure change.

Verification: `TNEditor` is on the definition of done's device list
(`AGENTS.md`), so this PR takes iPad evidence: marking the current page
shows the ribbon with no page turn and no canvas reload; a named mark shows
in the outline tab; the outline is in page order after a reorder and its
ordinals are the pages' own; a row dismisses and lands on its page; a mark
survives backgrounding. What is not done goes to `Docs/Unproven.md`.

## 4. Contract

Every hunk is Phillip's `CONTRACT:` commit; this is the proposal. Hunk 4
belongs to PR 2, hunks 1 to 3 to PR 3. PR 1 needs none.

**1. Custody, `Docs/Contract.md:44`.** One row, one cell.

```
quoted:       | Page order, paper, geometry | `Notebook` | `NotebookIndex` |
replace with: | Page order, paper, geometry, page bookmarks | `Notebook` | `NotebookIndex` |
```

Row 51 needs none: decoration is inside "the library tree", which it says.

**2. One save, `Docs/Contract.md:228-230`.** Forced: the paragraph states
an exhaustive list the code will break.

quoted: "- **A save writes only what changed.** An unchanged page file is
not rewritten. The index is rewritten only when order, paper, or geometry
changed. Rewriting an unchanged file is a bug."

replace with: "- **A save writes only what changed.** An unchanged page
file is not rewritten. The index is rewritten only when order, paper,
geometry, or a page bookmark changed. Rewriting an unchanged file is a
bug."

**3. Durable form, `Docs/Contract.md:139`.** The digit alone: quoted
"**Format version is 2.**", replace with "**Format version is 3.**" The
rest of the paragraph stands, "a round-trip test from a fixture package
checked into the repo" included: no fixture package exists in this tree, so
a rewrite would put a rule in force that this pull request does not meet.

**4. Library, `Docs/Contract.md:332`.** One clause. quoted: "A folder has a
`.folder.json` holding its `FolderID`." replace with: "A folder has a
`.folder.json` holding its `FolderID`, its colour, and its symbol."

**No Undo hunk.** "Undo belongs to the notebook. There is one stack per
notebook, holding ink values" (`:265-266`) already excludes a bookmark, a
colour and a move, and this plan adds no record site; the
`bookmark(_:titled:)` doc comment is that fact's right home.

## 5. Out of scope

Bookmarked pages in the library's Favorites section, which GoodNotes does
and which here would need a `.page` case on `ItemIdentity`
(`LibraryStore.swift:26-32`) and give `TNLibrary` knowledge of notebook
interiors it does not have. An outline derived from a PDF's outline, from
heading styles or from handwriting, which needs either a heading model this
app lacks or the full-notebook read open avoids (`Docs/Contract.md:359`);
with it go nesting, reordering, renaming an entry independently of its
page, and one page under two entries. A persistent outline panel instead of
the sheet's tab, a layout change to `EditorView`, the sheet having been
chosen over a full-screen cover for a stated reason (`:67-71`). A colour or
symbol on a notebook, which has no sidecar. Undo for any of the four, and
the ten deferred features.

## 6. Decisions

1. **The mark carries a title, or is a bare flag.** Recommendation: the
   title, because an all-unnamed outline is the thumbnail grid filtered and
   nothing more, and the title is why this plan needs no second structure.
   It costs one `String` in a record that would otherwise be one `PageID`,
   plus an alert with a text field on two surfaces. The alternative is both
   reference apps' shape: drop `title` from `PageBookmark`, the alert, the
   text field and the label under the ordinal, and the marked tab shows
   thumbnails only. Choosing that now costs nothing already built; choosing
   it after marks are on disk costs a format bump. It is the plan's one
   real departure from GoodNotes, so it is a decision, not an assertion.
2. **The index bump is loud on open and silent in the library.**
   `IndexFile.decode` refuses a format-2 package by the key it is missing,
   but `LibraryStore.indexFacts(ofPackageAt:)` decodes the same index with
   `try?` and returns nil on any fault (`:224-229`). After the bump every
   pre-existing package therefore lists with `notebookID: nil` (`:241`) and
   identity nil (`:55-59`), which drops its star
   (`LibraryBrowser.swift:85-87`), makes `toggleFavorite` a no-op (`:209`),
   skips it in `scanIdentities` (`LibraryStore.swift:592`), re-mints its
   trash container name (`:457`), sorts it by file creation date (`:243`),
   and draws a blank cover (`Library.swift:151`): healthy in the grid until
   you tap it. Recommendation: accept it, delete the dev library, and pin
   the behaviour with the store-level test PR 3 adds. The alternative,
   making `indexFacts` throw, makes `item(at:url:kind:)` throwing
   (`:235-246`) and one unreadable package refuse a whole listing.
3. **The `public.data` drag defect.** Recommendation: defer, carrying the
   `KNOWN DEFECT:` block across with a cross-reference, since the fix needs
   a `UTExportedTypeDeclarations` array with no `INFOPLIST_KEY_` form and
   the app target generates its plist (`project.yml:220`).

Closed, not decisions. Colour is a named palette and not `RGBA8`, because
`TNLibrary` may not import SwiftUI (`Docs/Contract.md:379-380`), so the
mapping is the app's either way and a name fails loud at decode for free. A
hover highlight may promise a drop that is then refused, because
`dropDestination` exposes a `Bool` and no payload during hover; the refusal
lands in the banner that exists. A duplicated page does not carry its mark,
`duplicatePage` ending in `insertPage`, which touches only `pages`.

## 7. Cross-plan

The sibling wave-4 plan is `capture.md`, and it shares two files textually
and nothing else: the `EditorView` toolbar `HStack` (`:96-115`), where this
plan adds a bookmark button to the `pages` group and `capture.md` adds rows
to `insertMenu`, and `EditorViewModel.swift`, where this plan adds a
`MARK: Bookmarks` section and `capture.md` an import intention beside
`importImage` (`:393-399`). Neither plan needs the other. This plan assumes
what is merged at 2a8fbf8 and nothing else: undo as `EditHistory` of
`HistoryEntry`/`PageRevision` (`PageState.swift:137-181`), the navigator
sheet with its reorder, duplicate and delete, export as `export.md` left
it, and the library browser as `loose-ends.md` left it.

## 8. Review disposition

Three reviewers read this plan on 2026-09-12, two against the simplicity
brief on different models and one adversarially, and the lead reviewer's
consolidated disposition was answered here; two of its findings were
reached independently by more than one reviewer, and every finding was
adopted. `FolderDecorations.json` is gone, which both simplicity reviewers
reached on their own, and with it the file struct, `decorationsURL`,
`decorations()`, `setDecoration(_:for:)` and the browser's decoration map
and join: the plan had rejected a `FolderFile` bump for a silent failure
and then bumped `NotebookIndex` for a louder one and called that
sanctioned. Colour and symbol are now two flat keys on `.folder.json` at
version 2, with a neutral `FolderColor` case, the pair on `LibraryItem`,
the cost of an unreadable sidecar in one sentence, and the wrong claim that
`favorites()` was the precedent for pinning nested keys struck. Five
Contract hunks became four: the Custody library row went, the Library hunk
that would have promoted an implementation defect into a permanent rule
became one clause on `:332`, the Durable-form hunk is the digit alone, and
the Undo paragraph was cut. Both data-loss defects the adversarial reviewer
found are fixed: `withPages` drops the bookmarks of pages it does not
carry, and the bump's silence in `LibraryStore.indexFacts` is decision 2
with a test behind it. The outline filters the enumerated pairs and not the
array, which two reviewers caught, so an ordinal and its tap target stay
the page's own. `DraggedLibraryItems` moved to `LibraryCells.swift`, the
same-parent guard moved into `LibraryStore.move` beside `rename`'s
identical line, `LibraryBrowser.move` gathers refusals instead of
half-moving a selection, the refusal test drags the folder that holds the
open notebook rather than a neighbour, and the bump's effect on
`FormatTests.swift:77-90` and five memberwise call sites is listed.
`setBookmark(on:title: String?)` split in two, the toolbar button opens the
navigator's titled alert instead of writing an unnameable empty mark, and
the title survives as decision 1 with the bare flag priced. Four decisions
that were facts became three closing sentences, and the vendor survey, the
vote count, the seventeen-line `PageRecord` argument, the duplicated
out-of-scope list and the `public.data` repetitions are gone; six citations
were corrected. Rejected: none. One finding was dropped because its
evidence did not hold: the review listed `LibraryItem.identity` as cited at
`:41-45` twice, and no such citation existed in the plan, which already
gave `:55-59`.
