import Foundation
import Testing
@testable import TuberNotes
@testable import TuberStore

/// The app carries this alias for the same collision the browser tests name:
/// something up the import graph exposes a public `LibraryItem`, and here the
/// store's is the one meant.
private typealias LibraryItem = TuberStore.LibraryItem

/// A unique library root per test, removed when the test ends — the same
/// shape `LibraryBrowserTests` uses.
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

// MARK: - The star toggle

@Suite("Favorites toggle", .serialized)
@MainActor
struct LibraryFavoriteToggleTests {
    @Test("The star round-trips through a real store: on, listed, off, unlisted")
    func starToggleRoundTrips() async throws {
        let scratch = try LibraryScratch("startoggle")
        _ = try await scratch.library.createDocumentDirectory(named: "Bayes Exam", in: "")

        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        let doc = try #require(model.items.first)
        #expect(!doc.isFavorite)

        await model.toggleFavorite(doc)
        let starred = try #require(model.items.first)
        #expect(starred.isFavorite)
        #expect(try await scratch.library.listFavorites().map(\.id) == ["Bayes Exam.tubernotes"])

        // Toggling from the refreshed snapshot flips it back off.
        await model.toggleFavorite(starred)
        let unstarred = try #require(model.items.first)
        #expect(!unstarred.isFavorite)
        #expect(try await scratch.library.listFavorites().isEmpty)
    }
}

// MARK: - The collection

