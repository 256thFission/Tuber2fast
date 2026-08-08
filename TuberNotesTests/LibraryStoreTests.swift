import Foundation
import Testing
@testable import TuberModel
@testable import TuberStore

/// A unique library root per test, removed when the test ends.
///
/// Mirrors `TestScratch`, one storage level up, and deliberately does not
/// touch it: that class means "a scratch document", this one means "a scratch
/// library". `container` stands in for Application Support — the library root
/// is a child of it, exactly the shape `defaultRootURL()` produces, so the
/// adoption path (a sibling of the root) is exercised as production runs it.
private final class LibraryScratch {
    let container: URL
    let root: URL
    let store: LibraryStore

    var documentsURL: URL { root.appendingPathComponent("Documents") }
    var trashURL: URL { root.appendingPathComponent("Trash") }
    var stagingURL: URL { root.appendingPathComponent(".staging") }

    init(_ label: String = "library") throws {
        container = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tubernotes-\(label)-\(UUID().uuidString)")
        root = container.appendingPathComponent("TuberLibrary")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        store = LibraryStore(rootURL: root)
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: container)
        } catch CocoaError.fileNoSuchFile {
            // Nothing to remove.
        } catch {
            // Cleanup, not an assertion: a leaked temp directory is the
            // simulator's problem and failing here would blame the wrong test.
        }
    }

    /// A fresh store each time, deliberately: it defeats the once-per-instance
    /// adoption/sweep flag and the prefs cache, so assertions about disk are
    /// about disk.
    func freshStore() -> LibraryStore { LibraryStore(rootURL: root) }

    func itemURL(_ relativePath: String) -> URL {
        documentsURL.appendingPathComponent(relativePath)
    }

    /// The pre-library document at the old fixed path: a sibling of the root,
    /// where `DocumentStore.defaultDirectoryURL()` puts it.
    func plantLegacyDocument() throws {
        let source = container.appendingPathComponent("JustACanvas.tubernotes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([0x01, 0x02]).write(to: source.appendingPathComponent("document.plist"))
    }

    // MARK: - Derived-date plumbing

    /// Far in the past and exact, as `TestScratch.frozen`: `== frozen` means
    /// *not touched*, not *touched within a clock's resolution*.
    static let frozen = Date(timeIntervalSinceReferenceDate: 0)

    static let interiorPaths = ["document.plist", "pages", "layers", "assets"]

    /// Backdates the package's interior paths (and, when freezing everything,
    /// the package directory itself) so the next listing's derived modified
    /// date is exactly the participant a save shape refreshed.
    func freezeInteriorDates(ofPackage packageURL: URL, except participant: String? = nil) throws {
        for name in Self.interiorPaths where name != participant {
            let url = packageURL.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.setAttributes(
                [.modificationDate: Self.frozen],
                ofItemAtPath: url.path
            )
        }
        if participant == nil {
            try FileManager.default.setAttributes(
                [.modificationDate: Self.frozen],
                ofItemAtPath: packageURL.path
            )
        }
    }

    func modifiedAt(of id: String, inFolder folder: String = "", store: LibraryStore) async throws -> Date {
        let listing = try await store.listFolder(folder)
        return try #require(listing.items.first { $0.id == id }).modifiedAt
    }

    func inkLayers(_ data: Data, layerID: UUID = UUID()) -> [LayerEnvelope] {
        [
            LayerEnvelope(
                layerID: layerID,
                kind: .ink,
                payload: data,
                pageSpaceTransform: .identity
            )
        ]
    }

    func index(documentID: UUID, pageIDs: [UUID], currentPageIndex: Int = 0) -> DocumentIndex {
        DocumentIndex(
            formatVersion: DocumentIndex.currentFormatVersion,
            documentID: documentID,
            pages: pageIDs.map { PageRecord(id: $0, geometry: .canonical) },
            currentPageIndex: currentPageIndex
        )
    }
}

@Suite("Library store")
struct LibraryStoreTests {

