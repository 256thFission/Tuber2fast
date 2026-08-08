import Foundation
import PencilKit
import Testing
@testable import TuberCanvas
@testable import TuberNotes
@testable import TuberStore

/// The app carries this alias for the same collision: something up the import
/// graph exposes a public `LibraryItem`, and here the store's is the one meant.
private typealias LibraryItem = TuberStore.LibraryItem

/// A unique library root per test, removed when the test ends — the same
/// shape `TestScratch` gives a document, one level up.
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

// MARK: - The one comparator

@Suite("Library browser sorting")
struct LibrarySortingTests {
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

    @Test("Last Modified descending interleaves folders and documents")
    func lastModifiedInterleaves() {
        let sorted = FolderListingModel.sorted(
            [
                item("Old Doc", modified: 10),
                item("New Folder", folder: true, modified: 30),
                item("New Doc", modified: 20),
            ],
            by: .lastModified,
            ascending: false
        )
        // The folder lands between documents by its date alone: one array,
        // one comparator, no grouping outside the Type sort.
        #expect(sorted.map(\.name) == ["New Folder", "New Doc", "Old Doc"])
    }

    @Test("Name ascending is a plain interleaved name sort")
    func nameSortInterleaves() {
        let sorted = FolderListingModel.sorted(
            [item("cherry"), item("apple", folder: true), item("Banana")],
            by: .name,
            ascending: true
        )
        #expect(sorted.map(\.name) == ["apple", "Banana", "cherry"])
    }

    @Test("Type alone groups folders first")
    func typeSortGroupsFoldersFirst() {
        let sorted = FolderListingModel.sorted(
            [item("A Doc"), item("Z Folder", folder: true), item("B Doc")],
            by: .type,
            ascending: true
        )
        #expect(sorted.map(\.name) == ["Z Folder", "A Doc", "B Doc"])
    }

    @Test("Date Created respects direction; ties fall back to name")
    func dateCreatedAndTies() {
        let ascending = FolderListingModel.sorted(
            [item("B", created: 2), item("A", created: 1), item("C", created: 2)],
            by: .dateCreated,
            ascending: true
        )
        #expect(ascending.map(\.name) == ["A", "B", "C"])

        let descending = FolderListingModel.sorted(
            [item("B", created: 2), item("A", created: 1), item("C", created: 2)],
            by: .dateCreated,
            ascending: false
        )
        #expect(descending.map(\.name) == ["B", "C", "A"])
    }
}

// MARK: - The listing model over a real store

@Suite("Folder listing model", .serialized)
@MainActor
struct FolderListingModelTests {
    @Test("A successful empty listing is loaded-empty, never refused")
    func emptyIsLoadedNotRefused() async throws {
        let scratch = try LibraryScratch("empty")
        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        #expect(model.state == .loaded)
        #expect(model.items.isEmpty)
    }

    @Test("A folder that cannot be listed is refused, never shown empty")
    func missingFolderIsRefused() async throws {
        let scratch = try LibraryScratch("refused")
        let model = FolderListingModel(folderPath: "No Such Folder", library: scratch.library)
        await model.refresh()
        guard case .refused = model.state else {
            Issue.record("expected .refused for an unlistable folder, got \(model.state)")
            return
        }
        #expect(model.items.isEmpty)
    }

    @Test("Create, list, rename, and trash round-trip through the model")
    func mutationsRoundTrip() async throws {
        let scratch = try LibraryScratch("roundtrip")
        let model = FolderListingModel(folderPath: "", library: scratch.library)

        await model.createFolder(named: "Chinese", decoration: FolderDecoration(color: "#E74C3C"))
        _ = try await scratch.library.createDocumentDirectory(named: "Bayes Exam", in: "")
        await model.refresh()
        #expect(model.state == .loaded)
        #expect(Set(model.items.map(\.name)) == ["Chinese", "Bayes Exam"])

        let doc = try #require(model.items.first { $0.name == "Bayes Exam" })
        let inlineError = await model.rename(doc, to: "Bayes Final")
        #expect(inlineError == nil)
        #expect(model.items.contains { $0.name == "Bayes Final" })
        #expect(!model.items.contains { $0.name == "Bayes Exam" })

        let renamed = try #require(model.items.first { $0.name == "Bayes Final" })
        await model.trash(renamed)
        #expect(model.items.map(\.name) == ["Chinese"])
        #expect(try await scratch.library.listTrash().count == 1)
    }

    @Test("The name gate's refusal surfaces inline, and the item keeps its name")
    func invalidRenameSurfacesInline() async throws {
        let scratch = try LibraryScratch("invalidname")
        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.createFolder(named: "Notes", decoration: FolderDecoration())
        let folder = try #require(model.items.first)

        let reason = await model.rename(folder, to: "a/b")
        #expect(reason != nil)
        #expect(model.items.map(\.name) == ["Notes"])
    }

