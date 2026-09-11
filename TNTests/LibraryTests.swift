import Foundation
import PencilKit
import Testing
@testable import TNEditor
@testable import TNFormat
@testable import TNLibrary
@testable import TNModel
@testable import TNNotebook

@Suite("Library: the tree, the trash, the ledger")
@MainActor
struct LibraryTests {
    func makeLibrary(_ name: String) throws -> (Scratch, Library) {
        let scratch = try Scratch(name)
        let store = try LibraryStore(base: scratch.root)
        return (scratch, Library(store: store))
    }

    @Test("Create, list, rename, move: the tree round-trips and names validate")
    func tree() async throws {
        let (scratch, library) = try makeLibrary("lib-tree")
        defer { withExtendedLifetime(scratch) {} }
        let folder = try await library.store.createFolder(named: "Math", in: "")
        let notebook = try await library.store.createNotebook(named: "Algebra", in: "Math")
        #expect(notebook.relativePath == "Math/Algebra.tubernotes")
        #expect(try await library.store.list(folder: "Math").map(\.name) == ["Algebra"])
        let renamed = try await library.rename(at: notebook.relativePath, to: "Algebra II")
        #expect(renamed.relativePath == "Math/Algebra II.tubernotes")
        let moved = try await library.move(at: renamed.relativePath, toFolder: "")
        #expect(moved.relativePath == "Algebra II.tubernotes")
        #expect(try await library.store.list(folder: "").map(\.name) == ["Algebra II", "Math"])
        await #expect(throws: LibraryError.invalidName("../x")) { try await library.store.createFolder(named: "../x", in: "") }
        await #expect(throws: LibraryError.destinationInsideSource) { try await library.move(at: folder.relativePath, toFolder: "Math") }
        #expect(await library.store.folderID(of: "Math") != nil)
    }

    @Test("Checkout is exclusive: a second checkout says alreadyOpen, mutations refuse, release lifts both")
    func ledger() async throws {
        let (scratch, library) = try makeLibrary("lib-ledger")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Notes", in: "")
        guard case .opened(let notebook) = await library.checkout(item.relativePath) else { Issue.record("open failed"); return }
        guard case .alreadyOpen(let id) = await library.checkout(item.relativePath) else { Issue.record("second checkout opened"); return }
        #expect(id == notebook.notebookID)
        await #expect(throws: LibraryError.notebookIsOpen(name: "Notes.tubernotes")) { try await library.rename(at: item.relativePath, to: "Other") }
        await #expect(throws: LibraryError.notebookIsOpen(name: "Notes.tubernotes")) { try await library.trash(at: item.relativePath) }
        #expect(library.openCount == 1)
        #expect(await library.release(item.relativePath) == .clean)
        #expect(library.openCount == 0)
        _ = try await library.rename(at: item.relativePath, to: "Other")
    }

    @Test("A folder holding an open notebook is locked too")
    func ancestorLock() async throws {
        let (scratch, library) = try makeLibrary("lib-ancestor")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Work", in: "")
        let item = try await library.store.createNotebook(named: "Plan", in: "Work")
        guard case .opened = await library.checkout(item.relativePath) else { Issue.record("open failed"); return }
        #expect(library.isLocked("Work"))
        await #expect(throws: LibraryError.notebookIsOpen(name: "Work")) { try await library.rename(at: "Work", to: "Play") }
        _ = await library.release(item.relativePath)
        #expect(!library.isLocked("Work"))
    }

    @Test("Trash and recover restores the original name; a collision suffixes; a vanished origin lands at the root")
    func trashRoundTrip() async throws {
        let (scratch, library) = try makeLibrary("lib-trash")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Old", in: "")
        let item = try await library.store.createNotebook(named: "Journal", in: "Old")
        let entry = try await library.trash(at: item.relativePath)
        #expect(entry.name == "Journal")
        let oldID = await library.store.folderID(of: "Old")
        #expect(entry.origin.originFolderID == oldID)
        #expect(try await library.store.list(folder: "Old").isEmpty)
        let listed = try await library.store.listTrash()
        #expect(listed.map(\.id) == [entry.id])
        let recovered = try await library.store.recover(entry)
        #expect(recovered.relativePath == "Old/Journal.tubernotes")

        // Collision: trash it, create another with the same name, recover.
        let again = try await library.trash(at: recovered.relativePath)
        _ = try await library.store.createNotebook(named: "Journal", in: "Old")
        #expect(try await library.store.recover(again).relativePath == "Old/Journal 2.tubernotes")

        // Vanished origin: trash the notebook, then trash its folder, recover the notebook.
        let third = try await library.trash(at: "Old/Journal 2.tubernotes")
        _ = try await library.trash(at: "Old")
        #expect(try await library.store.recover(third).relativePath == "Journal 2.tubernotes")
    }

