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

    let folderPath: String
    /// Exposed for the move picker's drill-down, which lists other folders
    /// through the same store; every mutation still lands through this model.
    let library: LibraryStore

    private(set) var state: ListingState = .loading
    /// One array, one comparator — folders and documents interleaved.
    private(set) var items: [LibraryItem] = []
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
