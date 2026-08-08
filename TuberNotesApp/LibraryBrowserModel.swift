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

    let folderPath: String
    private let library: LibraryStore

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
        self.folderPath = folderPath
        self.library = library
    }

    var displayTitle: String {
        folderPath.isEmpty
            ? "Documents"
            : folderPath.split(separator: "/").last.map(String.init) ?? folderPath
    }

    func refresh() async {
        do {
            let listing = try await library.listFolder(folderPath)
            let prefs = await library.prefs()
            items = Self.sorted(listing.items, by: prefs.sortKey, ascending: prefs.ascending)
            degradations = listing.degradations
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
