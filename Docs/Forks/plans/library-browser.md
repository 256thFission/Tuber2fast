# Library browser

A plan, then code. Branch `plan/library-browser`, based on `v2-mvp`. Every
claim cites the file it was read from.

**In short.** The GoodNotes-style browser from `library-lane-f`, rebuilt
over `TNLibrary`. A sidebar of Documents, Favorites, Trash; one folder at a
time in a grid or a list; sort, filter, name search; select mode with
move, duplicate, trash; rename, new folder, new notebook through the
existing `NewNotebookSheet`; the trash with recover, delete, empty. Covers
are the first page rendered through `Renderer.thumbnail`, keyed by the
package's modification time, cached in memory, never written. Favorites
are one identity-keyed file beside `Notebooks/`. View options are a
preference in `UserDefaults`, on the tool palette's precedent. The browser
model lives in `TNLibrary` so it is tested hostless.

## 1. Data shape

```swift
// Modules/TNLibrary/LibraryStore.swift
package struct LibraryItem {                       // two new fields
    package let folderID: FolderID?               // read from .folder.json; nil for a notebook
    package let createdAt: Date                   // notebook: index.createdAt; folder: the directory's creation date
    package var identity: ItemIdentity?           // .notebook(id) or .folder(id); nil when the sidecar is unreadable
}
package enum ItemIdentity: Hashable, Codable, Sendable { case notebook(NotebookID), folder(FolderID) }

/// `Favorites.json` beside `Notebooks/`: which identities are starred.
package struct FavoritesFile: Codable { formatVersion; notebooks: [NotebookID]; folders: [FolderID] }
// LibraryStore
package func favorites() throws(LibraryError) -> Set<ItemIdentity>
package func setFavorite(_ identity: ItemIdentity, _ starred: Bool) throws(LibraryError)
package func listFavorites() throws(LibraryError) -> [LibraryItem]      // walks the tree; a star on a trashed item is kept, unseen
package func listFolders(in folder: String) throws(LibraryError) -> [LibraryItem]
package func emptyTrash() throws(LibraryError)

/// What a cover is rendered from. The version is the package's newest
/// mtime in milliseconds (`modifiedAt`), so a save moves the key.
package struct CoverSource: Sendable { pageID, geometry, paper: Paper?, bytes: PageBytes, version: UInt64 }
package func coverSource(of relativePath: String) async throws(LibraryError) -> CoverSource
```

```swift
// Modules/TNLibrary/LibraryViewOptions.swift
package enum LibrarySortKey: String, Codable, CaseIterable { case dateCreated, lastModified, name, type }
package enum LibraryLayout: String, Codable { case grid, list }
package struct LibraryViewOptions: Codable, Equatable, Sendable {
    package var layout = LibraryLayout.grid
    package var sortKey = LibrarySortKey.lastModified
    package var ascending = false
    package func tapping(_ key: LibrarySortKey) -> Self   // same key flips; new key takes its default (dates descending, name and type ascending)
    package func sorted(_ items: [LibraryItem]) -> [LibraryItem]  // folders and notebooks interleave; `.type` groups folders first; localizedStandardCompare on name breaks ties
}
package protocol LibraryViewOptionsStore: Sendable { func load() -> LibraryViewOptions?; func save(_:) }
```

```swift
// Modules/TNLibrary/LibraryBrowser.swift
package enum LibrarySection: Hashable { case documents, favorites, trash }
package enum LibraryFilter: CaseIterable { case all, notebooks, folders }
package enum Listing: Equatable { case loading, loaded([LibraryItem]), refused(String) }

@MainActor @Observable package final class LibraryBrowser {
    package let library: Library
    package var section: LibrarySection            // sidebar row; changing it clears search and selection
    package private(set) var folder: String        // path inside Documents; "" at the root
    package var options: LibraryViewOptions        // didSet saves through the store
    package var filter: LibraryFilter
    package var searchText: String
    package private(set) var listing: Listing
    package private(set) var trash: [TrashEntry]
    package private(set) var favorites: Set<ItemIdentity>
    /// nil when not selecting. The set holds relative paths.
    package private(set) var selection: Set<String>?
    package var displayed: [LibraryItem]           // listing, filtered, name-searched (case and diacritic insensitive), sorted
    package var refusal: String?                   // the last refused mutation, one line

    package func reload() async
    package func enter(_ folder: LibraryItem); package func back()
    package func beginSelecting(); endSelecting(); toggleSelected(_:); selectAll()
    package func destinations(excluding: Set<String>) async -> [LibraryItem]   // folders under `folder` for the move picker, minus the moved folders and their subtrees
    package func cover(of item: LibraryItem) async -> CGImage?
    // intentions, each a Library or store call then a reload; a refusal lands in `refusal`
    rename(_:to:), move(_:toFolder:), trash(_:), duplicate(_:), toggleFavorite(_:), createFolder(named:), createNotebook(named:geometry:paper:), recover(_:), deletePermanently(_:), emptyTrash()
}
```

