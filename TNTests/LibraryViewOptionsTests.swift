import Foundation
import Testing
@testable import TNLibrary
@testable import TNModel

/// Options in memory. The production conformer is the app's, over
/// `UserDefaults`; a test that wrote one would leave the machine holding
/// state the next run reads back.
final class MemoryViewOptionsStore: LibraryViewOptionsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var options: LibraryViewOptions?

    init(_ options: LibraryViewOptions? = nil) { self.options = options }

    func load() -> LibraryViewOptions? { lock.withLock { options } }
    func save(_ options: LibraryViewOptions) { lock.withLock { self.options = options } }

    var stored: LibraryViewOptions? { lock.withLock { options } }
}

func listingItem(_ name: String, kind: ItemKind = .notebook, created: Double = 0, modified: Double = 0) -> LibraryItem {
    LibraryItem(
        id: name, name: name, kind: kind,
        notebookID: kind == .notebook ? NotebookID() : nil,
        folderID: kind == .folder ? FolderID() : nil,
        decoration: kind == .folder ? .plain : nil,
        createdAt: Date(timeIntervalSince1970: created),
        modifiedAt: Date(timeIntervalSince1970: modified)
    )
}

@Suite("Library view options: the sort, the flip, and the preference")
@MainActor
struct LibraryViewOptionsTests {
    private let folder = listingItem("Beta", kind: .folder, created: 200, modified: 100)
    private let alpha = listingItem("Alpha", created: 100, modified: 300)
    private let gamma = listingItem("Gamma", created: 300, modified: 200)

    private func sorted(_ key: LibrarySortKey, ascending: Bool) -> [String] {
        LibraryViewOptions(sortKey: key, ascending: ascending)
            .sorted([gamma, folder, alpha])
            .map(\.name)
    }

    @Test("Each key runs both ways, folders interleaved, except .type which groups them first")
    func everyKeyBothWays() {
        #expect(sorted(.dateCreated, ascending: true) == ["Alpha", "Beta", "Gamma"])
        #expect(sorted(.dateCreated, ascending: false) == ["Gamma", "Beta", "Alpha"])
        #expect(sorted(.lastModified, ascending: true) == ["Beta", "Gamma", "Alpha"])
        #expect(sorted(.lastModified, ascending: false) == ["Alpha", "Gamma", "Beta"])
        #expect(sorted(.name, ascending: true) == ["Alpha", "Beta", "Gamma"])
        #expect(sorted(.name, ascending: false) == ["Gamma", "Beta", "Alpha"])
        #expect(sorted(.type, ascending: true) == ["Beta", "Alpha", "Gamma"])
        #expect(sorted(.type, ascending: false) == ["Beta", "Gamma", "Alpha"])
    }

    @Test("Names order the way a person reads numbers")
    func namesUseLocalizedStandardCompare() {
        let items = [listingItem("Note 10"), listingItem("Note 2"), listingItem("Note 1")]
        let options = LibraryViewOptions(sortKey: .name, ascending: true)
        #expect(options.sorted(items).map(\.name) == ["Note 1", "Note 2", "Note 10"])
    }

    @Test("Tapping the active key flips it; tapping another takes that key's default")
    func tapping() {
        let options = LibraryViewOptions(sortKey: .lastModified, ascending: false)
        let flipped = options.tapping(.lastModified)
        #expect(flipped.sortKey == .lastModified)
        #expect(flipped.ascending)
        #expect(flipped.tapping(.lastModified).ascending == false)

        let byName = options.tapping(.name)
        #expect(byName.sortKey == .name)
        #expect(byName.ascending)
        #expect(options.tapping(.dateCreated).ascending == false)
    }

    @Test("Options round-trip through the store, and the browser saves every change")
    func optionsAreAPreference() async throws {
        let scratch = try Scratch("browser-options")
        defer { withExtendedLifetime(scratch) {} }
        let library = Library(store: try LibraryStore(base: scratch.root))
        let store = MemoryViewOptionsStore()

        let browser = LibraryBrowser(library: library, optionsStore: store)
        #expect(browser.options == LibraryViewOptions())
        #expect(store.stored == nil)

        browser.options = browser.options.tapping(.name)
        #expect(store.stored == LibraryViewOptions(sortKey: .name, ascending: true))
        browser.options.layout = .list
        #expect(store.stored?.layout == .list)

        // The last new-notebook choice rides the same record.
        let setup = NotebookSetup(geometry: PageGeometry(width: 595, height: 842), paper: .lined)
        browser.options.newNotebook = setup
        #expect(store.stored?.newNotebook == setup)

        let reopened = LibraryBrowser(library: library, optionsStore: store)
        #expect(reopened.options == LibraryViewOptions(layout: .list, sortKey: .name, ascending: true, newNotebook: setup))
    }
}
