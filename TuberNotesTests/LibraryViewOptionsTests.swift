import Foundation
import Testing
@testable import TuberNotes
@testable import TuberStore

/// The app carries this alias for the same collision the browser suite
/// names: something up the import graph exposes a public `LibraryItem`,
/// and here the store's is the one meant.
private typealias LibraryItem = TuberStore.LibraryItem

/// A unique library root per test, removed when the test ends — the same
/// shape `LibraryBrowserTests` uses, duplicated here because it is three
/// lines and a shared fixture file would couple the suites.
private final class ViewOptionsScratch {
    let root: URL
    let library: LibraryStore

    init(_ label: String) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tuberviewoptions-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = LibraryStore(rootURL: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private func item(
    _ name: String,
    folder: Bool = false,
    created: TimeInterval = 0,
    modified: TimeInterval = 0
) -> LibraryItem {
    LibraryItem(
        id: folder ? name : "\(name).tubernotes",
        name: name,
        kind: folder ? .folder(FolderDecoration()) : .document,
        createdAt: Date(timeIntervalSinceReferenceDate: created),
        modifiedAt: Date(timeIntervalSinceReferenceDate: modified),
        isFavorite: false,
        decorationDegraded: false
    )
}

// MARK: - The comparator under every key and direction

@Suite("View options comparator")
struct ViewOptionsComparatorTests {
    /// One mixed fixture reused across keys: two documents and two folders
    /// whose name, created, and modified orders all disagree, so a wrong key
    /// cannot accidentally produce the right order.
    private var fixture: [LibraryItem] {
        [
            item("Delta", created: 4, modified: 1),
            item("alpha", folder: true, created: 3, modified: 2),
            item("Charlie", created: 1, modified: 4),
            item("bravo", folder: true, created: 2, modified: 3),
        ]
    }

    @Test("Date Created orders by creation in both directions, interleaved")
    func dateCreatedBothDirections() {
        let ascending = FolderListingModel.sorted(fixture, by: .dateCreated, ascending: true)
        #expect(ascending.map(\.name) == ["Charlie", "bravo", "alpha", "Delta"])

        let descending = FolderListingModel.sorted(fixture, by: .dateCreated, ascending: false)
        #expect(descending.map(\.name) == ["Delta", "alpha", "bravo", "Charlie"])
    }

    @Test("Last Modified orders by modification in both directions, interleaved")
    func lastModifiedBothDirections() {
        let ascending = FolderListingModel.sorted(fixture, by: .lastModified, ascending: true)
        #expect(ascending.map(\.name) == ["Delta", "alpha", "bravo", "Charlie"])

        let descending = FolderListingModel.sorted(fixture, by: .lastModified, ascending: false)
        #expect(descending.map(\.name) == ["Charlie", "bravo", "alpha", "Delta"])
    }

    @Test("Name is localizedStandardCompare in both directions, interleaved")
    func nameBothDirections() {
        let ascending = FolderListingModel.sorted(fixture, by: .name, ascending: true)
        #expect(ascending.map(\.name) == ["alpha", "bravo", "Charlie", "Delta"])

        let descending = FolderListingModel.sorted(fixture, by: .name, ascending: false)
        #expect(descending.map(\.name) == ["Delta", "Charlie", "bravo", "alpha"])
    }

    @Test("Type groups folders first under both directions; direction orders names within groups")
    func typeBothDirections() {
        let ascending = FolderListingModel.sorted(fixture, by: .type, ascending: true)
        #expect(ascending.map(\.name) == ["alpha", "bravo", "Charlie", "Delta"])

        // Folders stay first even descending: the grouping is what the Type
        // sort *is*; only the names within each group reverse.
        let descending = FolderListingModel.sorted(fixture, by: .type, ascending: false)
        #expect(descending.map(\.name) == ["bravo", "alpha", "Delta", "Charlie"])
    }

    @Test("Name digits compare numerically, not lexically")
    func nameIsStandardCompare() {
        let sorted = FolderListingModel.sorted(
            [item("Note 10"), item("Note 2"), item("Note 1")],
            by: .name,
            ascending: true
        )
        #expect(sorted.map(\.name) == ["Note 1", "Note 2", "Note 10"])
    }
}

// MARK: - Filter and search over a real store

@Suite("Filter and search", .serialized)
@MainActor
struct LibraryFilterSearchTests {
    @Test("The filter narrows to documents or folders and All restores")
    func filterNarrows() async throws {
        let scratch = try ViewOptionsScratch("filter")
        _ = try await scratch.library.createFolder(named: "Chinese", in: "", decoration: FolderDecoration())
        _ = try await scratch.library.createDocumentDirectory(named: "Bayes Exam", in: "")

        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        let prefs = LibraryPrefs.default

        model.filter = .documents
        #expect(model.displayed(under: prefs).map(\.name) == ["Bayes Exam"])

        model.filter = .folders
        #expect(model.displayed(under: prefs).map(\.name) == ["Chinese"])

        model.filter = .all
        #expect(Set(model.displayed(under: prefs).map(\.name)) == ["Chinese", "Bayes Exam"])
    }

    @Test("Search matches case- and diacritic-insensitively on names")
    func searchIsInsensitive() async throws {
        let scratch = try ViewOptionsScratch("search")
        _ = try await scratch.library.createDocumentDirectory(named: "Résumé Notes", in: "")
        _ = try await scratch.library.createDocumentDirectory(named: "Bayes Exam", in: "")

        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        let prefs = LibraryPrefs.default

        model.searchText = "resume"
        #expect(model.displayed(under: prefs).map(\.name) == ["Résumé Notes"])

        model.searchText = "ÉXAM"
        #expect(model.displayed(under: prefs).map(\.name) == ["Bayes Exam"])

        model.searchText = "nothing like this"
        #expect(model.displayed(under: prefs).isEmpty)

        // Whitespace-only is no query at all.
        model.searchText = "   "
        #expect(model.displayed(under: prefs).count == 2)
    }

    @Test("Search is scoped to one folder's model and resets on folder change")
    func searchResetsOnFolderChange() async throws {
        let scratch = try ViewOptionsScratch("searchscope")
        _ = try await scratch.library.createFolder(named: "Chinese", in: "", decoration: FolderDecoration())
        _ = try await scratch.library.createDocumentDirectory(named: "Vocab", in: "Chinese")

        let rootModel = FolderListingModel(folderPath: "", library: scratch.library)
        await rootModel.refresh()
        rootModel.searchText = "vocab"
        // No recursion: the query filters this folder's listing only, and
        // the child document is not reachable from the root's model.
        #expect(rootModel.displayed(under: .default).isEmpty)

        // A folder push builds a fresh model (the view constructs one per
        // folder), so the query resets structurally rather than by handoff.
        let childModel = FolderListingModel(folderPath: "Chinese", library: scratch.library)
        await childModel.refresh()
        #expect(childModel.searchText.isEmpty)
        #expect(childModel.displayed(under: .default).map(\.name) == ["Vocab"])
    }
}

// MARK: - Prefs persistence through the view-options model

@Suite("View options prefs", .serialized)
@MainActor
struct LibraryViewOptionsPrefsTests {
    @Test("Re-tapping the active key toggles direction; a new key takes its default")
    func sortKeyTapSemantics() async throws {
        let scratch = try ViewOptionsScratch("taps")
        let options = LibraryViewOptionsModel(library: scratch.library)
        await options.load()
        #expect(options.prefs == .default)

        // Re-tap the default active key: direction flips, key holds.
        await options.tapSortKey(.lastModified)
        #expect(options.prefs.sortKey == .lastModified)
        #expect(options.prefs.ascending)

        // A new key starts at its conventional default, not the old direction.
        await options.tapSortKey(.name)
        #expect(options.prefs.sortKey == .name)
        #expect(options.prefs.ascending)
        await options.tapSortKey(.dateCreated)
        #expect(options.prefs.sortKey == .dateCreated)
        #expect(!options.prefs.ascending)
    }

    @Test("View mode and sort persist across a fresh store over the same root")
    func prefsPersistAcrossStores() async throws {
        let scratch = try ViewOptionsScratch("persist")
        let options = LibraryViewOptionsModel(library: scratch.library)
        await options.load()

        await options.setViewMode(.list)
        await options.tapSortKey(.type)

        // A fresh store over the same root reads what the first one wrote —
        // the preference is global and durable, not a session artifact.
        let reopened = LibraryStore(rootURL: scratch.root)
        let prefs = await reopened.prefs()
        #expect(prefs.viewMode == .list)
        #expect(prefs.sortKey == .type)
        #expect(prefs.ascending == LibraryViewOptionsModel.defaultAscending(for: .type))
    }
}
