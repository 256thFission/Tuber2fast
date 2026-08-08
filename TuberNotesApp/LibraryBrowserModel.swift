import Foundation
import Observation
import TuberStore

/// One folder's listing as the browser shows it: the store's last answer,
/// sorted, plus the failure and degradation surfaces the proposal names.
///
/// The browser renders snapshots and sends intentions (`02-proposal.md` §2):
/// every mutation here is an async store call followed by a re-list — no
/// optimistic mutation, because the file system is the truth and the UI shows
/// what the store last proved.
@MainActor
@Observable
final class FolderListingModel {
    /// Refused is distinct from empty by design (`03-review.md` M-E): the
    /// designed empty state renders only on a successful empty listing.
    enum ListingState: Equatable {
        case loading
        case refused(String)
        case loaded
    }

    /// The toolbar's funnel chip: All / Documents / Folders (spec §7.2).
    /// Session-scoped by design — GoodNotes evidence on filter persistence
    /// is absent ("Filter persistence: UNKNOWN"), so nothing is written.
    enum ItemFilter: String, CaseIterable {
        case all, documents, folders
    }

    /// What the model lists: one folder's contents, or the flat cross-parent
    /// favorites collection. Every mutation resolves against the item's own
    /// full relative path (`item.id`), so the same mutation set works from
    /// either source — a rename from Favorites lands in the item's real
    /// parent, not in some "current folder".
    enum Source: Equatable {
        case folder(String)
        case favorites
    }

    let source: Source
    /// The folder this model lists — `""` for the root and for Favorites,
    /// which has no folder of its own (nothing is created there).
    var folderPath: String {
        if case .folder(let path) = source { return path }
        return ""
    }
    /// Exposed for the move picker's drill-down, which lists other folders
    /// through the same store; every mutation still lands through this model.
    let library: LibraryStore

    private(set) var state: ListingState = .loading
    /// One array, one comparator — folders and documents interleaved.
    private(set) var items: [LibraryItem] = []
    /// The funnel chip's choice, applied in memory over `items`.
    var filter: ItemFilter = .all
    /// The title search's live query. The model is built per folder view, so
    /// a folder push starts a fresh model and the query resets structurally.
    var searchText: String = ""
    /// The listing's own notices — corrupt sidecars set aside, foreign files
    /// ignored — surfaced in one non-modal banner.
    private(set) var degradations: [String] = []
    /// A mutation that failed for a reason the popover cannot show inline.
    var mutationBanner: String?

    init(folderPath: String, library: LibraryStore) {
        self.source = .folder(folderPath)
        self.library = library
    }

    /// The Favorites collection over the same model: `listFavorites` feeds
    /// `items`, and every mutation already resolves against `item.id`.
    init(favoritesIn library: LibraryStore) {
        self.source = .favorites
        self.library = library
    }