    @Test("Decoration edits land and re-list")
    func decorationEditsLand() async throws {
        let scratch = try LibraryScratch("decoration")
        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.createFolder(named: "HSK 5", decoration: FolderDecoration())
        let folder = try #require(model.items.first)

        await model.setDecoration(
            FolderDecoration(color: "#2E7D32", icon: "star.fill"),
            for: folder
        )
        guard case .folder(let decoration) = try #require(model.items.first).kind else {
            Issue.record("expected a folder")
            return
        }
        #expect(decoration.color == "#2E7D32")
        #expect(decoration.icon == "star.fill")
    }
}

// MARK: - The coordinator's open/close machine

@Suite("Library coordinator", .serialized)
@MainActor
struct LibraryCoordinatorTests {
    @Test("New notebook: the store reserves the directory, the session creates, close releases")
    func newNotebookOpensAndClosesClean() async throws {
        let scratch = try LibraryScratch("newnotebook")
        let coordinator = LibraryCoordinator(library: scratch.library)

        try await coordinator.createAndOpenNotebook(named: "Field Notes", in: "")
        let open = try #require(coordinator.openDocument)
        #expect(open.itemPath == "Field Notes.tubernotes")
        #expect(!coordinator.canOpenDocuments)

        await open.lifecycle.session.start()
        #expect(open.lifecycle.session.phase == .ready)

        let generationBefore = coordinator.libraryGeneration
        await coordinator.closeOpenDocument()
        #expect(coordinator.openDocument == nil)
        #expect(coordinator.draining == nil)
        #expect(coordinator.canOpenDocuments)
        #expect(coordinator.libraryGeneration > generationBefore)

        // The notebook is durable: a fresh session opens it as existing.
        coordinator.openDocument(at: "Field Notes.tubernotes", named: "Field Notes")
        let reopened = try #require(coordinator.openDocument)
        await reopened.lifecycle.session.start()
        #expect(reopened.lifecycle.session.phase == .ready)
        await coordinator.closeOpenDocument()
    }

    @Test("A dirty close retains the session, blocks opens, and Retry drains it")
    func dirtyCloseRetainsBlocksAndDrains() async throws {
        let libraryScratch = try LibraryScratch("dirtyclose")
        let coordinator = LibraryCoordinator(library: libraryScratch.library)

        // A session over its own scratch, dirtied for real and then denied
        // its save — the same broken-destination trick the close suite uses.
        let scratch = try TestScratch("coordinator-dirty")
        let session = EditorSession(store: scratch.store, debounce: .seconds(30))
        await session.start()
        try await canvas(of: session).drawing = strokeAcrossPage()
        try FileManager.default.removeItem(at: scratch.root)
        try Data().write(to: scratch.root)

        coordinator.installOpenDocumentForTesting(
            lifecycle: EditorLifecycle(session: session),
            itemPath: "Broken.tubernotes",
            displayName: "Broken"
        )
        await coordinator.closeOpenDocument()

        #expect(coordinator.openDocument == nil)
        #expect(coordinator.draining != nil)
        #expect(!coordinator.canOpenDocuments)

        // Opening anything while the drain holds is refused.
        _ = try await libraryScratch.library.createDocumentDirectory(named: "Other", in: "")
        coordinator.openDocument(at: "Other.tubernotes", named: "Other")
        #expect(coordinator.openDocument == nil)

        // Heal the destination; Retry is close() again, which re-checks
        // dirtiness after the session's own machinery drains.
        try FileManager.default.removeItem(at: scratch.root)
        try FileManager.default.createDirectory(at: scratch.root, withIntermediateDirectories: true)
        try scratch.createDirectories()
        try await waitUntil("the drained session is released") {
            await coordinator.retryDrain()
            return coordinator.draining == nil
        }
        #expect(coordinator.canOpenDocuments)

        // And the block lifts for real: the refused open now succeeds.
        coordinator.openDocument(at: "Other.tubernotes", named: "Other")
        #expect(coordinator.openDocument != nil)
        await coordinator.closeOpenDocument()
    }

    // MARK: - Fixtures

    private func waitUntil(
        _ what: String,
        within timeout: Duration = .seconds(10),
        _ condition: () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record(Comment(rawValue: "timed out waiting for: \(what)"))
    }

    /// The hosting step the close suite takes, for the same reason: the paged
    /// runtime builds canvases during layout.
    private func canvas(of session: EditorSession) async throws -> PKCanvasView {
        let root = session.pages.view!
        if root.frame.isEmpty {
            root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        }
        root.layoutIfNeeded()
        for _ in 0..<200 {
            if let page = session.currentCanvas { return page.canvasView }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("the paged runtime built no canvas for the current page")
    }

    private func strokeAcrossPage() -> PKDrawing {
        let locations = [
            CGPoint(x: 100, y: 150),
            CGPoint(x: 300, y: 400),
            CGPoint(x: 500, y: 650),
        ]
        let points = locations.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: Double(index) * 0.01,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }
}
