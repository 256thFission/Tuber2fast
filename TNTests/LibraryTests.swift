import Foundation
import PencilKit
import Testing
@testable import TNEditor
@testable import TNFormat
@testable import TNLibrary
@testable import TNModel
@testable import TNNotebook

/// The tests' one rung: the version before the current one wrote the
/// current index plus a `title` key, which strict decoding refuses. The step
/// drops the key and writes the current version through the save seam.
let oneStepUp: MigrationStep = { root, fileSystem in
    let indexURL = root.appendingPathComponent("notebook.json")
    var object = try jsonObject(fileSystem.read(indexURL))
    object.removeValue(forKey: "title")
    object["formatVersion"] = NotebookIndex.currentFormatVersion
    try fileSystem.writeAtomically(jsonData(object), to: indexURL, syncing: root)
}

@Suite("Library: the tree, the trash, the ledger")
@MainActor
struct LibraryTests {
    func makeLibrary(_ name: String, ladder: [MigrationStep] = IndexFile.migrationSteps) throws -> (Scratch, Library) {
        let scratch = try Scratch(name)
        let store = try LibraryStore(base: scratch.root, ladder: ladder)
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

    @Test("Creating under a taken name lands on the first free Name (n); renaming onto one refuses")
    func takenNames() async throws {
        let (scratch, library) = try makeLibrary("lib-taken-names")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createNotebook(named: "New notebook", in: "")
        let second = try await library.store.createNotebook(named: "New notebook", in: "")
        let third = try await library.store.createNotebook(named: "New notebook", in: "")
        #expect(second.relativePath == "New notebook (1).tubernotes")
        #expect(third.relativePath == "New notebook (2).tubernotes")
        _ = try await library.store.createFolder(named: "New folder", in: "")
        let folder = try await library.store.createFolder(named: "New folder", in: "")
        #expect(folder.relativePath == "New folder (1)")
        await #expect(throws: LibraryError.alreadyExists("New notebook (1)")) {
            try await library.rename(at: third.relativePath, to: "New notebook (1)")
        }
    }

    @Test("Two creates in flight under one name land as two notebooks under two names")
    func concurrentCreatesClaimDistinctNames() async throws {
        let (scratch, library) = try makeLibrary("lib-concurrent-create")
        defer { withExtendedLifetime(scratch) {} }
        let store = library.store
        async let first = store.createNotebook(named: "New notebook", in: "")
        async let second = store.createNotebook(named: "New notebook", in: "")
        let made = try await [first, second]
        #expect(Set(made.map(\.relativePath)) == ["New notebook.tubernotes", "New notebook (1).tubernotes"])
        let ids = made.compactMap(\.notebookID)
        #expect(Set(ids).count == 2)
        #expect(Set(try await store.list(folder: "").compactMap(\.notebookID)) == Set(ids))
    }

    @Test("A move into the current parent returns the item and moves no files")
    func movingIntoTheCurrentParent() async throws {
        let (scratch, library) = try makeLibrary("lib-move-nowhere")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Drafts", in: "")
        let item = try await library.store.createNotebook(named: "Essay", in: "Drafts")
        let before = try await library.store.list(folder: "Drafts")

        let stayed = try await library.move(at: item.relativePath, toFolder: "Drafts")
        #expect(stayed.relativePath == item.relativePath)
        #expect(try await library.store.list(folder: "Drafts") == before)

        // And at the root, where the parent path is the empty string.
        let loose = try await library.store.createNotebook(named: "Loose", in: "")
        let alsoStayed = try await library.move(at: loose.relativePath, toFolder: "")
        #expect(alsoStayed.relativePath == loose.relativePath)
        #expect(try await library.store.list(folder: "").map(\.name) == ["Drafts", "Loose"])
    }

