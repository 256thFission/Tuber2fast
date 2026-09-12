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
    /// The last refused intention, one line. Cleared by the next that lands.
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
        }.filter { item in
            searchText.isEmpty || item.name.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return options.sorted(narrowed)
    }

    package func isFavorite(_ item: LibraryItem) -> Bool {
        item.identity.map(favorites.contains) ?? false
    }

    // MARK: Reading

    package func reload() async {
        do {
            favorites = try await library.store.favorites()
            switch section {
            // A search reads the whole tree from the root, wherever the
            // reader is standing: searching is looking for something you
            // cannot see, and the folder you are in is the part you can.
            case .documents where !searchText.isEmpty:
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
            listing = .refused(error.description)
        }
    }

    package func enter(_ item: LibraryItem) {
        guard item.kind == .folder else { return }
        section = .documents
        folder = item.relativePath
        leaveListing()
    }

    package func back() {
        guard let slash = folder.lastIndex(of: "/") else { folder = ""; leaveListing(); return }
        folder = String(folder[..<slash])
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
    /// folders and everything inside them.
    package func destinations(in parent: String, excluding moved: Set<String>) async -> [LibraryItem] {
        let folders = (try? await library.store.listFolders(in: parent)) ?? []
        return folders.filter { candidate in
            !moved.contains { $0 == candidate.relativePath || candidate.relativePath.hasPrefix($0 + "/") }
        }
    }

    // MARK: Covers

    package func cover(of item: LibraryItem) async -> CGImage? {
        await library.cover(of: item)
    }

    // MARK: Intentions

    /// Untyped because a closure does not infer a typed throw; every call
    /// inside throws `LibraryError`, and the fallback names anything else.
    private func perform(_ work: () async throws -> Void) async {
        do {
            try await work()
            refusal = nil
        } catch let error as LibraryError {
            refusal = error.description
        } catch {
            refusal = "\(error)"
        }
        await reload()
    }

    package func rename(_ item: LibraryItem, to name: String) async {
        await perform { _ = try await library.rename(at: item.relativePath, to: name) }
    }

    package func move(_ paths: Set<String>, toFolder destination: String) async {
        await perform {
            for path in paths.sorted() { _ = try await library.move(at: path, toFolder: destination) }
        }
        selection = nil
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

    package func createFolder(named name: String) async {
        await perform { _ = try await library.store.createFolder(named: name, in: folder) }
    }

    package func createNotebook(named name: String, geometry: PageGeometry, paper: DrawnPaper) async {
        await perform { _ = try await library.store.createNotebook(named: name, in: folder, geometry: geometry, paper: paper) }
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
