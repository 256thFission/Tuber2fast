import Foundation
import Observation
// A cover is a `CGImage`, and `TNLibrary` may not import CoreGraphics:
// PencilKit brings it, as it does for `TNNotebook`'s thumbnails.
import PencilKit
import TNModel

package enum LibrarySection: Hashable, Sendable {
    case documents, favorites, trash
}

package enum LibraryFilter: CaseIterable, Sendable {
    case all, notebooks, folders
}

/// What a listing is right now. Refused is a state, not an empty list, so
/// a folder that cannot be read never looks like one with nothing in it.
package enum Listing: Equatable, Sendable {
    case loading
    case loaded([LibraryItem])
    case refused(String)

    package var items: [LibraryItem] {
        if case .loaded(let items) = self { return items }
        return []
    }
}

/// The browser's state on the main actor: where you are, how it is shown,
/// what is selected. Views draw it and send intentions; every intention is
/// a `Library` or store call and then a reload, never an optimistic edit,
/// so what is drawn is what is on disk.
@MainActor @Observable
package final class LibraryBrowser {
    @ObservationIgnored package let library: Library
    @ObservationIgnored private let optionsStore: any LibraryViewOptionsStore

    package var section = LibrarySection.documents {
        didSet { if section != oldValue { leaveListing() } }
    }
    package private(set) var folder = ""
    package var options: LibraryViewOptions {
        didSet { if options != oldValue { optionsStore.save(options) } }
    }
    package var filter = LibraryFilter.all
    package var searchText = ""
    package private(set) var listing = Listing.loading
    package private(set) var trash: [TrashEntry] = []
    package private(set) var favorites: Set<ItemIdentity> = []
    /// nil when not selecting. Paths, because that is what a mutation takes.
    package private(set) var selection: Set<String>?
    /// One line: the last refused intention, or else the stars' fault. An
    /// intention that lands clears it, but the reload after it raises the
    /// stars' fault again while they cannot be read, so it is no sign that
    /// an intention landed; `perform`'s result is.
    package var refusal: String?

    package init(library: Library, optionsStore: any LibraryViewOptionsStore) {
        self.library = library
        self.optionsStore = optionsStore
        self.options = optionsStore.load() ?? LibraryViewOptions()
    }

    package var title: String {
        switch section {
        case .documents: folder.isEmpty ? "Documents" : String(folder.split(separator: "/").last ?? "")
        case .favorites: "Favorites"
        case .trash: "Trash"
        }
    }

    package var isSelecting: Bool { selection != nil }

    /// The listing, narrowed by the filter and the search, in the sort.
    package var displayed: [LibraryItem] {
        let narrowed = listing.items.filter { item in
            switch filter {
            case .all: true
            case .notebooks: item.kind == .notebook
            case .folders: item.kind == .folder
            }
        }.filter { matches($0.name) }
        return options.sorted(narrowed)
    }

    /// The trash, narrowed by the search. The trash is its own list and is
    /// never in `listing`, so a search standing in the trash section looks
    /// at the trash and nothing else, as a search anywhere else looks at
    /// everything but the trash.
    package var displayedTrash: [TrashEntry] {
        trash.filter { matches($0.name) }
    }

    private func matches(_ name: String) -> Bool {
        searchText.isEmpty || name.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    package func isFavorite(_ item: LibraryItem) -> Bool {
        item.identity.map(favorites.contains) ?? false
    }

    // MARK: Reading

    package func reload() async {
        // The stars refuse alone (*An unreadable sidecar refuses only the
        // item it describes*): none shows, the Favorites section refuses
        // through its own read of the file, and everything else lists. The
        // line is raised unless an intention's own refusal is showing.
        do {
            favorites = try await library.store.favorites()
        } catch {
            favorites = []
            if refusal == nil { refusal = error.description }
        }
        do {
            switch section {
            // A search reads the whole tree from the root, wherever the
            // reader is standing: searching is looking for something you
            // cannot see, and the folder or the stars you are looking at
            // are the part you can. The trash is not in the tree, so a
            // search here never finds a trashed item.
            case .documents where !searchText.isEmpty, .favorites where !searchText.isEmpty:
                listing = .loaded(try await library.store.listTree(under: ""))
            case .documents: listing = .loaded(try await library.store.list(folder: folder))
            case .favorites: listing = .loaded(try await library.store.listFavorites())
            // The trash is its own list, so the listing holds nothing rather
            // than staying at `.loading` while the section is on screen.
            case .trash:
                trash = try await library.store.listTrash()
                listing = .loaded([])
            }
        } catch {
            // The trash draws `trash`, so a refused read leaves no stale
            // rows behind it and nothing for Empty to count.
            if section == .trash { trash = [] }
            listing = .refused(error.description)
        }
    }

    package func enter(_ item: LibraryItem) {
        guard item.kind == .folder else { return }
        section = .documents
        folder = item.relativePath
        leaveListing()
    }

    /// One level up from the folder showing: where `back()` goes, and so
    /// where a drop on the way back lands.
    package var parentFolder: String { LibraryPath.parent(of: folder) }

    package func back() {
        folder = parentFolder
        leaveListing()
    }

    /// A new place has its own search and no selection.
    private func leaveListing() {
        searchText = ""
        selection = nil
        listing = .loading
    }

    // MARK: Selecting

    package func beginSelecting() { selection = [] }
    package func endSelecting() { selection = nil }

    package func toggleSelected(_ item: LibraryItem) {
        guard var set = selection else { return }
        if set.contains(item.relativePath) { set.remove(item.relativePath) } else { set.insert(item.relativePath) }
        selection = set
    }

    package func selectAll() {
        guard selection != nil else { return }
        selection = Set(displayed.map(\.relativePath))
    }

    /// Folders under `folder` a move could land in, minus the moved
    /// folders and everything inside them. A level that cannot be read is
    /// refused, never shown as one with no folders in it.
    package func destinations(in parent: String, excluding moved: Set<String>) async -> Listing {
        do {
            let folders = try await library.store.listFolders(in: parent)
            return .loaded(folders.filter { candidate in
                !moved.contains { $0 == candidate.relativePath || candidate.relativePath.hasPrefix($0 + "/") }
            })
        } catch {
            return .refused(error.description)
        }
    }

    // MARK: Covers

    package func cover(of item: LibraryItem) async -> CGImage? {
        await library.cover(of: item)
    }

    // MARK: Intentions

    /// Untyped because a closure does not infer a typed throw; every call
    /// inside throws `LibraryError`, and the fallback names anything else.
    /// What the work returned, or nil when it was refused, read before the
    /// reload can raise the stars' fault.
    @discardableResult
    private func perform<Made>(_ work: () async throws -> Made) async -> Made? {
        var made: Made?
        do {
            made = try await work()
            refusal = nil
        } catch let error as LibraryError {
            refusal = error.description
        } catch {
            refusal = "\(error)"
        }
        await reload()
        return made
    }

    package func rename(_ item: LibraryItem, to name: String) async {
        await perform { _ = try await library.rename(at: item.relativePath, to: name) }
    }

    /// Every movable item moves, and the ones that refused are named in one
    /// line. Not `perform`, which stops at the first refusal with the earlier
    /// paths already moved: that is liveable from a menu, where a move is
    /// chosen item by item, and wrong under a drag, where hauling a selection
    /// that happens to contain an open notebook is the ordinary gesture.
    package func move(_ paths: Set<String>, toFolder destination: String) async {
        var refusals: [String] = []
        for path in paths.sorted() {
            do {
                _ = try await library.move(at: path, toFolder: destination)
            } catch {
                refusals.append(error.description)
            }
        }
        refusal = refusals.isEmpty ? nil : refusals.joined(separator: "; ")
        selection = nil
        await reload()
    }

    package func trash(_ paths: Set<String>) async {
        await perform {
            for path in paths.sorted() { _ = try await library.trash(at: path) }
        }
        selection = nil
    }

    /// Notebooks only; a folder in the set is passed over, as the spec's
    /// menu has no Duplicate for folders.
    package func duplicate(_ paths: Set<String>) async {
        let notebooks = listing.items.filter { paths.contains($0.relativePath) && $0.kind == .notebook }
        await perform {
            for item in notebooks { _ = try await library.duplicateNotebook(at: item.relativePath) }
        }
        selection = nil
    }

    package func toggleFavorite(_ item: LibraryItem) async {
        guard let identity = item.identity else { return }
        let starred = !favorites.contains(identity)
        await perform { try await library.store.setFavorite(identity, starred) }
    }

    package func setDecoration(_ decoration: FolderDecoration, on item: LibraryItem) async {
        await perform { try await library.store.setDecoration(decoration, at: item.relativePath) }
    }

    package func createFolder(named name: String) async {
        await perform { _ = try await library.store.createFolder(named: Self.name(name, or: "New folder"), in: folder) }
    }

    /// The notebook made, for the caller to open, or nil when the store
    /// refused; the refusal is in `refusal`.
    @discardableResult
    package func createNotebook(named name: String, geometry: PageGeometry, paper: DrawnPaper) async -> LibraryItem? {
        let made = await perform {
            try await library.store.createNotebook(named: Self.name(name, or: "New notebook"), in: folder, geometry: geometry, paper: paper)
        }
        // Only a notebook that was actually made is a choice worth opening on
        // next time. `perform` says so, not `refusal`, which also carries the
        // stars' fault. The `didSet` on `options` is what writes it.
        guard let made else { return nil }
        options.newNotebook = NotebookSetup(geometry: geometry, paper: paper)
        return made
    }

    /// Creation without the sheet: the size and paper are the last made here,
    /// and letter blank before there is one, which is what the sheet itself
    /// opens on.
    @discardableResult
    package func createNotebookWithLastSetup(named name: String) async -> LibraryItem? {
        let setup = options.newNotebook ?? NotebookSetup(geometry: .letter, paper: .blank)
        return await createNotebook(named: name, geometry: setup.geometry, paper: setup.paper)
    }

    /// What a new item is called: the name asked for with its ends trimmed,
    /// or `fallback` when that leaves nothing (*A taken name becomes
    /// `Name (n)`*).
    private static func name(_ asked: String, or fallback: String) -> String {
        let trimmed = asked.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    package func recover(_ entry: TrashEntry) async {
        await perform { _ = try await library.store.recover(entry) }
    }

    package func deletePermanently(_ entry: TrashEntry) async {
        await perform { try await library.store.deletePermanently(entry) }
    }

    package func emptyTrash() async {
        await perform { try await library.store.emptyTrash() }
    }
}