Covers. `Library.cover(of item:)` on the main actor: an open notebook
answers from custody through `Notebook.thumbnail(of: pageIDs.first)`, so
the browser and the navigator share one picture of an open notebook. A
closed one goes through `store.coverSource(of:)` (index and first page
read on the store actor), `Notebook.decode` (made `package`, the one
decode the navigator plan insisted on), and a `Renderer` built over the
package's `PackageStore` so asset paper draws. The `CGImage` lands in
`Library.covers`, a `BoundedCache<CoverKey, CGImage>`. Cache: covers by
`CoverKey(path, version)`. Owner: `Library`. Bound: 32 MB, oldest out.
Evictor: insert, and `purge()` from `Workspace`'s memory-warning observer.
A throwaway `Renderer` per closed cover is one asset decode per render,
which is what an open notebook's first render costs; `BoundedCache`
becomes `package` so `Library` can hold one.

Why not a `Renderer` on the library: its asset reader is one package.
Why not a `Notebook` per cover: a `Notebook` is a checkout, and the
contract has one per package.

## 2. Files

- `Modules/TNLibrary/LibraryStore.swift`: `folderID`, `createdAt` on items; `ItemIdentity`; favorites file and its three operations; `listFolders`; `emptyTrash`; `CoverSource` and `coverSource(of:)`. `trash` and `recover` leave the star alone: identity survives both.
- `Modules/TNLibrary/Library.swift`: `cover(of:)`, `covers`, `purge()`, `setFavorite` (ungated; a star on an open notebook is fine).
- `Modules/TNLibrary/LibraryViewOptions.swift`: the two enums, the options value, the store protocol.
- `Modules/TNLibrary/LibraryBrowser.swift`: the model.
- `Modules/TNNotebook/Notebook.swift`: `LoadOutcome` and `decode` become `package`.
- `Modules/TNRender/Renderer.swift`: `BoundedCache` becomes `package`.
- `TuberNotesApp/LibraryView.swift`: sidebar and content column; the toolbar row (filter chip, search field, "+ New" menu with Notebook and Folder, view options menu with Select Items, Grid, List, the four sort keys); the select-mode bar (Select All, Move, Duplicate, Trash, Done); the folder title and back chevron; empty states.
- `TuberNotesApp/LibraryCells.swift`: grid cell and list row, the cover, the folder glyph, the star, the chevron menu (Rename, Duplicate, Move, Move to Trash).
- `TuberNotesApp/LibraryTrashView.swift`: the trash section, per-row Recover and Delete Permanently (confirmed), Empty (confirmed).
- `TuberNotesApp/LibraryMovePicker.swift`: destination drill-down, "Move here".
- `TuberNotesApp/LibraryViewDefaults.swift`: `LibraryViewOptionsStore` over `UserDefaults`, key `tn.libraryView`, on `fileIOAllowlist` beside `ToolPaletteDefaults.swift` for the same reason.
- `TuberNotesApp/Workspace.swift`: owns the `LibraryBrowser`; the memory-warning observer also calls `library.purge()`. On the device list.
- `TuberNotesApp/LibrarySubviews.swift`: deleted.
- `TuberNotesTests/ContractStructureTests.swift`: `fileIOAllowlist` gains `LibraryViewDefaults.swift`.

## 3. Tests