    var displayTitle: String {
        switch source {
        case .favorites:
            return "Favorites"
        case .folder(let path):
            return path.isEmpty
                ? "Documents"
                : path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    func refresh() async {
        do {
            let prefs = await library.prefs()
            switch source {
            case .folder(let path):
                let listing = try await library.listFolder(path)
                items = Self.sorted(listing.items, by: prefs.sortKey, ascending: prefs.ascending)
                degradations = listing.degradations
            case .favorites:
                let favorites = try await library.listFavorites()
                items = Self.sorted(favorites, by: prefs.sortKey, ascending: prefs.ascending)
                degradations = []
            }
            state = .loaded
        } catch {
            state = .refused(Self.describe(error))
        }
    }

    // MARK: - What the pane shows

    /// The listing as the pane renders it: filtered, searched, then sorted
    /// under the prefs handed in at render time — so a sort changed anywhere
    /// in the stack re-orders every visible folder view, including ones the
    /// navigation stack kept alive across a pop.
    ///
    /// The search filters **this folder's in-memory listing only** — no
    /// recursion, deliberately: a whole-tree title search would walk the tree
    /// the design promises not to walk (`03-review.md` M-J; recursive search
    /// is a later argument, not a smaller loop here).
    func displayed(under prefs: LibraryPrefs) -> [LibraryItem] {
        var visible = items
        switch filter {
        case .all:
            break
        case .documents:
            visible = visible.filter { !Self.isFolder($0) }
        case .folders:
            visible = visible.filter { Self.isFolder($0) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            visible = visible.filter {
                $0.name.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
        return Self.sorted(visible, by: prefs.sortKey, ascending: prefs.ascending)
    }

    // MARK: - The one comparator

    /// Folders and documents interleave under every key except Type, which
    /// alone groups folders first (spec §7.1, fidelity commitment UX-1).
    /// Name is the tie-break everywhere so equal dates cannot shuffle
    /// between refreshes.
    nonisolated static func sorted(
        _ items: [LibraryItem],
        by key: LibrarySortKey,
        ascending: Bool
    ) -> [LibraryItem] {
        items.sorted { a, b in
            switch key {
            case .lastModified:
                if a.modifiedAt != b.modifiedAt {
                    return ascending ? a.modifiedAt < b.modifiedAt : a.modifiedAt > b.modifiedAt
                }
            case .dateCreated:
                if a.createdAt != b.createdAt {
                    return ascending ? a.createdAt < b.createdAt : a.createdAt > b.createdAt
                }
            case .name:
                let compared = a.name.localizedStandardCompare(b.name)
                if compared != .orderedSame {
                    return ascending
                        ? compared == .orderedAscending
                        : compared == .orderedDescending
                }
            case .type:
                // Folders first regardless of direction: the grouping is what
                // the Type sort *is*; direction orders names within a group.
                if isFolder(a) != isFolder(b) { return isFolder(a) }
                let compared = a.name.localizedStandardCompare(b.name)
                if compared != .orderedSame {
                    return ascending
                        ? compared == .orderedAscending
                        : compared == .orderedDescending
                }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private nonisolated static func isFolder(_ item: LibraryItem) -> Bool {
        if case .folder = item.kind { return true }
        return false
    }

    // MARK: - Multi-select

    /// Select mode (spec §6.2, UX-10). The selection lives here rather than
    /// in the view so the batch mutations resolve against the same snapshots
    /// every single-item mutation does — ids, not indices, because a refresh
    /// mid-selection may reorder or drop items and a stale id at worst names
    /// nothing.
    private(set) var isSelecting = false
    private(set) var selectedIDs: Set<String> = []

    func enterSelection() {
        isSelecting = true
        selectedIDs = []
    }

    /// Done. Exits and clears — a re-entry always starts empty.
    func exitSelection() {
        isSelecting = false
        selectedIDs = []
    }

    func toggleSelected(_ item: LibraryItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    /// Select All selects **the visible listing** — what the filter and
    /// search left on screen — not the folder's full contents; selecting
    /// hidden items would trash what the user cannot see. (Platform
    /// convention, INFERRED — the spec images only the button.)
    func selectAllVisible(under prefs: LibraryPrefs) {
        selectedIDs = Set(displayed(under: prefs).map(\.id))
    }

    func deselectAll() {
        selectedIDs = []
    }

    /// True when everything visible is selected — the moment 'Select All'
    /// reads 'Deselect All'.
    func allVisibleSelected(under prefs: LibraryPrefs) -> Bool {
        let visible = displayed(under: prefs)
        return !visible.isEmpty && visible.allSatisfy { selectedIDs.contains($0.id) }
    }

    /// The selected items as snapshots, resolved against the current listing
    /// in its displayed order — an id whose item vanished under a refresh
    /// resolves to nothing rather than to a guess.
    func selectedItems(under prefs: LibraryPrefs) -> [LibraryItem] {
        displayed(under: prefs).filter { selectedIDs.contains($0.id) }
    }

    // MARK: - Batch mutations

    /// Trashes every selected item. Same stance as the single trash: no
    /// confirmation, recoverable. Failures are counted into one banner —
    /// a three-item batch with one refusal still trashes the other two.
    func trashSelected(under prefs: LibraryPrefs) async {
        var failures: [String] = []
        for item in selectedItems(under: prefs) {
            do {
                try await library.trashItem(at: item.id)
            } catch {
                failures.append(Self.describe(error))
            }
        }
        if let first = failures.first {
            mutationBanner = failures.count == 1
                ? first
                : "\(first) (+\(failures.count - 1) more)"
        }
        exitSelection()
        await refresh()
    }

    /// Duplicates the selected **documents**; folders are skipped and the
    /// banner says how many — the same "no folder duplicate" stance as the
    /// chevron menu (UX-9), surfaced instead of silent because a batch hides
    /// what a menu's absence showed.
    func duplicateSelected(under prefs: LibraryPrefs) async {
        var copies = 0
        var skippedFolders = 0
        var failures: [String] = []
        for item in selectedItems(under: prefs) {
            guard case .document = item.kind else {
                skippedFolders += 1
                continue
            }
            do {
                _ = try await library.duplicateDocument(at: item.id)
                copies += 1
            } catch {
                failures.append(Self.describe(error))
            }
        }
        var parts: [String] = []
        if copies > 0 {
            parts.append("Duplicated \(copies) document\(copies == 1 ? "" : "s").")
        }
        if skippedFolders > 0 {
            parts.append(
                "\(skippedFolders) folder\(skippedFolders == 1 ? " was" : "s were") skipped — folders do not duplicate."
            )
        }
        parts.append(contentsOf: failures)
        if !parts.isEmpty { mutationBanner = parts.joined(separator: " ") }
        exitSelection()
        await refresh()
    }

    /// Moves a batch to one destination. Collisions are the store's suffix,
    /// per item, and the banner names every adaptation at once — batch-style,
    /// where the single move names its one.
    func moveBatch(_ batch: [LibraryItem], toFolder destination: String) async {
        var renamed: [String] = []
        var failures: [String] = []
        for item in batch {
            do {
                let moved = try await library.moveItem(at: item.id, toFolder: destination)
                if moved.name != item.name {
                    renamed.append("\u{201C}\(moved.name)\u{201D}")
                }
            } catch {
                failures.append(Self.describe(error))
            }
        }
        var parts: [String] = []
        if !renamed.isEmpty {
            parts.append("Renamed to avoid collisions: \(renamed.joined(separator: ", ")).")
        }
        parts.append(contentsOf: failures)
        if !parts.isEmpty { mutationBanner = parts.joined(separator: " ") }
        exitSelection()
        await refresh()
    }

    // MARK: - Mutations

    /// Returns the inline reason when the name gate refused — the popover
    /// shows it next to the field — and banners everything else.
    func rename(_ item: LibraryItem, to newName: String) async -> String? {
        do {
            _ = try await library.renameItem(at: item.id, to: newName)
            await refresh()
            return nil
        } catch let error as LibraryError {
            if case .invalidName(let reason) = error { return reason }
            mutationBanner = Self.describe(error)
            await refresh()
            return nil
        } catch {
            mutationBanner = Self.describe(error)
            await refresh()
            return nil
        }
    }

    /// No confirmation, deliberately: trash is recoverable, the platform
    /// convention confirms only permanent deletes (those live with the Trash
    /// screen's lane).
    func trash(_ item: LibraryItem) async {
        do {
            try await library.trashItem(at: item.id)
        } catch {
            mutationBanner = Self.describe(error)
        }
        await refresh()
    }

    /// The collision suffix is the store's job (L3's one sanctioned
    /// adaptation); when it changed the name, the adaptation is surfaced in
    /// the banner rather than passing silently.
    func move(_ item: LibraryItem, toFolder destination: String) async {
        do {
            let moved = try await library.moveItem(at: item.id, toFolder: destination)
            if moved.name != item.name {
                mutationBanner = "\(item.name) was moved as \u{201C}\(moved.name)\u{201D}."
            }
        } catch {
            mutationBanner = Self.describe(error)
        }
        await refresh()
    }

    /// The star's tap. The flag flips from the snapshot the cell rendered —
    /// one writer, so a stale snapshot can at worst repeat the state the
    /// store already has, never invent a third.
    func toggleFavorite(_ item: LibraryItem) async {
        do {
            try await library.setFavorite(!item.isFavorite, at: item.id)
        } catch {
            mutationBanner = Self.describe(error)
        }
        await refresh()
    }

    /// Documents only — the observed folder menu has no Duplicate (spec
    /// §6.5, `03-review.md` UX-9), and the store's precondition agrees.
    /// The suffixed copy name is surfaced, not silent (M-C's license covers
    /// the suffix; the banner covers the adaptation).
    func duplicate(_ item: LibraryItem) async {
        guard case .document = item.kind else { return }
        do {
            let copy = try await library.duplicateDocument(at: item.id)
            mutationBanner = "Duplicated as \u{201C}\(copy.name)\u{201D}."
        } catch {
            mutationBanner = Self.describe(error)
        }
        await refresh()
    }

    func createFolder(named name: String, decoration: FolderDecoration) async {
        do {
            _ = try await library.createFolder(
                named: name,
                in: folderPath,
                decoration: decoration
            )
        } catch {
            mutationBanner = Self.describe(error)
        }
        await refresh()
    }

    func setDecoration(_ decoration: FolderDecoration, for item: LibraryItem) async {
        do {
            try await library.setDecoration(decoration, forFolderAt: item.id)
        } catch {
            mutationBanner = Self.describe(error)
        }
        await refresh()
    }

    // MARK: - Failure copy

    /// PROVISIONAL WORDING: the failure-taxonomy work owns the sentences;
    /// what is decided here is only that each refusal names its cause.
    nonisolated static func describe(_ error: Error) -> String {
        guard let library = error as? LibraryError else { return String(describing: error) }
        switch library {
        case .invalidName(let reason):
            return "That name will not work: \(reason)."
        case .itemNotFound(let path):
            return "\(path) no longer exists."
        case .notAFolder(let path):
            return "\(path) is not a folder."
        case .enumerationFailed(let detail):
            return "This folder could not be read. \(detail)"
        case .destinationInsideSource:
            return "A folder cannot be moved into itself."
        }
    }
}