    // MARK: - Listing

    @Test("Create and list round-trips folders and documents, with directory facts")
    func createAndListRoundTrip() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        let decoration = FolderDecoration(color: "#FF0000", icon: "book")
        let folder = try await store.createFolder(named: "Chinese", in: "", decoration: decoration)
        let document = try await store.createDocumentDirectory(named: "Bayes Exam", in: "")
        _ = try await store.createDocumentDirectory(named: "Vocab", in: "Chinese")

        #expect(folder.id == "Chinese")
        #expect(document.id == "Bayes Exam.tubernotes")
        #expect(document.name == "Bayes Exam")
        #expect(document.kind == .document)

        let rootListing = try await scratch.freshStore().listFolder("")
        #expect(rootListing.degradations.isEmpty)
        #expect(Set(rootListing.items.map(\.id)) == ["Chinese", "Bayes Exam.tubernotes"])
        let listedFolder = try #require(rootListing.items.first { $0.id == "Chinese" })
        #expect(listedFolder.kind == .folder(decoration))
        #expect(!listedFolder.decorationDegraded)
        let listedDocument = try #require(rootListing.items.first { $0.kind == .document })
        // A reserved package with no interior files yet: every interior stat
        // is ENOENT, tolerated, and the date falls back to the directory's.
        #expect(listedDocument.createdAt > .distantPast)
        #expect(listedDocument.modifiedAt > .distantPast)