    @Test("The tree lists everything under a folder, depth first, by full path")
    func listingTheTree() async throws {
        let (scratch, library) = try makeLibrary("lib-tree-walk")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Term", in: "")
        _ = try await library.store.createFolder(named: "Week 1", in: "Term")
        _ = try await library.store.createNotebook(named: "Deep", in: "Term/Week 1")
        _ = try await library.store.createNotebook(named: "Loose", in: "")

        let whole = try await library.store.listTree(under: "")
        #expect(whole.map(\.relativePath) == [
            "Loose.tubernotes",
            "Term",
            "Term/Week 1",
            "Term/Week 1/Deep.tubernotes",
        ])
        #expect(whole.last?.parentPath == "Term/Week 1")
        #expect(whole.first?.parentPath == "")

        // Under a folder, the root's other items are not in it.
        #expect(try await library.store.listTree(under: "Term").map(\.relativePath) == [
            "Term/Week 1",
            "Term/Week 1/Deep.tubernotes",
        ])
    }

    @Test("Checkout is exclusive: a second checkout says alreadyOpen, mutations refuse, release lifts both")
    func ledger() async throws {
        let (scratch, library) = try makeLibrary("lib-ledger")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Notes", in: "")
        guard case .opened(let notebook) = await library.checkout(item.relativePath) else { Issue.record("open failed"); return }
        guard case .alreadyOpen(let id) = await library.checkout(item.relativePath) else { Issue.record("second checkout opened"); return }
        #expect(id == notebook.notebookID)
        await #expect(throws: LibraryError.notebookIsOpen(name: "Notes")) { try await library.rename(at: item.relativePath, to: "Other") }
        await #expect(throws: LibraryError.notebookIsOpen(name: "Notes")) { try await library.trash(at: item.relativePath) }
        #expect(library.openCount == 1)
        #expect(await notebook.close() == .clean)
        library.release(item.relativePath)
        #expect(library.openCount == 0)
        _ = try await library.rename(at: item.relativePath, to: "Other")
    }

    @Test("A discard after a failing save stops the save engine before the checkout ends, and nothing more is written")
    func discardStopsTheSaveEngine() async throws {
        let scratch = try Scratch("lib-discard")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await LibraryStore(base: scratch.root).createNotebook(named: "Notes", in: "")
        // The first publish after the checkout is the first pass's; a retry
        // would succeed and write the ink.
        let library = Library(store: try LibraryStore(base: scratch.root, fileSystem: FaultingFileSystem(faults: [.failPublish(nth: 1)])))
        guard case .opened(let notebook) = await library.checkout(item.relativePath, schedule: fast) else { Issue.record("open failed"); return }
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        notebook.inkChanged(on: page, Ink.drawing(strokes: 2), echoOf: nil)
        await notebook.flush()
        #expect(notebook.lastSaveError != nil)
        #expect(notebook.debounce != nil, "the failed pass armed its retry")
        let package = library.store.url(of: item.relativePath)
        let before = try files(under: package)

        await library.discard(item.relativePath)
        #expect(notebook.isClosed)
        #expect(notebook.debounce == nil && notebook.currentSave == nil)
        #expect(!library.isCheckedOut(item.relativePath))
        try await Task.sleep(for: .milliseconds(200))   // well past the retry's 20 ms backoff
        #expect(try files(under: package) == before)
    }

    @Test("A folder holding an open notebook is locked too, and the refusal names the notebook")
    func ancestorLock() async throws {
        let (scratch, library) = try makeLibrary("lib-ancestor")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Work", in: "")
        let item = try await library.store.createNotebook(named: "Plan", in: "Work")
        guard case .opened(let notebook) = await library.checkout(item.relativePath) else { Issue.record("open failed"); return }
        #expect(library.isLocked("Work"))
        await #expect(throws: LibraryError.notebookIsOpen(name: "Plan")) { try await library.rename(at: "Work", to: "Play") }
        #expect(await notebook.close() == .clean)
        library.release(item.relativePath)
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
        #expect(try entry.origin.get().originFolderID == oldID)
        #expect(try await library.store.list(folder: "Old").isEmpty)
        let listed = try await library.store.listTrash()
        #expect(listed.map(\.id) == [entry.id])
        let recovered = try await library.store.recover(entry)
        #expect(recovered.relativePath == "Old/Journal.tubernotes")

        // Collision: trash it, create another with the same name, recover.
        let again = try await library.trash(at: recovered.relativePath)
        _ = try await library.store.createNotebook(named: "Journal", in: "Old")
        #expect(try await library.store.recover(again).relativePath == "Old/Journal (1).tubernotes")

        // Vanished origin: trash the notebook, then trash its folder, recover the notebook.
        let third = try await library.trash(at: "Old/Journal (1).tubernotes")
        _ = try await library.trash(at: "Old")
        #expect(try await library.store.recover(third).relativePath == "Journal (1).tubernotes")
    }

    @Test("A recovery and a duplicate land on the first free Name (n), as a create does")
    func recoverUsesFreeName() async throws {
        let (scratch, library) = try makeLibrary("lib-recover-free-name")
        defer { withExtendedLifetime(scratch) {} }
        let journal = try await library.store.createNotebook(named: "Journal", in: "")
        let trashedNotebook = try await library.trash(at: journal.relativePath)
        _ = try await library.store.createNotebook(named: "Journal", in: "")
        _ = try await library.store.createNotebook(named: "Journal", in: "")
        #expect(try await library.store.recover(trashedNotebook).relativePath == "Journal (2).tubernotes")

        let term = try await library.store.createFolder(named: "Term", in: "")
        let trashedFolder = try await library.trash(at: term.relativePath)
        _ = try await library.store.createFolder(named: "Term", in: "")
        let recovered = try await library.store.recover(trashedFolder)
        #expect(recovered.relativePath == "Term (1)")
        #expect(recovered.folderID == term.folderID)

        #expect(try await library.duplicateNotebook(at: "Journal.tubernotes").relativePath == "Journal copy.tubernotes")
        #expect(try await library.duplicateNotebook(at: "Journal.tubernotes").relativePath == "Journal copy (1).tubernotes")
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
        #expect(await notebook.close() == .clean)
        library.release(item.relativePath)

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
        // File system dates carry second resolution on some volumes, so the
        // bound is the second the folder was made in, not the instant.
        let before = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        _ = try await library.store.createFolder(named: "Term", in: "")
        _ = try await library.store.createNotebook(named: "Physics", in: "Term")
        let after = Date()

        let notebook = try #require(try await library.store.list(folder: "Term").first)
        let loaded = try await PackageStore(root: library.store.url(of: notebook.relativePath)).load()
        #expect(notebook.createdAt == loaded.index.createdAt)
        #expect(notebook.folderID == nil)
        #expect(notebook.identity == .notebook(loaded.index.notebookID))

        let folder = try #require(try await library.store.list(folder: "").first)
        #expect(folder.notebookID == nil)
        #expect(folder.folderID == (await library.store.folderID(of: "Term")))
        #expect(folder.identity == .folder(try #require(folder.folderID)))
        #expect(folder.createdAt >= before && folder.createdAt <= after)
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

    @Test("A folder's colour and symbol round trip, and a new folder is plain")
    func decoration() async throws {
        let (scratch, library) = try makeLibrary("lib-decoration")
        defer { withExtendedLifetime(scratch) {} }
        let made = try await library.store.createFolder(named: "Term", in: "")
        #expect(made.decoration == .plain)
        #expect(made.decoration?.color == .neutral)
        #expect(made.decoration?.symbol == .folder)

        let chosen = FolderDecoration(color: .blue, symbol: .star)
        try await library.store.setDecoration(chosen, at: "Term")
        #expect(try await library.store.list(folder: "").first?.decoration == chosen)
        // Decorating reads the identity back rather than minting one.
        #expect(await library.store.folderID(of: "Term") == made.folderID)

        // A notebook has no sidecar, so it has no decoration and cannot take
        // one.
        let essay = try await library.store.createNotebook(named: "Essay", in: "")
        #expect(essay.decoration == nil)
        await #expect(throws: LibraryError.notAFolder(essay.relativePath)) {
            try await library.store.setDecoration(chosen, at: essay.relativePath)
        }
    }

    @Test("Decoration follows the folder through rename, move, trash, and recovery")
    func decorationSurvivesEveryMove() async throws {
        let (scratch, library) = try makeLibrary("lib-decoration-survives")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Archive", in: "")
        _ = try await library.store.createFolder(named: "Term", in: "")
        let chosen = FolderDecoration(color: .purple, symbol: .school)
        try await library.store.setDecoration(chosen, at: "Term")

        let renamed = try await library.rename(at: "Term", to: "Autumn")
        #expect(renamed.decoration == chosen)
        let moved = try await library.move(at: renamed.relativePath, toFolder: "Archive")
        #expect(moved.decoration == chosen)

        let entry = try await library.trash(at: moved.relativePath)
        let recovered = try await library.store.recover(entry)
        #expect(recovered.decoration == chosen)
    }

    @Test("A colour name this build does not know refuses the sidecar loudly: the folder lists with the fault and no identity")
    func anUnknownColourRefusesTheSidecar() async throws {
        let (scratch, library) = try makeLibrary("lib-decoration-unknown")
        defer { withExtendedLifetime(scratch) {} }
        let made = try await library.store.createFolder(named: "Term", in: "")
        let identity = try #require(made.identity)
        try await library.store.setFavorite(identity, true)

        let sidecar = library.store.url(of: "Term").appendingPathComponent(".folder.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        object["color"] = "chartreuse"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: sidecar)

        // The cost of a strict sidecar, said where the folder is rather than
        // swallowed: a folder with no identity has no star, though the file
        // still holds it.
        let listed = try #require(try await library.store.list(folder: "").first)
        #expect(listed.name == "Term")
        #expect(listed.decoration == nil)
        #expect(listed.folderID == nil)
        #expect(listed.identity == nil)
        let fault = try #require(listed.fault)
        #expect(fault.description.hasPrefix(".folder.json cannot be read: "))
        #expect(fault.description.contains("chartreuse"))
        #expect(try await library.store.listFavorites().isEmpty)
        #expect(try await library.store.favorites() == [identity])
    }

    @Test("An unreadable .folder.json lists the folder with its fault, lists what it holds, and refuses a decoration with that fault")
    func anUnreadableFolderFileIsListedLoudly() async throws {
        let (scratch, library) = try makeLibrary("lib-folder-unreadable")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Term", in: "")
        _ = try await library.store.createNotebook(named: "Essay", in: "Term")
        let sidecar = library.store.url(of: "Term").appendingPathComponent(".folder.json")
        let written = try Data(contentsOf: sidecar)
        // A newer sidecar with a key this build does not know is refused by
        // its number, not by the key: the version is read first.
        var newer = try jsonObject(written)
        newer["formatVersion"] = FolderFile.currentFormatVersion + 1
        newer["tint"] = "blue"
        let newerBytes = try jsonData(newer)

        for (bytes, reason) in [
            (Data(), "corrupt JSON"),
            (newerBytes, FormatFault.newerFormat(found: FolderFile.currentFormatVersion + 1).description),
        ] {
            try bytes.write(to: sidecar)
            let listed = try await library.store.list(folder: "")
            #expect(listed.map(\.name) == ["Term"])
            let fault = try #require(listed.first?.fault, "\(reason)")
            #expect(fault.description.hasPrefix(".folder.json cannot be read: \(reason)"))
            #expect(listed.first?.identity == nil)
            #expect(listed.first?.decoration == nil)
            #expect(try await library.store.list(folder: "Term").map(\.name) == ["Essay"])

            await #expect(throws: fault) {
                try await library.store.setDecoration(FolderDecoration(color: .red, symbol: .star), at: "Term")
            }
            #expect(try Data(contentsOf: sidecar) == bytes, "a refused decoration writes nothing")
        }
    }

    @Test("`.folder.json` carries exactly its keys, and losing or gaining one refuses it")
    func folderFileKeys() async throws {
        let (scratch, library) = try makeLibrary("lib-folder-keys")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Term", in: "")
        let sidecar = library.store.url(of: "Term").appendingPathComponent(".folder.json")
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        #expect(Set(written.keys) == ["formatVersion", "folderID", "color", "symbol"])
        #expect(written["formatVersion"] as? Int == 1)

        for key in written.keys {
            var short = written
            short.removeValue(forKey: key)
            try JSONSerialization.data(withJSONObject: short, options: [.sortedKeys]).write(to: sidecar)
            await #expect(throws: LibraryError.unreadable(file: ".folder.json", reason: "missing key \(key)")) {
                try await library.store.folderFile(of: "Term")
            }
        }

        var extra = written
        extra["tint"] = "blue"
        try JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys]).write(to: sidecar)
        await #expect(throws: LibraryError.unreadable(file: ".folder.json", reason: "unknown key tint")) {
            try await library.store.folderFile(of: "Term")
        }

        try JSONSerialization.data(withJSONObject: written, options: [.sortedKeys]).write(to: sidecar)
        _ = try await library.store.folderFile(of: "Term")
    }

    @Test("`Favorites.json` carries exactly its keys, is read version first, and losing or gaining a key refuses it")
    func favoritesKeyPin() async throws {
        let (scratch, library) = try makeLibrary("lib-favorites-keys")
        defer { withExtendedLifetime(scratch) {} }
        let made = try await library.store.createNotebook(named: "Essay", in: "")
        try await library.store.setFavorite(try #require(made.identity), true)
        let url = library.store.favoritesURL
        let written = try jsonObject(Data(contentsOf: url))
        #expect(Set(written.keys) == ["formatVersion", "notebooks", "folders"])
        #expect(written["formatVersion"] as? Int == 1)

        for key in written.keys {
            var short = written
            short.removeValue(forKey: key)
            try jsonData(short).write(to: url)
            await #expect(throws: LibraryError.unreadable(file: "Favorites.json", reason: "missing key \(key)")) {
                try await library.store.favorites()
            }
        }
        var extra = written
        extra["pinned"] = "x"
        try jsonData(extra).write(to: url)
        await #expect(throws: LibraryError.unreadable(file: "Favorites.json", reason: "unknown key pinned")) {
            try await library.store.favorites()
        }
        extra["formatVersion"] = 2
        try jsonData(extra).write(to: url)
        await #expect(throws: LibraryError.unreadable(file: "Favorites.json", reason: FormatFault.newerFormat(found: 2).description)) {
            try await library.store.favorites()
        }
    }

    @Test("`origin.json` carries exactly its keys, is read version first, and losing or gaining a key refuses it")
    func trashOriginKeyPin() async throws {
        let (scratch, library) = try makeLibrary("lib-origin-keys")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createFolder(named: "Term", in: "")
        let nested = try await library.store.createNotebook(named: "Essay", in: "Term")
        let loose = try await library.store.createNotebook(named: "Loose", in: "")
        let fromFolder = try await library.trash(at: nested.relativePath)
        let fromRoot = try await library.trash(at: loose.relativePath)
        func originURL(_ entry: TrashEntry) -> URL {
            library.store.trashRoot.appendingPathComponent(entry.id).appendingPathComponent("origin.json")
        }

        // The root has no folder, so its identity is left out, not written
        // as null.
        let written = try jsonObject(Data(contentsOf: originURL(fromFolder)))
        #expect(Set(written.keys) == ["formatVersion", "originFolderID", "originPathHint", "originName", "deletedAt"])
        #expect(written["formatVersion"] as? Int == 1)
        #expect(Set(try jsonObject(Data(contentsOf: originURL(fromRoot))).keys) == ["formatVersion", "originPathHint", "originName", "deletedAt"])

        func listedOrigin() async throws -> Result<TrashOrigin, LibraryError> {
            try #require(try await library.store.listTrash().first { $0.id == fromFolder.id }).origin
        }
        let asWritten = try await listedOrigin()
        #expect(try asWritten.get().originName == "Essay.tubernotes")
        for key in written.keys where key != "originFolderID" {
            var short = written
            short.removeValue(forKey: key)
            try jsonData(short).write(to: originURL(fromFolder))
            #expect(try await listedOrigin() == .failure(.unreadable(file: "origin.json", reason: "missing key \(key)")))
        }
        var extra = written
        extra["note"] = "x"
        try jsonData(extra).write(to: originURL(fromFolder))
        #expect(try await listedOrigin() == .failure(.unreadable(file: "origin.json", reason: "unknown key note")))
        extra["formatVersion"] = 2
        try jsonData(extra).write(to: originURL(fromFolder))
        #expect(try await listedOrigin() == .failure(.unreadable(file: "origin.json", reason: FormatFault.newerFormat(found: 2).description)))

        try jsonData(written).write(to: originURL(fromFolder))
        #expect(try await listedOrigin() == asWritten)
    }

    @Test("A notebook at a newer version lists as itself and refuses to open by its version")
    func listingKeepsANewerNotebooksIdentity() async throws {
        let (scratch, library) = try makeLibrary("lib-newer")
        defer { withExtendedLifetime(scratch) {} }
        let made = try await library.store.createNotebook(named: "Physics", in: "")
        let identity = try #require(made.notebookID)
        let indexURL = PackageLayout(root: library.store.url(of: made.relativePath)).indexURL
        var object = try jsonObject(Data(contentsOf: indexURL))
        let newer = NotebookIndex.currentFormatVersion + 1
        object["formatVersion"] = newer
        object["title"] = "Physics"
        try jsonData(object).write(to: indexURL)

        let listed = try #require(try await library.store.list(folder: "").first)
        #expect(listed.notebookID == identity)
        guard case .failed(.format(.newerFormat(found: newer))) = await library.checkout(made.relativePath) else {
            Issue.record("a newer notebook must refuse by its version")
            return
        }
    }

    @Test("Two packages with one identity are both listed, a link to it is collided, and neither is rewritten")
    func collidedPackagesAreBothListedAndNeitherRewritten() async throws {
        let (scratch, library) = try makeLibrary("lib-collide")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "One", in: "")
        let id = try #require(item.notebookID)
        try FileManager.default.copyItem(at: library.store.url(of: item.relativePath), to: library.store.url(of: "Two.tubernotes"))
        let indexURLs = ["One.tubernotes", "Two.tubernotes"].map { PackageLayout(root: library.store.url(of: $0)).indexURL }
        let before = try indexURLs.map { try Data(contentsOf: $0) }

        try await library.refreshIdentities()
        #expect(try await library.store.list(folder: "").map(\.notebookID) == [id, id])
        #expect(library.identities.live == [id: "One.tubernotes"])
        #expect(library.identities.collisions == ["Two.tubernotes": id])
        #expect(library.identities.resolve(id) == .collided)
        #expect(try indexURLs.map { try Data(contentsOf: $0) } == before)
    }

    @Test("A collided path does not open, and neither does a path whose identity another checkout holds")
    func checkoutOfACollidedPathIsRefused() async throws {
        let (scratch, library) = try makeLibrary("lib-collide-checkout")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "One", in: "")
        try FileManager.default.copyItem(at: library.store.url(of: item.relativePath), to: library.store.url(of: "Two.tubernotes"))

        // Before the index is built, only the ledger can see the collision.
        guard case .opened(let two) = await library.checkout("Two.tubernotes") else { Issue.record("open failed"); return }
        guard case .failed(.identityCollision("One.tubernotes")) = await library.checkout("One.tubernotes") else {
            Issue.record("a second checkout under one identity must refuse")
            return
        }
        #expect(library.openCount == 1)
        #expect(await two.close() == .clean)
        library.release("Two.tubernotes")

        try await library.refreshIdentities()
        guard case .failed(.identityCollision("Two.tubernotes")) = await library.checkout("Two.tubernotes") else {
            Issue.record("a collided path must refuse")
            return
        }
        guard case .opened(let one) = await library.checkout("One.tubernotes") else { Issue.record("open failed"); return }
        #expect(await one.close() == .clean)
        library.release("One.tubernotes")
    }

    /// The three faults a sidecar commit meets, and whether the old file is
    /// what remains. A failed sync comes after the rename, so the new file is
    /// already in place.
    static let sidecarFaults: [(fault: FaultingFileSystem.Fault, keepsOld: Bool)] = [
        (.failStage(nth: 1), true), (.failPublish(nth: 1), true), (.failSync(nth: 1), false),
    ]

    /// A store over the same library whose file system fails on cue.
    func faulting(_ scratch: Scratch, _ fault: FaultingFileSystem.Fault) throws -> LibraryStore {
        try LibraryStore(base: scratch.root, fileSystem: FaultingFileSystem(faults: [fault]))
    }

    @Test("A star written into each fault leaves the old stars or the new ones")
    func favoriteWriteSurvivesEachFault() async throws {
        for (fault, keepsOld) in Self.sidecarFaults {
            let (scratch, library) = try makeLibrary("lib-favorite-fault")
            defer { withExtendedLifetime(scratch) {} }
            let first = try #require(try await library.store.createNotebook(named: "First", in: "").identity)
            let second = try #require(try await library.store.createNotebook(named: "Second", in: "").identity)
            try await library.store.setFavorite(first, true)

            let store = try faulting(scratch, fault)
            await #expect(throws: LibraryError.self, "\(fault)") { try await store.setFavorite(second, true) }
            #expect(try await library.store.favorites() == Set(keepsOld ? [first] : [first, second]), "\(fault)")
        }
    }

    @Test("A decoration written into each fault leaves the old sidecar or the new one, with its identity")
    func decorationWriteSurvivesEachFault() async throws {
        for (fault, keepsOld) in Self.sidecarFaults {
            let (scratch, library) = try makeLibrary("lib-decoration-fault")
            defer { withExtendedLifetime(scratch) {} }
            let made = try await library.store.createFolder(named: "Term", in: "")
            let chosen = FolderDecoration(color: .blue, symbol: .star)

            let store = try faulting(scratch, fault)
            await #expect(throws: LibraryError.self, "\(fault)") { try await store.setDecoration(chosen, at: "Term") }
            let sidecar = try await library.store.folderFile(of: "Term")
            #expect(sidecar.folderID == made.folderID, "\(fault)")
            #expect(sidecar.decoration == (keepsOld ? .plain : chosen), "\(fault)")
        }
    }

    @Test("A trash interrupted before the move leaves the item where it was, and a retry trashes it")
    func trashInterruptedBeforeTheMoveKeepsTheItem() async throws {
        for (fault, _) in Self.sidecarFaults {
            let (scratch, library) = try makeLibrary("lib-trash-fault")
            defer { withExtendedLifetime(scratch) {} }
            let item = try await library.store.createNotebook(named: "Essay", in: "")

            let store = try faulting(scratch, fault)
            await #expect(throws: LibraryError.self, "\(fault)") { try await store.trash(at: item.relativePath) }
            let listed = try await library.store.list(folder: "")
            #expect(listed.map(\.relativePath) == [item.relativePath], "\(fault)")
            #expect(listed.map(\.notebookID) == [item.notebookID], "\(fault)")
            #expect(try await library.store.listTrash().isEmpty, "\(fault)")

            let entry = try await library.trash(at: item.relativePath)
            #expect(try await library.store.listTrash().map(\.id) == [entry.id], "\(fault)")
        }
    }

    @Test("A trash container that holds an item refuses a second item under its identity, and both stay")
    func occupiedTrashContainerRefuses() async throws {
        let (scratch, library) = try makeLibrary("lib-trash-occupied")
        defer { withExtendedLifetime(scratch) {} }
        let one = try await library.store.createNotebook(named: "One", in: "")
        try FileManager.default.copyItem(at: library.store.url(of: one.relativePath), to: library.store.url(of: "Two.tubernotes"))
        let trashed = try await library.trash(at: one.relativePath)

        await #expect(throws: LibraryError.alreadyExists(trashed.id)) { try await library.trash(at: "Two.tubernotes") }
        let listed = try await library.store.list(folder: "")
        #expect(listed.map(\.relativePath) == ["Two.tubernotes"])
        #expect(listed.map(\.notebookID) == [one.notebookID])
        let inTrash = try await library.store.listTrash()
        #expect(inTrash.map(\.id) == [trashed.id])
        #expect(inTrash.map(\.notebookID) == [one.notebookID])
    }

    @Test("A container left holding only its sidecar does not block the next trash of its item")
    func sidecarOnlyLeftoverDoesNotBlockTrash() async throws {
        let (scratch, library) = try makeLibrary("lib-trash-leftover")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Essay", in: "")
        let first = try await library.trash(at: item.relativePath)
        // A recovery interrupted after its move and before it removed the
        // container: the container keeps `origin.json` and nothing else.
        let container = library.store.trashRoot.appendingPathComponent(first.id)
        try FileManager.default.moveItem(
            at: container.appendingPathComponent(try first.origin.get().originName),
            to: library.store.url(of: item.relativePath)
        )
        #expect(try await library.store.listTrash().isEmpty)

        let second = try await library.trash(at: item.relativePath)
        #expect(second.id == first.id)
        #expect(try await library.store.listTrash().map(\.id) == [first.id])
        #expect(try await library.store.list(folder: "").isEmpty)
    }

    @Test("A trash record that does not read lists its item with the fault, enables Empty, and recovers to the root")
    func anUnreadableTrashRecordIsListedAndRecoverable() async throws {
        for record in ["zero bytes", "another version"] {
            let (scratch, library) = try makeLibrary("lib-trash-record")
            defer { withExtendedLifetime(scratch) {} }
            _ = try await library.store.createFolder(named: "Term", in: "")
            let item = try await library.store.createNotebook(named: "Essay", in: "Term")
            let entry = try await library.trash(at: item.relativePath)
            let origin = library.store.trashRoot.appendingPathComponent(entry.id).appendingPathComponent("origin.json")
            if record == "zero bytes" {
                try Data().write(to: origin)
            } else {
                var object = try jsonObject(Data(contentsOf: origin))
                object["formatVersion"] = TrashOrigin.currentFormatVersion + 1
                try jsonData(object).write(to: origin)
            }

            // Alone in the trash, so the listing is all that Empty counts.
            let listed = try await library.store.listTrash()
            #expect(listed.map(\.id) == [entry.id], "\(record)")
            let refused = try #require(listed.first)
            #expect(refused.name == "Essay")
            #expect(refused.kind == .notebook)
            #expect(refused.notebookID == item.notebookID)
            guard case .failure(let fault) = refused.origin else {
                Issue.record("\(record): an unreadable record must be the entry's fault")
                continue
            }
            #expect(fault.description.hasPrefix("origin.json cannot be read: "), "\(record)")

            // Where it came from is what the record could not say, so it
            // lands at the root, suffixed when the name is taken.
            _ = try await library.store.createNotebook(named: "Essay", in: "")
            let recovered = try await library.store.recover(refused)
            #expect(recovered.relativePath == "Essay (1).tubernotes", "\(record)")
            #expect(recovered.notebookID == item.notebookID)
            #expect(try await library.store.listTrash().isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: library.store.trashRoot.path).isEmpty)
        }
    }

    @Test("A notebook whose index cannot be read is trashed under a fresh name, with no identity invented")
    func unreadableIndexTrashesWithNoInventedID() async throws {
        let (scratch, library) = try makeLibrary("lib-trash-unreadable")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Torn", in: "")
        let id = try #require(item.notebookID)
        try Data("{".utf8).write(to: PackageLayout(root: library.store.url(of: item.relativePath)).indexURL)

        let entry = try await library.trash(at: item.relativePath)
        #expect(entry.notebookID == nil)
        #expect(entry.id != id.description)
        #expect(try await library.store.listTrash().map(\.notebookID) == [nil])
    }

    /// Every fault a dry run of `act` reaches: the Nth stage, publish or
    /// directory sync failing, for each N it counted.
    static func faultsReached(
        by act: (LibraryStore) async throws -> Void
    ) async throws -> (faults: [FaultingFileSystem.Fault], counts: FaultingFileSystem.Counts) {
        let scratch = try Scratch("lib-dry-run")
        let dry = FaultingFileSystem(faults: [])
        try await act(LibraryStore(base: scratch.root, fileSystem: dry))
        let counts = dry.counts
        let faults: [FaultingFileSystem.Fault] = (1...counts.stages).map { .failStage(nth: $0) }
            + (1...counts.publishes).map { .failPublish(nth: $0) }
            + (1...counts.syncs).map { .failSync(nth: $0) }
        return (faults, counts)
    }

    @Test("A folder create failing at any stage, publish or sync leaves no folder, or the folder with its sidecar")
    func folderAppearsOnlyWithItsSidecar() async throws {
        let (faults, counts) = try await Self.faultsReached { _ = try await $0.createFolder(named: "Term", in: "") }
        for fault in faults {
            let (scratch, library) = try makeLibrary("lib-folder-fault")
            defer { withExtendedLifetime(scratch) {} }

            let store = try faulting(scratch, fault)
            await #expect(throws: LibraryError.self, "\(fault)") { try await store.createFolder(named: "Term", in: "") }
            // Only the sync after the publish meets a folder already listed.
            let published = fault == .failSync(nth: counts.syncs)
            let listed = try await library.store.list(folder: "")
            #expect(listed.map(\.name) == (published ? ["Term"] : []), "\(fault)")
            #expect(listed.allSatisfy { $0.folderID != nil }, "\(fault)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: library.store.stagingRoot.path).isEmpty, "\(fault)")
        }
    }

    @Test("A notebook create interrupted before its publish leaves nothing listed and the name free")
    func createInterruptedLeavesNothingListed() async throws {
        let (faults, counts) = try await Self.faultsReached { _ = try await $0.createNotebook(named: "Essay", in: "") }
        for fault in faults {
            let (scratch, library) = try makeLibrary("lib-create-fault")
            defer { withExtendedLifetime(scratch) {} }

            let store = try faulting(scratch, fault)
            await #expect(throws: LibraryError.self, "\(fault)") { try await store.createNotebook(named: "Essay", in: "") }
            let published = fault == .failSync(nth: counts.syncs)
            let listed = try await library.store.list(folder: "")
            #expect(listed.map(\.name) == (published ? ["Essay"] : []), "\(fault)")
            #expect(listed.allSatisfy { $0.notebookID != nil }, "\(fault)")
            let held = try FileManager.default.contentsOfDirectory(atPath: library.store.notebooksRoot.path)
            #expect(held == (published ? ["Essay.tubernotes"] : []), "\(fault)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: library.store.stagingRoot.path).isEmpty, "\(fault)")
            if !published {
                #expect(try await library.store.createNotebook(named: "Essay", in: "").notebookID != nil, "\(fault)")
            }
        }

        // Under a taken name the landing meets `Essay` and goes on to claim
        // `Essay (1)`; failing that publish leaves the first notebook alone.
        let (scratch, library) = try makeLibrary("lib-create-fault-taken")
        defer { withExtendedLifetime(scratch) {} }
        _ = try await library.store.createNotebook(named: "Essay", in: "")
        let store = try faulting(scratch, .failPublish(nth: counts.publishes + 1))
        await #expect(throws: LibraryError.self) { try await store.createNotebook(named: "Essay", in: "") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.store.notebooksRoot.path) == ["Essay.tubernotes"])
        #expect(try stagingIsEmpty(library))
    }

    @Test("A landing whose directory sync fails throws, and leaves the item at its old path or its new one")
    func aLandingThatFailsToSyncThrows() async throws {
        // A rename syncs the one directory it stays in. A move and a recovery
        // sync the one they leave, then the one they enter; a trash does too,
        // after the sync that commits its origin.json.
        let landings = [("rename", 1), ("move", 1), ("move", 2), ("recover", 1), ("recover", 2), ("trash", 2), ("trash", 3)]
        for (landing, nth) in landings {
            let (scratch, library) = try makeLibrary("lib-landing-sync")
            defer { withExtendedLifetime(scratch) {} }
            _ = try await library.store.createFolder(named: "Term", in: "")
            let made = try await library.store.createNotebook(named: "Essay", in: "")
            let id = try #require(made.notebookID)

            let store = try faulting(scratch, .failSync(nth: nth))
            let ends: [String]
            switch landing {
            case "rename":
                ends = [made.relativePath, "Draft.tubernotes"]
                await #expect(throws: LibraryError.self) { try await store.rename(at: made.relativePath, to: "Draft") }
            case "move":
                ends = [made.relativePath, "Term/Essay.tubernotes"]
                await #expect(throws: LibraryError.self) { try await store.move(at: made.relativePath, toFolder: "Term") }
            case "recover":
                let entry = try await library.trash(at: made.relativePath)
                ends = ["Trash/\(entry.id)", made.relativePath]
                await #expect(throws: LibraryError.self) { try await store.recover(entry) }
            default:
                ends = [made.relativePath, "Trash/\(id)"]
                await #expect(throws: LibraryError.self) { try await store.trash(at: made.relativePath) }
            }
            let live = try await library.store.listTree(under: "").filter { $0.notebookID == id }.map(\.relativePath)
            let trashed = try await library.store.listTrash().filter { $0.notebookID == id }.map { "Trash/\($0.id)" }
            let places = live + trashed
            #expect(places.count == 1 && ends.contains(places[0]), "\(landing), sync \(nth): \(places)")
        }
    }

    // MARK: The ladder

    /// Rewrites the package's index in the shape `oneStepUp` reads.
    func writeOlderVersion(of item: TNLibrary.LibraryItem, in library: Library) throws {
        let indexURL = PackageLayout(root: library.store.url(of: item.relativePath)).indexURL
        var object = try jsonObject(Data(contentsOf: indexURL))
        object["formatVersion"] = NotebookIndex.currentFormatVersion - 1
        object["title"] = "Physics"
        try jsonData(object).write(to: indexURL)
    }

    /// Every file under `root`, by its path inside it.
    func files(under root: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                found[path] = try Data(contentsOf: url)
            }
        }
        return found
    }

    func formatVersion(of item: TNLibrary.LibraryItem, in library: Library) throws -> Int? {
        try jsonObject(Data(contentsOf: PackageLayout(root: library.store.url(of: item.relativePath)).indexURL))["formatVersion"] as? Int
    }

    func stagingIsEmpty(_ library: Library) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: library.store.stagingRoot.path).isEmpty
    }

    @Test("An older notebook is migrated on open: it opens with its identity and ink, and its index on disk is current")
    func olderPackageMigratesOnOpen() async throws {
        let (scratch, library) = try makeLibrary("lib-migrate", ladder: [oneStepUp])
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Physics", in: "")
        guard case .opened(let written) = await library.checkout(item.relativePath, schedule: fast) else { Issue.record("open failed"); return }
        let page = written.pageIDs[0]
        written.windowChanged(to: [page])
        try await waitUntil { written.state(of: page)?.content != nil }
        written.inkChanged(on: page, Ink.drawing(strokes: 4), echoOf: nil)
        #expect(await written.close() == .clean)
        library.release(item.relativePath)
        try writeOlderVersion(of: item, in: library)
        await #expect(throws: FormatFault.olderFormat(found: NotebookIndex.currentFormatVersion - 1)) {
            try await PackageStore(root: library.store.url(of: item.relativePath)).load()
        }

        guard case .opened(let migrated) = await library.checkout(item.relativePath, schedule: fast) else {
            Issue.record("an older notebook must open")
            return
        }
        #expect(migrated.notebookID == item.notebookID)
        #expect(await migrated.close() == .clean)
        library.release(item.relativePath)
        let index = try jsonObject(Data(contentsOf: PackageLayout(root: library.store.url(of: item.relativePath)).indexURL))
        #expect(index["formatVersion"] as? Int == Int(NotebookIndex.currentFormatVersion))
        #expect(index["title"] == nil)
        let bytes = try await PackageStore(root: library.store.url(of: item.relativePath)).loadPage(page)
        #expect(bytes.faults.isEmpty)
        #expect(try PKDrawing(data: try #require(bytes.inkArchive)).strokes.count == 4)
        #expect(try stagingIsEmpty(library))
    }

    @Test("A migration failing at any stage, publish, sync or exchange, or in its step, refuses the open and leaves the original")
    func aFaultAtEachPhaseLeavesTheOriginal() async throws {
        let dry = FaultingFileSystem(faults: [])
        do {
            let (scratch, library) = try makeLibrary("lib-migrate-dry")
            defer { withExtendedLifetime(scratch) {} }
            let item = try await library.store.createNotebook(named: "Physics", in: "")
            try writeOlderVersion(of: item, in: library)
            try await LibraryStore(base: scratch.root, fileSystem: dry, ladder: [oneStepUp]).upgradePackage(at: item.relativePath)
        }
        let counts = dry.counts
        #expect(counts.stages == 1 && counts.publishes == 1 && counts.exchanges == 1)
        let faults: [FaultingFileSystem.Fault] = [.failStage(nth: 1), .failPublish(nth: 1), .failExchange(nth: 1)]
            + (1...counts.syncs).map { .failSync(nth: $0) }
        let cases: [(name: String, faults: [FaultingFileSystem.Fault], ladder: [MigrationStep])] = faults.map { ("\($0)", [$0], [oneStepUp]) } + [
            ("a step that throws", [], [{ _, _ in throw FormatFault.corruptJSON("the step's own fault") }]),
            ("a step that breaks the index", [], [{ root, fileSystem in
                try fileSystem.writeAtomically(Data("{".utf8), to: root.appendingPathComponent("notebook.json"), syncing: root)
            }]),
        ]
        for (name, faults, ladder) in cases {
            let (scratch, library) = try makeLibrary("lib-migrate-fault")
            defer { withExtendedLifetime(scratch) {} }
            let item = try await library.store.createNotebook(named: "Physics", in: "")
            try writeOlderVersion(of: item, in: library)
            let live = library.store.url(of: item.relativePath)
            let original = try files(under: live)

            let faulting = Library(store: try LibraryStore(base: scratch.root, fileSystem: FaultingFileSystem(faults: faults), ladder: ladder))
            let outcome = await faulting.checkout(item.relativePath)
            guard case .failed(let error) = outcome else { Issue.record("\(name): the open must be refused, got \(outcome)"); continue }
            if name == "a step that throws" { #expect(error == .format(.corruptJSON("the step's own fault"))) }
            // Only the sync after the exchange meets the package already swapped.
            if faults == [.failSync(nth: counts.syncs)] {
                #expect(try formatVersion(of: item, in: library) == Int(NotebookIndex.currentFormatVersion), "\(name)")
            } else {
                #expect(try files(under: live) == original, "\(name)")
            }
            _ = try LibraryStore(base: scratch.root)
            #expect(try stagingIsEmpty(library), "\(name)")
        }
    }

    @Test("Staging is swept when the store starts, and nothing listed goes with it")
    func stagingIsSweptAtLaunch() async throws {
        let (scratch, library) = try makeLibrary("lib-sweep")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Physics", in: "")
        // What a process that died mid-duplicate or mid-migration leaves: a
        // whole package, and a loose staged file.
        let staging = library.store.stagingRoot
        try FileManager.default.copyItem(at: library.store.url(of: item.relativePath), to: staging.appendingPathComponent(UUID().uuidString))
        try Data("torn".utf8).write(to: staging.appendingPathComponent("tmp-loose"))
        #expect(try !stagingIsEmpty(library))

        let restarted = try LibraryStore(base: scratch.root)
        #expect(try stagingIsEmpty(library))
        #expect(try await restarted.list(folder: "").map(\.notebookID) == [item.notebookID])
    }

    @Test("A newer notebook is refused by its version, on open and on duplicate, and is left byte for byte")
    func newerPackageIsRefusedUntouched() async throws {
        let (scratch, library) = try makeLibrary("lib-migrate-newer", ladder: [oneStepUp])
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Physics", in: "")
        let live = library.store.url(of: item.relativePath)
        let indexURL = PackageLayout(root: live).indexURL
        var object = try jsonObject(Data(contentsOf: indexURL))
        let newer = NotebookIndex.currentFormatVersion + 1
        object["formatVersion"] = newer
        try jsonData(object).write(to: indexURL)
        let original = try files(under: live)

        guard case .failed(.format(.newerFormat(found: newer))) = await library.checkout(item.relativePath) else {
            Issue.record("a newer notebook must refuse by its version")
            return
        }
        await #expect(throws: LibraryError.format(.newerFormat(found: newer))) { try await library.duplicateNotebook(at: item.relativePath) }
        #expect(try files(under: live) == original)
        #expect(try await library.store.list(folder: "").map(\.relativePath) == [item.relativePath])
        #expect(try stagingIsEmpty(library))
    }

    @Test("Duplicating an older notebook migrates the copy, and the original stays at its version")
    func duplicateOfAnOlderPackageMigratesTheCopy() async throws {
        let (scratch, library) = try makeLibrary("lib-migrate-duplicate", ladder: [oneStepUp])
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Physics", in: "")
        try writeOlderVersion(of: item, in: library)
        let original = try files(under: library.store.url(of: item.relativePath))

        let copy = try await library.duplicateNotebook(at: item.relativePath)
        let loaded = try await PackageStore(root: library.store.url(of: copy.relativePath)).load()
        #expect(loaded.index.notebookID != item.notebookID)
        #expect(try formatVersion(of: copy, in: library) == Int(NotebookIndex.currentFormatVersion))
        #expect(try files(under: library.store.url(of: item.relativePath)) == original)
        #expect(try stagingIsEmpty(library))
    }

    @Test("A deleted page's files survive the save and go on the background pass")
    func compactingOpenPackages() async throws {
        let (scratch, library) = try makeLibrary("lib-compact")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Notes", in: "")
        guard case .opened(let notebook) = await library.checkout(item.relativePath, schedule: fast) else {
            Issue.record("open failed"); return
        }
        let kept = notebook.pageIDs[0]
        let doomed = notebook.appendPage(after: kept)
        await notebook.flush()
        let layout = PackageLayout(root: library.store.url(of: item.relativePath))
        let fs = FileManager.default
        #expect(fs.fileExists(atPath: layout.pageURL(doomed).path))

        notebook.deletePage(doomed)
        await notebook.flush()
        #expect(notebook.pageIDs == [kept])
        #expect(fs.fileExists(atPath: layout.pageURL(doomed).path), "a save deletes nothing")
        await library.compactOpenPackages()
        #expect(fs.fileExists(atPath: layout.pageURL(doomed).path), "younger than a day, so kept")

        try scratch.backdate(layout.pageURL(doomed), by: 2 * 86_400)
        await library.compactOpenPackages()
        #expect(!fs.fileExists(atPath: layout.pageURL(doomed).path))
        #expect(fs.fileExists(atPath: layout.pageURL(kept).path))
        #expect(await notebook.close() == .clean)
        library.release(item.relativePath)
    }

    @Test("A package nobody has open is not swept")
    func compactSkipsClosedPackages() async throws {
        let (scratch, library) = try makeLibrary("lib-compact-closed")
        defer { withExtendedLifetime(scratch) {} }
        let item = try await library.store.createNotebook(named: "Closed", in: "")
        let layout = PackageLayout(root: library.store.url(of: item.relativePath))
        let orphan = layout.pageURL(PageID())
        try Data([1]).write(to: orphan)
        try scratch.backdate(orphan, by: 2 * 86_400)
        #expect(await library.compactOpenPackages().isEmpty)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("Each open package is swept once, and reports what it removed and kept")
    func compactReportsEachOpenPackage() async throws {
        let (scratch, library) = try makeLibrary("lib-compact-each")
        defer { withExtendedLifetime(scratch) {} }
        let one = try await library.store.createNotebook(named: "One", in: "")
        let two = try await library.store.createNotebook(named: "Two", in: "")
        guard case .opened(let first) = await library.checkout(one.relativePath, schedule: fast),
              case .opened(let second) = await library.checkout(two.relativePath, schedule: fast) else {
            Issue.record("open failed"); return
        }
        let orphan = PackageLayout(root: library.store.url(of: two.relativePath)).pageURL(PageID())
        try Data([1]).write(to: orphan)
        try scratch.backdate(orphan, by: 2 * 86_400)

        let reports = await library.compactOpenPackages()
        #expect(reports.count == 2)
        #expect(reports[first.notebookID]?.removed == [])
        #expect(reports[second.notebookID]?.removed == [orphan.lastPathComponent])
        #expect(await first.close() == .clean)
        #expect(await second.close() == .clean)
        library.release(one.relativePath)
        library.release(two.relativePath)
    }
}
