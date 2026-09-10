import Foundation
import PencilKit
import Testing
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