        // IDs are library-relative from the Documents root, not folder-local.
        let nested = try await store.listFolder("Chinese")
        #expect(nested.items.map(\.id) == ["Chinese/Vocab.tubernotes"])
        #expect(nested.items.map(\.name) == ["Vocab"])
    }

    @Test("Listing a document path is not a folder; listing nowhere is not found")
    func listingRefusals() async throws {
        let scratch = try LibraryScratch()
        _ = try await scratch.store.createDocumentDirectory(named: "A", in: "")
        await #expect(throws: LibraryError.notAFolder("A.tubernotes")) {
            _ = try await scratch.store.listFolder("A.tubernotes")
        }
        await #expect(throws: LibraryError.itemNotFound("Nope")) {
            _ = try await scratch.store.listFolder("Nope")
        }
    }

    @Test("A root that cannot enumerate is refused, never shown empty")
    func enumerationFailureIsRefused() async throws {
        let scratch = try LibraryScratch()
        try FileManager.default.createDirectory(at: scratch.root, withIntermediateDirectories: true)
        // Documents is a FILE, so the listing cannot happen — and must say so.
        try Data("in the way".utf8).write(to: scratch.documentsURL)
        do {
            _ = try await scratch.store.listFolder("")
            Issue.record("a listing over a file reported success")
        } catch LibraryError.enumerationFailed {
            // The refused-folder state, as designed.
        }
    }

    @Test("Foreign files are ignored and reported, never listed and never deleted")
    func foreignFilesAreInert() async throws {
        let scratch = try LibraryScratch()
        _ = try await scratch.store.createDocumentDirectory(named: "A", in: "")
        let stray = scratch.documentsURL.appendingPathComponent("junk.txt")
        try Data("stray".utf8).write(to: stray)

        let listing = try await scratch.freshStore().listFolder("")
        #expect(listing.items.map(\.id) == ["A.tubernotes"])
        #expect(listing.degradations.contains { $0.contains("junk.txt") })
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    // MARK: - The name gate

    private func expectInvalidName(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("the name gate accepted a name it must refuse")
        } catch LibraryError.invalidName {
            // Refused, with a reason.
        } catch {
            Issue.record("the gate threw \(error), not invalidName")
        }
    }

    @Test("The name gate refuses each class of bad name, and only those")
    func nameGateRefusals() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store

        await expectInvalidName { _ = try await store.createFolder(named: "", in: "", decoration: FolderDecoration()) }
        await expectInvalidName { _ = try await store.createFolder(named: "   ", in: "", decoration: FolderDecoration()) }
        await expectInvalidName { _ = try await store.createDocumentDirectory(named: "a/b", in: "") }
        await expectInvalidName { _ = try await store.createDocumentDirectory(named: "a:b", in: "") }
        await expectInvalidName { _ = try await store.createFolder(named: ".hidden", in: "", decoration: FolderDecoration()) }
        await expectInvalidName { _ = try await store.createFolder(named: "Fake.tubernotes", in: "", decoration: FolderDecoration()) }
        await expectInvalidName { _ = try await store.createDocumentDirectory(named: "x.origin.plist backup", in: "") }

        // The 255-byte budget holds headroom for the appended suffix and a
        // two-digit collision suffix, so the boundary differs by kind.
        await expectInvalidName {
            _ = try await store.createFolder(named: String(repeating: "a", count: 253), in: "", decoration: FolderDecoration())
        }
        _ = try await store.createFolder(named: String(repeating: "a", count: 252), in: "", decoration: FolderDecoration())
        await expectInvalidName {
            _ = try await store.createDocumentDirectory(named: String(repeating: "b", count: 242), in: "")
        }
        _ = try await store.createDocumentDirectory(named: String(repeating: "b", count: 241), in: "")

        // A rename passes the same gate.
        await expectInvalidName { _ = try await store.renameItem(at: "\(String(repeating: "a", count: 252))", to: "c/d") }
    }

    // MARK: - Collisions

    @Test("A create collision suffixes by asking the file system")
    func createCollisionSuffixes() async throws {
        let scratch = try LibraryScratch()
        let first = try await scratch.store.createDocumentDirectory(named: "A", in: "")
        let second = try await scratch.store.createDocumentDirectory(named: "A", in: "")
        let third = try await scratch.store.createDocumentDirectory(named: "A", in: "")
        #expect(first.id == "A.tubernotes")
        #expect(second.id == "A 2.tubernotes")
        #expect(third.id == "A 3.tubernotes")
        #expect(second.name == "A 2")

        let folder = try await scratch.store.createFolder(named: "F", in: "", decoration: FolderDecoration())
        let folder2 = try await scratch.store.createFolder(named: "F", in: "", decoration: FolderDecoration())
        #expect(folder.id == "F")
        #expect(folder2.id == "F 2")
    }

    @Test("Rename lands, and a rename collision suffixes")
    func renameAndCollision() async throws {
        let scratch = try LibraryScratch()
        _ = try await scratch.store.createDocumentDirectory(named: "A", in: "")
        _ = try await scratch.store.createDocumentDirectory(named: "C", in: "")

        let renamed = try await scratch.store.renameItem(at: "A.tubernotes", to: "B")
        #expect(renamed.id == "B.tubernotes")
        #expect(!FileManager.default.fileExists(atPath: scratch.itemURL("A.tubernotes").path))

        let collided = try await scratch.store.renameItem(at: "B.tubernotes", to: "C")
        #expect(collided.id == "C 2.tubernotes")

        await #expect(throws: LibraryError.itemNotFound("Gone.tubernotes")) {
            _ = try await scratch.store.renameItem(at: "Gone.tubernotes", to: "X")
        }
    }

    // MARK: - Move and favorites

    @Test("A colliding move suffixes, and the favorites rewrite uses the post-suffix path")
    func moveRewritesFavoritesToPostSuffixPath() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        _ = try await store.createDocumentDirectory(named: "A", in: "")
        _ = try await store.createFolder(named: "F", in: "", decoration: FolderDecoration())
        _ = try await store.createDocumentDirectory(named: "A", in: "F")
        try await store.setFavorite(true, at: "A.tubernotes")

        let moved = try await store.moveItem(at: "A.tubernotes", toFolder: "F")
        #expect(moved.id == "F/A 2.tubernotes")
        let favorites = try await store.listFavorites().map(\.id)
        #expect(favorites == ["F/A 2.tubernotes"])
        let destination = try await store.listFolder("F")
        #expect(destination.items.count == 2)

        await #expect(throws: LibraryError.itemNotFound("Gone")) {
            _ = try await store.moveItem(at: "Gone", toFolder: "")
        }
    }

    @Test("Renaming an ancestor carries every starred descendant by prefix")
    func ancestorRenameRewritesFavoritesByPrefix() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        _ = try await store.createFolder(named: "F", in: "", decoration: FolderDecoration())
        _ = try await store.createDocumentDirectory(named: "V", in: "F")
        try await store.setFavorite(true, at: "F")
        try await store.setFavorite(true, at: "F/V.tubernotes")

        _ = try await store.renameItem(at: "F", to: "G")

        let favorites = try await store.listFavorites().map(\.id)
        #expect(favorites == ["G", "G/V.tubernotes"])
    }

    @Test("A folder never moves into its own subtree")
    func moveIntoOwnSubtreeIsRefused() async throws {
        let scratch = try LibraryScratch()
        _ = try await scratch.store.createFolder(named: "F", in: "", decoration: FolderDecoration())
        _ = try await scratch.store.createFolder(named: "Sub", in: "F", decoration: FolderDecoration())

        await #expect(throws: LibraryError.destinationInsideSource) {
            _ = try await scratch.store.moveItem(at: "F", toFolder: "F/Sub")
        }
        await #expect(throws: LibraryError.destinationInsideSource) {
            _ = try await scratch.store.moveItem(at: "F", toFolder: "F")
        }
    }

    @Test("A dangling favorite renders nothing and is pruned only by the next write")
    func danglingFavoritesPruneOnWriteOnly() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        _ = try await store.createDocumentDirectory(named: "A", in: "")
        _ = try await store.createDocumentDirectory(named: "B", in: "")
        try await store.setFavorite(true, at: "A.tubernotes")
        try await store.trashItem(at: "A.tubernotes")

        // The read skips the dangling entry but leaves it on disk.
        let resolved = try await store.listFavorites()
        #expect(resolved.isEmpty)
        let onDisk = try PropertyListDecoder().decode(
            [String].self,
            from: Data(contentsOf: scratch.root.appendingPathComponent("favorites.plist"))
        )
        #expect(onDisk == ["A.tubernotes"])

        // The next write prunes it.
        try await store.setFavorite(true, at: "B.tubernotes")
        let afterWrite = try PropertyListDecoder().decode(
            [String].self,
            from: Data(contentsOf: scratch.root.appendingPathComponent("favorites.plist"))
        )
        #expect(afterWrite == ["B.tubernotes"])
    }

    // MARK: - Trash

    @Test("Trash, list, recover: the origin sidecar is honored and then deleted")
    func trashRecoverHonorsOrigin() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        _ = try await store.createFolder(named: "F", in: "", decoration: FolderDecoration())
        _ = try await store.createDocumentDirectory(named: "V", in: "F")

        try await store.trashItem(at: "F/V.tubernotes")
        let sidecar = scratch.trashURL.appendingPathComponent("V.tubernotes.origin.plist")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))

        let trash = try await store.listTrash()
        let entry = try #require(trash.first)
        #expect(entry.id == "V.tubernotes")
        #expect(entry.name == "V")
        #expect(entry.kind == .document)
        #expect(entry.originPath == "F")
        #expect(abs(entry.deletedAt.timeIntervalSinceNow) < 60)

        let recovered = try await store.recoverItem(named: "V.tubernotes")
        #expect(recovered.id == "F/V.tubernotes")
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        let remaining = try await store.listTrash()
        #expect(remaining.isEmpty)
    }

    @Test("Two same-named items trash without crossing origins, post-suffix")
    func trashCollisionKeepsOriginsDistinct() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        _ = try await store.createDocumentDirectory(named: "A", in: "")
        _ = try await store.createFolder(named: "F", in: "", decoration: FolderDecoration())
        _ = try await store.createDocumentDirectory(named: "A", in: "F")

        try await store.trashItem(at: "A.tubernotes")
        try await store.trashItem(at: "F/A.tubernotes")

        let byID = Dictionary(
            uniqueKeysWithValues: try await store.listTrash().map { ($0.id, $0) }
        )
        #expect(byID["A.tubernotes"]?.originPath == "")
        #expect(byID["A 2.tubernotes"]?.originPath == "F")

        // The trash suffix was a real rename — tree-as-truth, the directory
        // name is the name — so recover carries it; what the sidecar buys is
        // the origin, and the origin is F, not the other A's root.
        let recovered = try await store.recoverItem(named: "A 2.tubernotes")
        #expect(recovered.id == "F/A 2.tubernotes")
    }

    @Test("A missing origin sidecar recovers to the root")
    func recoverWithoutSidecarGoesToRoot() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        _ = try await store.createFolder(named: "F", in: "", decoration: FolderDecoration())
        _ = try await store.createDocumentDirectory(named: "V", in: "F")
        try await store.trashItem(at: "F/V.tubernotes")
        try FileManager.default.removeItem(
            at: scratch.trashURL.appendingPathComponent("V.tubernotes.origin.plist")
        )

        let recovered = try await store.recoverItem(named: "V.tubernotes")
        #expect(recovered.id == "V.tubernotes")

        await #expect(throws: LibraryError.itemNotFound("Nope.tubernotes")) {
            _ = try await store.recoverItem(named: "Nope.tubernotes")
        }
    }

    @Test("An origin folder that no longer exists recovers to the root")
    func recoverWithGoneOriginGoesToRoot() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        _ = try await store.createFolder(named: "F", in: "", decoration: FolderDecoration())
        _ = try await store.createDocumentDirectory(named: "V", in: "F")
        try await store.trashItem(at: "F/V.tubernotes")
        try await store.trashItem(at: "F")

        let recovered = try await store.recoverItem(named: "V.tubernotes")
        #expect(recovered.id == "V.tubernotes")
    }

    @Test("Delete Permanently removes the item and its sidecar")
    func deletePermanentlyRemovesItemAndSidecar() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        _ = try await store.createDocumentDirectory(named: "A", in: "")
        try await store.trashItem(at: "A.tubernotes")

        try await store.deletePermanently(named: "A.tubernotes")
        let remaining = try await store.listTrash()
        #expect(remaining.isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: scratch.trashURL.path).isEmpty
        )
    }

    @Test("Empty Trash sweeps items and sidecars alike")
    func emptyTrashSweepsSidecars() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        _ = try await store.createDocumentDirectory(named: "A", in: "")
        _ = try await store.createFolder(named: "F", in: "", decoration: FolderDecoration())
        try await store.trashItem(at: "A.tubernotes")
        try await store.trashItem(at: "F")

        try await store.emptyTrash()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: scratch.trashURL.path).isEmpty
        )

        await #expect(throws: LibraryError.itemNotFound("A.tubernotes")) {
            try await store.trashItem(at: "A.tubernotes")
        }
    }

    // MARK: - Corrupt sidecars

    @Test("A corrupt .folder.plist degrades, is set aside, and the evidence survives")
    func corruptFolderPlistDegradesAndIsSetAside() async throws {
        let scratch = try LibraryScratch()
        _ = try await scratch.store.createFolder(
            named: "F", in: "", decoration: FolderDecoration(color: "#00FF00", icon: "star")
        )
        let sidecar = scratch.itemURL("F").appendingPathComponent(".folder.plist")
        let garbage = Data("not a plist at all".utf8)
        try garbage.write(to: sidecar)

        let listing = try await scratch.freshStore().listFolder("")
        let item = try #require(listing.items.first { $0.id == "F" })
        #expect(item.kind == .folder(FolderDecoration()))
        #expect(item.decorationDegraded)
        #expect(!listing.degradations.isEmpty)

        let setAside = scratch.itemURL("F").appendingPathComponent(".folder.plist.corrupt")
        #expect(try Data(contentsOf: setAside) == garbage)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))

        // The next write is the recovery.
        let decoration = FolderDecoration(color: "#0000FF", icon: nil)
        try await scratch.store.setDecoration(decoration, forFolderAt: "F")
        let relisted = try await scratch.freshStore().listFolder("")
        #expect(relisted.items.first { $0.id == "F" }?.kind == .folder(decoration))
    }

    @Test("Corrupt favorites and prefs degrade to their defaults and are set aside")
    func corruptRootSidecarsDegrade() async throws {
        let scratch = try LibraryScratch()
        _ = try await scratch.store.createDocumentDirectory(named: "A", in: "")
        try Data("junk".utf8).write(to: scratch.root.appendingPathComponent("favorites.plist"))
        try Data("junk".utf8).write(to: scratch.root.appendingPathComponent("library.plist"))

        let store = scratch.freshStore()
        let favorites = try await store.listFavorites()
        #expect(favorites.isEmpty)
        let prefs = await store.prefs()
        #expect(prefs == .default)
        #expect(
            FileManager.default.fileExists(
                atPath: scratch.root.appendingPathComponent("favorites.plist.corrupt").path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: scratch.root.appendingPathComponent("library.plist.corrupt").path
            )
        )
    }

    // MARK: - Duplicate and staging

    @Test("Duplicate stages, lands atomically, and torn staging never enumerates")
    func duplicateViaStaging() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        let source = try await store.createDocumentDirectory(named: "A", in: "")
        let documentStore = DocumentStore(directoryURL: store.documentURL(forItemAt: source.id))
        let pageID = UUID()
        let index = scratch.index(documentID: UUID(), pageIDs: [pageID])
        try await documentStore.save(
            index: index,
            pages: [PageWrite(pageID: pageID, layers: scratch.inkLayers(Data([0x0A])))]
        )

        let copy = try await store.duplicateDocument(at: "A.tubernotes")
        #expect(copy.id == "A 2.tubernotes")
        let sourceIndex = try Data(
            contentsOf: scratch.itemURL("A.tubernotes").appendingPathComponent("document.plist")
        )
        let copyIndex = try Data(
            contentsOf: scratch.itemURL("A 2.tubernotes").appendingPathComponent("document.plist")
        )
        #expect(sourceIndex == copyIndex)

        // Torn debris under .staging is invisible to every listing, and the
        // first root listing of a fresh store makes it not exist.
        let torn = scratch.stagingURL.appendingPathComponent("\(UUID().uuidString)/Torn.tubernotes")
        try FileManager.default.createDirectory(at: torn, withIntermediateDirectories: true)
        let listing = try await scratch.freshStore().listFolder("")
        #expect(Set(listing.items.map(\.id)) == ["A.tubernotes", "A 2.tubernotes"])
        #expect(!FileManager.default.fileExists(atPath: scratch.stagingURL.path))
    }

    // MARK: - Adoption

    @Test("The first root listing adopts the pre-library document, idempotently")
    func adoptionIsIdempotent() async throws {
        let scratch = try LibraryScratch()
        try scratch.plantLegacyDocument()

        let first = try await scratch.store.listFolder("")
        #expect(first.items.map(\.id) == ["Just a Canvas.tubernotes"])
        #expect(
            !FileManager.default.fileExists(
                atPath: scratch.container.appendingPathComponent("JustACanvas.tubernotes").path
            )
        )

        // Again on the same store, and again on a fresh one: nothing to do.
        let again = try await scratch.store.listFolder("")
        #expect(again.items.count == 1)
        let fresh = try await scratch.freshStore().listFolder("")
        #expect(fresh.items.count == 1)
    }

    @Test("Adoption suffixes when the adopted name is taken")
    func adoptionCollisionSuffixes() async throws {
        let scratch = try LibraryScratch()
        _ = try await scratch.store.createDocumentDirectory(named: "Just a Canvas", in: "")
        try scratch.plantLegacyDocument()

        let listing = try await scratch.freshStore().listFolder("")
        #expect(
            Set(listing.items.map(\.id))
                == ["Just a Canvas.tubernotes", "Just a Canvas 2.tubernotes"]
        )
    }

    // MARK: - The derived modified date

    /// Every save shape refreshes exactly one of the four interior paths this
    /// derivation stats; each shape is driven through a real `DocumentStore`
    /// and then isolated by re-freezing the other three. If an OS change ever
    /// broke the rename-refreshes-the-directory property, this fails loud
    /// rather than letting date sorts go quietly stale.
    @Test("The derived modified date moves on every save shape, including index-only")
    func derivedModifiedDateTracksEverySaveShape() async throws {
        let scratch = try LibraryScratch()
        let store = scratch.store
        let created = try await store.createDocumentDirectory(named: "Doc", in: "")
        let packageURL = store.documentURL(forItemAt: created.id)
        let documentStore = DocumentStore(directoryURL: packageURL)

        let documentID = UUID()
        let firstPage = UUID()
        let inkLayerID = UUID()
        try await documentStore.save(
            index: scratch.index(documentID: documentID, pageIDs: [firstPage]),
            pages: [
                PageWrite(pageID: firstPage, layers: scratch.inkLayers(Data([0x01]), layerID: inkLayerID))
            ]
        )

        // The control: with all four frozen, the derived date is frozen.
        try scratch.freezeInteriorDates(ofPackage: packageURL)
        #expect(try await scratch.modifiedAt(of: created.id, store: store) == LibraryScratch.frozen)

        func assertShapeMoves(
            participant: String,
            _ shape: () async throws -> Void
        ) async throws {
            try scratch.freezeInteriorDates(ofPackage: packageURL)
            try await shape()
            try scratch.freezeInteriorDates(ofPackage: packageURL, except: participant)
            let date = try await scratch.modifiedAt(of: created.id, store: store)
            #expect(
                date > LibraryScratch.frozen,
                "the \(participant) write did not move the derived date"
            )
        }

        // An ink-only save writes one layer file: layers/ carries the date.
        try await assertShapeMoves(participant: "layers") {
            try await documentStore.save(
                index: scratch.index(documentID: documentID, pageIDs: [firstPage]),
                pages: [
                    PageWrite(
                        pageID: firstPage,
                        layers: scratch.inkLayers(Data([0x02]), layerID: inkLayerID),
                        changedLayerIDs: [inkLayerID]
                    )
                ]
            )
        }

        // An appended page writes a page file: pages/ carries the date.
        let secondPage = UUID()
        try await assertShapeMoves(participant: "pages") {
            try await documentStore.save(
                index: scratch.index(documentID: documentID, pageIDs: [firstPage, secondPage]),
                pages: [PageWrite(pageID: secondPage, layers: scratch.inkLayers(Data([0x03])))]
            )
        }

        // An import writes an asset: assets/ carries the date.
        try await assertShapeMoves(participant: "assets") {
            try await documentStore.writeAsset(Data([0x04]), assetID: UUID(), format: .heic)
        }

        // A turn writes only the index: document.plist carries the date.
        try await assertShapeMoves(participant: "document.plist") {
            try await documentStore.save(
                index: scratch.index(
                    documentID: documentID,
                    pageIDs: [firstPage, secondPage],
                    currentPageIndex: 1
                ),
                pages: []
            )
        }
    }

    // MARK: - Preferences

    @Test("Preferences round-trip through library.plist")
    func prefsRoundTrip() async throws {
        let scratch = try LibraryScratch()
        let unset = await scratch.store.prefs()
        #expect(unset == .default)

        let chosen = LibraryPrefs(viewMode: .list, sortKey: .name, ascending: true)
        try await scratch.store.setPrefs(chosen)
        let reread = await scratch.freshStore().prefs()
        #expect(reread == chosen)
    }
}
