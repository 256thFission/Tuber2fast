import Foundation
import Testing
@testable import TuberNotes
@testable import TuberStore

/// The app carries this alias for the same collision `LibraryBrowserTests`
/// names: something up the import graph exposes a public `LibraryItem`, and
/// here the store's is the one meant.
private typealias LibraryItem = TuberStore.LibraryItem

/// A unique library root per test, removed when the test ends — the shape
/// `LibraryBrowserTests` uses, redeclared because its scratch is private to
/// that file.
private final class LibraryScratch {
    let root: URL
    let library: LibraryStore

    init(_ label: String) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tuberlibrary-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = LibraryStore(rootURL: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Select mode's batch mutations over a real store

@Suite("Library multi-select", .serialized)
@MainActor
struct LibraryMultiSelectTests {
    @Test("Batch trash: three selected items all land in the trash")
    func batchTrashSweepsSelection() async throws {
        let scratch = try LibraryScratch("batch-trash")
        _ = try await scratch.library.createDocumentDirectory(named: "A", in: "")
        _ = try await scratch.library.createDocumentDirectory(named: "B", in: "")
        _ = try await scratch.library.createFolder(
            named: "C", in: "", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createDocumentDirectory(named: "Keep", in: "")

        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        model.enterSelection()
        for name in ["A", "B", "C"] {
            let item = try #require(model.items.first { $0.name == name })
            model.toggleSelected(item)
        }
        #expect(model.selectedIDs.count == 3)

        await model.trashSelected(under: .default)

        // The batch exits select mode, the survivors remain, and every
        // trashed item is a trash entry.
        #expect(!model.isSelecting)
        #expect(model.selectedIDs.isEmpty)
        #expect(model.items.map(\.name) == ["Keep"])
        let trash = try await scratch.library.listTrash()
        #expect(Set(trash.map(\.name)) == ["A", "B", "C"])
    }

    @Test("Batch move with one collision: the suffix is surfaced, not silent")
    func batchMoveSurfacesCollisionSuffix() async throws {
        let scratch = try LibraryScratch("batch-move")
        _ = try await scratch.library.createDocumentDirectory(named: "Vocab", in: "")
        _ = try await scratch.library.createDocumentDirectory(named: "Notes", in: "")
        _ = try await scratch.library.createFolder(
            named: "Target", in: "", decoration: FolderDecoration()
        )
        // The collision waiting at the destination.
        _ = try await scratch.library.createDocumentDirectory(named: "Vocab", in: "Target")

        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        model.enterSelection()
        let vocab = try #require(model.items.first { $0.name == "Vocab" })
        let notes = try #require(model.items.first { $0.name == "Notes" })
        model.toggleSelected(vocab)
        model.toggleSelected(notes)

        await model.moveBatch(model.selectedItems(under: .default), toFolder: "Target")

        #expect(!model.isSelecting)
        let destination = try await scratch.library.listFolder("Target")
        #expect(Set(destination.items.map(\.name)) == ["Notes", "Vocab", "Vocab 2"])
        // The one adaptation is named; the clean move is not.
        let banner = try #require(model.mutationBanner)
        #expect(banner.contains("Vocab 2"))
        #expect(!banner.contains("Notes"))
    }

    @Test("Batch duplicate copies the documents and skips the folders, saying so")
    func batchDuplicateSkipsFolders() async throws {
        let scratch = try LibraryScratch("batch-duplicate")
        _ = try await scratch.library.createDocumentDirectory(named: "Doc", in: "")
        _ = try await scratch.library.createFolder(
            named: "Folder", in: "", decoration: FolderDecoration()
        )

        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        model.enterSelection()
        model.selectAllVisible(under: .default)
        #expect(model.selectedIDs.count == 2)

        await model.duplicateSelected(under: .default)

        // One copy, no folder copy — the folder is skipped, never trees.
        #expect(Set(model.items.map(\.name)) == ["Doc", "Doc 2", "Folder"])
        let banner = try #require(model.mutationBanner)
        #expect(banner.contains("skipped"))
    }

    @Test("Select All selects only what the active filter shows")
    func selectAllRespectsFilter() async throws {
        let scratch = try LibraryScratch("select-all-filter")
        _ = try await scratch.library.createDocumentDirectory(named: "Doc A", in: "")
        _ = try await scratch.library.createDocumentDirectory(named: "Doc B", in: "")
        _ = try await scratch.library.createFolder(
            named: "Folder", in: "", decoration: FolderDecoration()
        )

        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        model.enterSelection()
        model.filter = .documents
        model.selectAllVisible(under: .default)

        // The hidden folder is not swept into the selection.
        #expect(model.selectedIDs == ["Doc A.tubernotes", "Doc B.tubernotes"])
        #expect(model.allVisibleSelected(under: .default))

        // Widening the filter un-completes the selection: the folder is
        // visible again and unselected, so 'Select All' must reappear.
        model.filter = .all
        #expect(!model.allVisibleSelected(under: .default))
    }
}