    @Test("Duplicate mints a new notebook identity, keeps page identities, and the copy's ink reads")
    func duplicate() async throws {
        let (scratch, library) = try makeLibrary("lib-dup")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Source", in: "")
        guard case .opened(let notebook) = await library.checkout(item.relativePath, schedule: fast) else { Issue.record("open failed"); return }
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 4), echoOf: nil)
        _ = await library.release(item.relativePath)

        let copy = try await library.duplicateNotebook(at: item.relativePath)
        #expect(copy.relativePath == "Source copy.tubernotes")
        let original = try await PackageStore(root: library.store.url(of: item.relativePath)).load()
        let duplicated = PackageStore(root: library.store.url(of: copy.relativePath))
        let copied = try await duplicated.load()
        #expect(copied.index.notebookID != original.index.notebookID)
        #expect(copied.index.pageIDs == original.index.pageIDs)
        let bytes = try await duplicated.loadPage(page)
        #expect(bytes.faults.isEmpty)
        #expect(try PKDrawing(data: try #require(bytes.inkArchive)).strokes.count == 4)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.store.stagingRoot.path).isEmpty)
    }

    @Test("The identity index resolves live, trashed, and missing, and survives a move")
    func identities() async throws {
        let (scratch, library) = try makeLibrary("lib-ids")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "A", in: "")
        let item = try await library.store.createNotebook(named: "Linked", in: "A")
        let id = try #require(item.notebookID)
        try await library.refreshIdentities()
        #expect(library.identities.resolve(id) == .live(path: item.relativePath))
        let moved = try await library.move(at: item.relativePath, toFolder: "")
        try await library.refreshIdentities()
        #expect(library.identities.resolve(id) == .live(path: moved.relativePath))
        let entry = try await library.trash(at: moved.relativePath)
        try await library.refreshIdentities()
        #expect(library.identities.resolve(id) == .trashed(container: entry.id))
        try await library.store.deletePermanently(entry)
        try await library.refreshIdentities()
        #expect(library.identities.resolve(id) == .missing)
    }

    @Test("A notebook created at a stated size and paper has exactly that one page on disk")
    func createNotebookAtAStatedSizeAndPaper() async throws {
        let (scratch, library) = try makeLibrary("lib-page-size")
        defer { withExtendedLifetime(scratch) {} }
        let a5 = try #require(PageSize.a5.geometry(.portrait))
        let item = try await library.store.createNotebook(named: "Pocket", in: "", geometry: a5, paper: .lined)

        let loaded = try await PackageStore(root: library.store.url(of: item.relativePath)).load()
        #expect(loaded.pageFaults.isEmpty)
        #expect(loaded.index.pages.count == 1)
        let record = try #require(loaded.index.pages.first)
        #expect(record.geometry == a5)
        #expect(record.paper == .known(.drawn(.lined)))
    }

    @Test("A listed item carries its identity and when it was made")
    func identityAndCreationDate() async throws {
        let (scratch, library) = try makeLibrary("lib-identity")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Term", in: "")
        _ = try await library.store.createNotebook(named: "Physics", in: "Term")

        let notebook = try #require(try await library.store.list(folder: "Term").first)
        let loaded = try await PackageStore(root: library.store.url(of: notebook.relativePath)).load()
        #expect(notebook.createdAt == loaded.index.createdAt)
        #expect(notebook.folderID == nil)
        #expect(notebook.identity == .notebook(loaded.index.notebookID))

        let folder = try #require(try await library.store.list(folder: "").first)
        #expect(folder.notebookID == nil)
        #expect(folder.folderID == (await library.store.folderID(of: "Term")))
        #expect(folder.identity == .folder(try #require(folder.folderID)))
        #expect(folder.createdAt > Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("A cover source is the first page, at the version the listing shows")
    func coverSource() async throws {
        let (scratch, library) = try makeLibrary("lib-cover-source")
        defer { withExtendedLifetime(scratch) {} }
        let a5 = try #require(PageSize.a5.geometry(.portrait))
        let item = try await library.store.createNotebook(named: "Sketch", in: "", geometry: a5, paper: .grid)
        _ = try await library.store.createFolder(named: "Box", in: "")

        let source = try await library.store.coverSource(of: item.relativePath)
        let loaded = try await PackageStore(root: library.store.url(of: item.relativePath)).load()
        #expect(source.pageID == loaded.index.pageIDs[0])
        #expect(source.geometry == a5)
        #expect(source.paper == .drawn(.grid))
        #expect(source.bytes.faults.isEmpty)
        let listed = try #require(try await library.store.list(folder: "").first { $0.kind == .notebook })
        #expect(source.version == CoverSource.version(at: listed.modifiedAt))

        await #expect(throws: LibraryError.notANotebook("Box")) { try await library.store.coverSource(of: "Box") }
    }

    @Test("listFolders sees folders only; emptyTrash leaves no container behind")
    func foldersAndEmptyTrash() async throws {
        let (scratch, library) = try makeLibrary("lib-folders-empty")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Archive", in: "")
        _ = try await library.store.createFolder(named: "Current", in: "")
        let notebook = try await library.store.createNotebook(named: "Loose", in: "")
        #expect(try await library.store.listFolders(in: "").map(\.name) == ["Archive", "Current"])
        #expect(try await library.store.listFolders(in: "Archive").isEmpty)

        _ = try await library.trash(at: notebook.relativePath)
        _ = try await library.trash(at: "Current")
        #expect(try await library.store.listTrash().count == 2)
        try await library.store.emptyTrash()
        #expect(try await library.store.listTrash().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.store.trashRoot.path).isEmpty)
    }

    @Test("A star round-trips, and the listing mixes kinds across parents")
    func favorites() async throws {
        let (scratch, library) = try makeLibrary("lib-favorites")
        defer { withExtendedLifetime(scratch) {} }
        let work = try await library.store.createFolder(named: "Work", in: "")
        let plan = try await library.store.createNotebook(named: "Plan", in: "Work")
        _ = try await library.store.createNotebook(named: "Loose", in: "")
        #expect(try await library.store.favorites().isEmpty)

        let folderIdentity = try #require(work.identity)
        let notebookIdentity = try #require(plan.identity)
        try await library.store.setFavorite(folderIdentity, true)
        try await library.store.setFavorite(notebookIdentity, true)
        #expect(try await library.store.favorites() == [folderIdentity, notebookIdentity])
        #expect(try await library.store.listFavorites().map(\.relativePath) == ["Work", "Work/Plan.tubernotes"])

        try await library.store.setFavorite(folderIdentity, false)
        #expect(try await library.store.listFavorites().map(\.relativePath) == ["Work/Plan.tubernotes"])
    }

    @Test("A star follows the item through rename, move, trash, and recovery")
    func favoriteSurvivesEveryMove() async throws {
        let (scratch, library) = try makeLibrary("lib-favorite-survives")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Drafts", in: "")
        let item = try await library.store.createNotebook(named: "Essay", in: "Drafts")
        let identity = try #require(item.identity)
        try await library.store.setFavorite(identity, true)

        let renamed = try await library.rename(at: item.relativePath, to: "Essay II")
        #expect(try await library.store.listFavorites().map(\.relativePath) == [renamed.relativePath])
        let moved = try await library.move(at: renamed.relativePath, toFolder: "")
        #expect(try await library.store.listFavorites().map(\.relativePath) == [moved.relativePath])

        let entry = try await library.trash(at: moved.relativePath)
        #expect(try await library.store.listFavorites().isEmpty)
        #expect(try await library.store.favorites() == [identity])
        let recovered = try await library.store.recover(entry)
        #expect(try await library.store.listFavorites().map(\.relativePath) == [recovered.relativePath])
    }

    @Test("Two packages with one identity: the scan re-mints the second")
    func collision() async throws {
        let (scratch, library) = try makeLibrary("lib-collide")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "One", in: "")
        let source = library.store.url(of: item.relativePath)
        try FileManager.default.copyItem(at: source, to: library.store.url(of: "Two.tubernotes"))
        try await library.refreshIdentities()
        #expect(library.identities.live.count == 2)
        let ids = try await library.store.list(folder: "").compactMap(\.notebookID)
        #expect(Set(ids).count == 2)
    }
}
