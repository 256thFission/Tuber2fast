import Foundation
import Testing
@testable import TNFormat
@testable import TNLibrary
@testable import TNModel

/// Two durability defects found in the data-model review. Both assert what
/// `Docs/Contract.md` states, so both fail until the code agrees with it.
@Suite("Migration probe")
struct MigrationProbe {
    /// *Refuse at the narrowest scope*: "Nothing is dropped, adapted, or
    /// written back unread." An unknown paper kind is written back stripped
    /// of its payload, and `compact()` then reclaims the asset it named.
    @Test("A paper kind this build does not know keeps its asset through an index rewrite")
    func unknownPaperKeepsItsAsset() throws {
        let asset = AssetRef(id: AssetID(), format: .heic)
        var object = try jsonObject(try Codecs.encode(Fixture.index(pages: 1)))
        var pages = try #require(object["pages"] as? [[String: Any]])
        pages[0]["paper"] = ["kind": "gradient", "asset": asset.fileName]
        object["pages"] = pages

        let decoded = try IndexFile.decode(try jsonData(object)).validated()
        #expect(decoded.pageFaults[decoded.pageIDs[0]] == .unknownPaper("gradient"))

        let paper = try #require(
            (try jsonObject(try Codecs.encode(decoded))["pages"] as? [[String: Any]])?[0]["paper"] as? [String: Any]
        )
        #expect(paper["asset"] as? String == asset.fileName)
        #expect(decoded.pages[0].paperAsset == asset)
    }

    /// Only `compact()` deletes. `trash()` removes a colliding container
    /// outright, so trashing the second of two folders that share a
    /// `FolderID` destroys the first with no confirmation and no recovery.
    @Test("Trashing a second folder that shares a FolderID leaves the first recoverable")
    func trashCollisionKeepsBoth() async throws {
        let scratch = try Scratch("trash-collision")
        let store = try LibraryStore(base: scratch.root)

        let first = try await store.createFolder(named: "Autumn", in: "")
        let second = try await store.createFolder(named: "Spring", in: "")
        let sharedID = try #require(await store.folderID(of: first.relativePath))

        // A folder copied in Files carries its sidecar, identity included.
        try Codecs.encode(FolderFile(folderID: sharedID, decoration: .plain))
            .write(to: store.url(of: second.relativePath).appendingPathComponent(".folder.json"))
        try Data("the first folder's contents".utf8)
            .write(to: store.url(of: first.relativePath).appendingPathComponent("evidence.txt"))

        _ = try await store.trash(at: first.relativePath)
        _ = try await store.trash(at: second.relativePath)

        #expect(try await store.listTrash().count == 2)
        let survivors = FileManager.default.enumerator(at: store.trashRoot, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        #expect(survivors.contains("evidence.txt"))
    }

    /// Where derived data may live, pinned as a fact rather than a defect.
    /// `compact()` sweeps the four known directories by file name, so
    /// anything beside a page file is reclaimed however it is named, while a
    /// top-level directory it was never told about is not enumerated at all.
    /// Recognition data, a search index, or any other derived sidecar goes in
    /// its own directory or nowhere.
    @Test("compact reclaims a sidecar in pages/ and never sweeps a new top-level directory")
    func sidecarSurvivesCompaction() async throws {
        let scratch = try Scratch("sidecar-compaction")
        let (store, index, _) = try await Fixture.populated(at: scratch.packageURL)
        let layout = PackageLayout(root: scratch.packageURL)

        let beside = layout.pagesDirectory
            .appendingPathComponent("\(index.pageIDs[0].raw.uuidString).recognition.json")
        try Data(#"{"words":[]}"#.utf8).write(to: beside)

        let ownDirectory = scratch.packageURL.appendingPathComponent("recognition", isDirectory: true)
        try FileManager.default.createDirectory(at: ownDirectory, withIntermediateDirectories: true)
        let inside = ownDirectory.appendingPathComponent("\(index.pageIDs[0].raw.uuidString).json")
        try Data(#"{"words":[]}"#.utf8).write(to: inside)

        try scratch.backdate(beside, by: 2 * 86_400)
        try scratch.backdate(inside, by: 2 * 86_400)
        _ = try await store.compact()

        #expect(PosixFileSystem().exists(inside), "a new top-level directory is never swept")
        #expect(!PosixFileSystem().exists(beside), "a sidecar in pages/ is not a page file, so it goes")
    }

    /// *Refuse at the narrowest scope*: "A page whose paper this build does
    /// not know is refused; the notebook still opens." An asset extension
    /// outside `AssetFormat` escapes `PaperKind` as a `DecodingError` and
    /// takes the whole index with it, while the same unknown extension on an
    /// image layer costs only its page.
    @Test("Paper naming an asset format this build lacks refuses the page, not the notebook")
    func unknownAssetFormatInPaperRefusesOnlyThePage() throws {
        var object = try jsonObject(try Codecs.encode(Fixture.index(pages: 2)))
        var pages = try #require(object["pages"] as? [[String: Any]])
        pages[0]["paper"] = ["kind": "image", "asset": "\(UUID().uuidString).png"]
        object["pages"] = pages

        let index = try IndexFile.decode(try jsonData(object)).validated()
        #expect(index.pages.count == 2)
        #expect(index.pageFaults[index.pageIDs[0]] != nil, "the page carrying it is refused")
        #expect(index.pageFaults[index.pageIDs[1]] == nil, "its neighbour still opens")
    }
}
