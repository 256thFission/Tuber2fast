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

    var trashURL: URL { root.appendingPathComponent("Trash") }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - The Trash screen's model over a real store

@Suite("Trash screen model", .serialized)
@MainActor
struct TrashScreenModelTests {
    @Test("Trash, list, recover: the item returns to its origin")
    func trashListRecoverToOrigin() async throws {
        let scratch = try LibraryScratch("recover-origin")
        _ = try await scratch.library.createFolder(
            named: "Chinese", in: "", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createDocumentDirectory(named: "Vocab", in: "Chinese")
        try await scratch.library.trashItem(at: "Chinese/Vocab.tubernotes")

        let model = TrashListingModel(library: scratch.library)
        await model.refresh()
        #expect(model.items.count == 1)
        let entry = try #require(model.items.first)
        #expect(entry.name == "Vocab")
        #expect(entry.kind == .document)
        #expect(entry.originPath == "Chinese")

        await model.recover(entry)
        #expect(model.items.isEmpty)
        let origin = try await scratch.library.listFolder("Chinese")
        #expect(origin.items.map(\.id) == ["Chinese/Vocab.tubernotes"])
    }

    @Test("Recover with the origin gone lands in the root, never a recreated chain")
    func recoverWithOriginGoneLandsInRoot() async throws {
        let scratch = try LibraryScratch("recover-root")
        _ = try await scratch.library.createFolder(
            named: "Chinese", in: "", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createDocumentDirectory(named: "Vocab", in: "Chinese")
        try await scratch.library.trashItem(at: "Chinese/Vocab.tubernotes")
        // The origin folder itself is trashed, so the sidecar's path now
        // names nothing in the tree.
        try await scratch.library.trashItem(at: "Chinese")

        let model = TrashListingModel(library: scratch.library)
        await model.refresh()
        let doc = try #require(model.items.first { $0.name == "Vocab" })
        await model.recover(doc)

        let root = try await scratch.library.listFolder("")
        #expect(root.items.contains { $0.id == "Vocab.tubernotes" })
    }

    @Test("Delete Permanently removes the one entry, sidecar included, and leaves the rest")
    func deletePermanentlyRemoves() async throws {
        let scratch = try LibraryScratch("delete-one")
        _ = try await scratch.library.createDocumentDirectory(named: "Keep", in: "")
        _ = try await scratch.library.createDocumentDirectory(named: "Drop", in: "")
        try await scratch.library.trashItem(at: "Keep.tubernotes")
        try await scratch.library.trashItem(at: "Drop.tubernotes")

        let model = TrashListingModel(library: scratch.library)
        await model.refresh()
        let dropped = try #require(model.items.first { $0.name == "Drop" })
        await model.deletePermanently(dropped)

        #expect(model.items.map(\.name) == ["Keep"])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: scratch.trashURL.path)
        #expect(!remaining.contains { $0.hasPrefix("Drop") })
    }

    @Test("Empty Trash sweeps every entry and every sidecar")
    func emptyTrashSweeps() async throws {
        let scratch = try LibraryScratch("empty-trash")
        _ = try await scratch.library.createDocumentDirectory(named: "Doc", in: "")
        _ = try await scratch.library.createFolder(
            named: "Folder", in: "", decoration: FolderDecoration()
        )
        try await scratch.library.trashItem(at: "Doc.tubernotes")
        try await scratch.library.trashItem(at: "Folder")

        let model = TrashListingModel(library: scratch.library)
        await model.refresh()
        #expect(model.items.count == 2)

        await model.emptyTrash()
        #expect(model.items.isEmpty)
        let leftover = try FileManager.default.contentsOfDirectory(atPath: scratch.trashURL.path)
        #expect(leftover.isEmpty)
    }
}

// MARK: - The move picker's listing and the move itself

@Suite("Move picker and move semantics", .serialized)
@MainActor
struct LibraryMoveTests {
    @Test("The destination listing offers folders only, never the moved folder or its subtree")
    func destinationsExcludeSelfAndDescendants() async throws {
        let scratch = try LibraryScratch("destinations")
        _ = try await scratch.library.createFolder(
            named: "Moving", in: "", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createFolder(
            named: "Inside", in: "Moving", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createFolder(
            named: "Elsewhere", in: "", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createDocumentDirectory(named: "A Doc", in: "")

        // Root level: the moved folder and the document drop out; the
        // unrelated folder survives.
        let root = try await scratch.library.listFolder("")
        let rootDestinations = MovePickerSheet.destinationFolders(
            in: root.items, excluding: "Moving"
        )
        #expect(rootDestinations.map(\.id) == ["Elsewhere"])

        // Inside the moved folder: everything is its own descendant, so the
        // level is empty — the picker cannot offer the inside of the move.
        let inside = try await scratch.library.listFolder("Moving")
        let insideDestinations = MovePickerSheet.destinationFolders(
            in: inside.items, excluding: "Moving"
        )
        #expect(insideDestinations.isEmpty)
    }

    @Test("Move updates the listing and the favorite follows to the new path")
    func moveCarriesFavorite() async throws {
        let scratch = try LibraryScratch("move-favorite")
        _ = try await scratch.library.createDocumentDirectory(named: "Vocab", in: "")
        try await scratch.library.setFavorite(true, at: "Vocab.tubernotes")
        _ = try await scratch.library.createFolder(
            named: "Target", in: "", decoration: FolderDecoration()
        )

        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        let doc = try #require(model.items.first { $0.name == "Vocab" })
        await model.move(doc, toFolder: "Target")

        // The source listing no longer holds it; no collision, so no banner.
        #expect(model.items.map(\.name) == ["Target"])
        #expect(model.mutationBanner == nil)

        let destination = try await scratch.library.listFolder("Target")
        let moved = try #require(destination.items.first)
        #expect(moved.id == "Target/Vocab.tubernotes")
        #expect(moved.isFavorite)
        #expect(try await scratch.library.listFavorites().map(\.id) == ["Target/Vocab.tubernotes"])
    }

    @Test("A collision suffix on move is surfaced in the banner, never silent")
    func moveCollisionSurfaces() async throws {
        let scratch = try LibraryScratch("move-collision")
        _ = try await scratch.library.createDocumentDirectory(named: "Vocab", in: "")
        _ = try await scratch.library.createFolder(
            named: "Target", in: "", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createDocumentDirectory(named: "Vocab", in: "Target")

        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        let doc = try #require(model.items.first { $0.name == "Vocab" })
        await model.move(doc, toFolder: "Target")

        let destination = try await scratch.library.listFolder("Target")
        #expect(Set(destination.items.map(\.name)) == ["Vocab", "Vocab 2"])
        let banner = try #require(model.mutationBanner)
        #expect(banner.contains("Vocab 2"))
    }
}