All in `TNTests`, Swift Testing, `@MainActor` where the model is.

- `LibraryTests`: `createdAt` and `folderID` on listed items; a star round-trips through `favorites()`, `listFavorites` mixes kinds across parents, a star survives rename, move, trash and recover, and is absent from `listFavorites` while trashed; `emptyTrash` removes every container; `listFolders` returns folders only; `coverSource` of a fresh notebook has the first page's geometry and paper and a version equal to the item's `modifiedAt`.
- `LibraryCoverTests`: `Library.cover(of:)` on a closed notebook is exactly `Renderer.thumbnailPixels` for its geometry; a second call hits the cache (same object); a save through an opened and released notebook moves the version and the cover re-renders with the stroke; an open notebook's cover is its notebook's thumbnail; `purge()` empties the cache.
- `LibraryViewOptionsTests`: each key both directions with folders interleaved and `.type` grouped; name is `localizedStandardCompare` ("Note 1, 2, 10"); `tapping` flips the active key and gives a new key its default; options round-trip through an in-memory store and the browser saves on every change.
- `LibraryBrowserTests`: filter narrows and All restores; search is case and diacritic insensitive and clears on `enter`, `back`, and a section change; `enter` and `back` walk the path; selection begins empty, toggles, selects all of `displayed`, ends on a section change; `move` of a selection lands every item and reloads; a refused mutation (open notebook) sets `refusal` and leaves the listing intact; `destinations` excludes the moved folder and its subtree; the favorites section lists starred items and `toggleFavorite` from it unstars; trash section lists, recovers, deletes, empties.

Nothing hosted: no new UIKit surface. Device: the app target and `Workspace` changed, so the browser needs the ten-minute walk `Docs/Unproven.md` names.

## 4. Open questions and picks

1. Trash placement. Spec puts it behind the avatar menu (§9); pick the sidebar row, because there is no avatar and a third row costs nothing.
2. Search scope. In-folder name match, this folder only (spec §8 open question 5); content search is indexing and out.
3. Rename surface. The spec's inline title field (§6.1) versus the existing alert; pick the alert, one fewer popover, same result.
4. Shared section. Spec §1.1 lists it; it is collaboration, which `AGENTS.md` forbids early. Left out.
5. Folder colour and icon. Spec §3; needs `.folder.json` to grow, a format change. Left out; the hunk is in section 5.
6. Move to Trash confirmation. Spec is conflicting (§6.5); no confirmation, the trash is the undo.
7. Favorites storage. Identity-keyed file beside `Notebooks/` rather than paths, so a star survives rename and move with no rewriting, and survives the trash.
8. Cover for an open notebook. Custody, not files, so an unsaved stroke shows.
9. Multi-select in the trash. Out; per-row only.

## 5. Contract sentences

For Phillip's `CONTRACT:` commit.

Library, after the `.folder.json` sentence, add: "Favorites are
`Favorites.json` beside `Notebooks/`, a set of `NotebookID`s and
`FolderID`s written whole. A star follows the item through rename, move,
trash, and recovery, and shows nowhere while the item is in the trash."

Library, add: "A cover is a notebook's first page rendered as a thumbnail.
An open notebook's cover comes from its `Notebook`; a closed one is read
by `LibraryStore` and rendered by a `Renderer` over that package, keyed
by the package's modification time, cached by `Library` in memory (32 MB),
and never written to the package."

Custody table, add: "| Library covers | `Library` | in memory, keyed by path and modification time; rebuilt from the first page |"
and "| Favorites | `LibraryStore` | `Favorites.json` |".

Structure, quoted: "File I/O happens in `PosixFileSystem`, `LibraryStore`,
and `ImportReader`, and nowhere else." The allowlist already carries
`ToolPaletteDefaults.swift` as a preference exception; `LibraryViewDefaults.swift`
joins it on the same reasoning and the sentence needs no change if the
palette's did not.

Not adopted, recorded: folder colour and icon would add "and its colour
and icon" to the `.folder.json` sentence.

## 6. Out of scope

Shared, folder decoration, drag and drop, export, content search, a disk
tier for covers, trash multi-select, keyboard and pointer.