@Suite("Favorites collection", .serialized)
@MainActor
struct LibraryFavoritesCollectionTests {
    @Test("The favorites listing mixes documents and folders across parents")
    func listingMixesKindsAcrossParents() async throws {
        let scratch = try LibraryScratch("mixed")
        _ = try await scratch.library.createFolder(
            named: "Chinese", in: "", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createFolder(
            named: "Math", in: "", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createDocumentDirectory(named: "Vocab", in: "Chinese")
        _ = try await scratch.library.createDocumentDirectory(named: "Bayes", in: "Math")

        try await scratch.library.setFavorite(true, at: "Chinese/Vocab.tubernotes")
        try await scratch.library.setFavorite(true, at: "Math")

        let model = FolderListingModel(favoritesIn: scratch.library)
        await model.refresh()
        #expect(model.state == .loaded)
        #expect(model.displayTitle == "Favorites")
        // One flat listing: a document from inside `Chinese` beside the
        // `Math` folder itself — cross-parent, both kinds.
        #expect(Set(model.items.map(\.id)) == ["Chinese/Vocab.tubernotes", "Math"])
        let kinds = Set(model.items.map { item -> String in
            if case .folder = item.kind { return "folder" }
            return "document"
        })
        #expect(kinds == ["folder", "document"])
        // A favorited folder is one entry; its starred-nothing contents do
        // not surface individually.
        #expect(!model.items.contains { $0.id == "Math/Bayes.tubernotes" })
    }

    @Test("Rename from the favorites listing resolves the item's real path")
    func renameFromFavoritesResolvesRealPath() async throws {
        let scratch = try LibraryScratch("renamefav")
        _ = try await scratch.library.createFolder(
            named: "Chinese", in: "", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createDocumentDirectory(named: "Vocab", in: "Chinese")
        try await scratch.library.setFavorite(true, at: "Chinese/Vocab.tubernotes")

        let model = FolderListingModel(favoritesIn: scratch.library)
        await model.refresh()
        let doc = try #require(model.items.first)

        let inlineError = await model.rename(doc, to: "HSK Vocab")
        #expect(inlineError == nil)

        // The rename landed inside the item's true parent, not at some
        // favorites-level path — the tree is the truth.
        let parent = try await scratch.library.listFolder("Chinese")
        #expect(parent.items.map(\.id) == ["Chinese/HSK Vocab.tubernotes"])
        // And the favorites entry followed the rename (the store's prefix
        // rewrite), so the collection still shows it under the new name.
        #expect(model.items.map(\.id) == ["Chinese/HSK Vocab.tubernotes"])
        #expect(try #require(model.items.first).isFavorite)
    }

    @Test("Trash from the favorites listing removes the real item, not a reflection")
    func trashFromFavoritesResolvesRealPath() async throws {
        let scratch = try LibraryScratch("trashfav")
        _ = try await scratch.library.createFolder(
            named: "Chinese", in: "", decoration: FolderDecoration()
        )
        _ = try await scratch.library.createFolder(
            named: "HSK 5", in: "Chinese", decoration: FolderDecoration()
        )
        try await scratch.library.setFavorite(true, at: "Chinese/HSK 5")

        let model = FolderListingModel(favoritesIn: scratch.library)
        await model.refresh()
        let folder = try #require(model.items.first)

        await model.trash(folder)

        // Gone from the collection, gone from its real parent, present in
        // Trash under its own name.
        #expect(model.items.isEmpty)
        let parent = try await scratch.library.listFolder("Chinese")
        #expect(parent.items.isEmpty)
        let trash = try await scratch.library.listTrash()
        #expect(trash.map(\.name) == ["HSK 5"])
    }
}

// MARK: - Duplicate

@Suite("Duplicate from the popover's model call", .serialized)
@MainActor
struct LibraryDuplicateTests {
    @Test("Duplicate lands with the suffix, banners the adapted name, and leaves the source untouched")
    func duplicateSuffixesAndPreservesSource() async throws {
        let scratch = try LibraryScratch("duplicate")
        let created = try await scratch.library.createDocumentDirectory(named: "Field Notes", in: "")

        // Give the package contents worth comparing: the store never opens a
        // package, so the fixture writes the interior directly.
        let packageURL = scratch.library.documentURL(forItemAt: created.id)
        try Data("index".utf8).write(to: packageURL.appendingPathComponent("document.plist"))
        let pagesURL = packageURL.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pagesURL, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 512).write(to: pagesURL.appendingPathComponent("page-1"))

        let sourceBefore = try inventory(of: packageURL)

        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        let doc = try #require(model.items.first { $0.name == "Field Notes" })
        await model.duplicate(doc)

        // The copy appears in the listing under the collision suffix, and
        // the banner surfaces the adapted name rather than passing silently.
        #expect(Set(model.items.map(\.name)) == ["Field Notes", "Field Notes 2"])
        #expect(model.mutationBanner?.contains("Field Notes 2") == true)

        // The original is untouched: same files, same bytes.
        let sourceAfter = try inventory(of: packageURL)
        #expect(sourceAfter == sourceBefore)

        // And the copy carries the same contents.
        let copyURL = scratch.library.documentURL(forItemAt: "Field Notes 2.tubernotes")
        #expect(try inventory(of: copyURL) == sourceBefore)
    }

    @Test("Duplicate refuses nothing it should not: a folder is a no-op at the model")
    func duplicateIgnoresFolders() async throws {
        let scratch = try LibraryScratch("dupfolder")
        _ = try await scratch.library.createFolder(
            named: "Chinese", in: "", decoration: FolderDecoration()
        )
        let model = FolderListingModel(folderPath: "", library: scratch.library)
        await model.refresh()
        let folder = try #require(model.items.first)

        // The popover never offers Duplicate on a folder (UX-9); the model
        // guard is the backstop against a future caller.
        await model.duplicate(folder)
        #expect(model.items.map(\.name) == ["Chinese"])
        #expect(model.mutationBanner == nil)
    }

    /// Every file under `url`, relative path → byte count. Counts and bytes
    /// together say "same files, same sizes" without decoding anything.
    private func inventory(of url: URL) throws -> [String: Int] {
        var result: [String: Int] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let enumerator = try #require(
            FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        )
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let relative = file.path.replacingOccurrences(of: url.path + "/", with: "")
            result[relative] = values.fileSize ?? 0
        }
        return result
    }
}
