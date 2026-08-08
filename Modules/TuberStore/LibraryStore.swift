import Foundation
import TuberCore

/// A folder's own metadata — the only thing a directory cannot state itself.
/// Orphan-class: a missing or unreadable `.folder.plist` renders the default
/// and never blocks the folder from opening.
package struct FolderDecoration: Sendable, Equatable, Codable {
    /// Hex or catalog key; `nil` renders the default color.
    package var color: String?
    /// SF Symbol name; `nil` renders no icon.
    package var icon: String?

    package init(color: String? = nil, icon: String? = nil) {
        self.color = color
        self.icon = icon
    }
}

/// One entry of a folder listing, built from directory facts alone — building
/// it never opens the package.
package struct LibraryItem: Sendable, Equatable, Identifiable {
    package enum Kind: Sendable, Equatable {
        case document
        case folder(FolderDecoration)
    }

    /// Library-relative path from the `Documents/` root, e.g.
    /// `"Chinese/Vocab.tubernotes"`. The path *is* the identity: the tree is
    /// the only truth, so there is no other durable ID at this level.
    package var id: String
    /// Display name: the directory name, `.tubernotes` stripped for documents.
    package var name: String
    package var kind: Kind
    package var createdAt: Date
    package var modifiedAt: Date
    package var isFavorite: Bool
    /// True when `.folder.plist` was missing or corrupt — render the default
    /// decoration and surface it.
    package var decorationDegraded: Bool
}

/// One entry of the trash listing.
package struct TrashItem: Sendable, Equatable, Identifiable {
    /// The item's name inside `Trash/` — post-suffix, so two same-named items
    /// trashed from different folders stay distinct.
    package var id: String
    package var name: String
    package var kind: LibraryItem.Kind
    /// The trash entry's own file-system date.
    package var deletedAt: Date
    /// The library-relative folder it was trashed from. `nil` means the origin
    /// sidecar is missing or unreadable — recover to the root.
    package var originPath: String?
}

package enum LibrarySortKey: String, Sendable, Codable {
    case dateCreated, lastModified, name, type
}

/// Browser presentation preferences — global, one `library.plist` at the root.
package struct LibraryPrefs: Sendable, Equatable, Codable {
    package var viewMode: ViewMode
    package enum ViewMode: String, Sendable, Codable { case grid, list }
    package var sortKey: LibrarySortKey
    package var ascending: Bool

    package static let `default` = LibraryPrefs(
        viewMode: .grid, sortKey: .lastModified, ascending: false
    )

    package init(viewMode: ViewMode, sortKey: LibrarySortKey, ascending: Bool) {
        self.viewMode = viewMode
        self.sortKey = sortKey
        self.ascending = ascending
    }
}

/// One folder's contents, as the file system states them.
package struct LibraryListing: Sendable {
    /// `""` is the root.
    package var folderPath: String
    /// Unsorted; the view model sorts.
    package var items: [LibraryItem]
    /// Human-readable notices — corrupt sidecars set aside, foreign files
    /// ignored — surfaced non-modally, never blocking.
    package var degradations: [String]
}

package enum LibraryError: Error, Equatable {
    /// The name gate refused: separators, leading dot, reserved suffix,
    /// byte budget, or emptiness. The reason says which.
    case invalidName(reason: String)
    case itemNotFound(String)
    case notAFolder(String)
    /// A folder that fails to enumerate is refused, not shown empty; the
    /// browser renders the refused-folder state from the description.
    case enumerationFailed(String)
    /// A folder cannot be moved into its own subtree.
    case destinationInsideSource
}

/// The sole writer of the library tree — what `DocumentStore` is to one
/// document's insides, one level up (`Docs/Contract.proposed.md` — L1, L3).
///
/// The tree is the only truth: names are directory names, dates are
/// file-system attributes, and there is no library index to disagree with
/// either. Every mutation's structural step is one atomic directory
/// operation; every file this store owns is an orphan-class sidecar whose
/// loss degrades to a stated default.
///
/// The package boundary is the boundary between the stores: this actor never
/// opens, decodes, or writes a file inside a `.tubernotes` package. The one
/// stated exception is a **stat** of the package's well-known interior paths
/// for the derived modified date — see `documentInteriorPaths`.
package actor LibraryStore {
    /// The interior paths whose newest mtime is a document's modified date.
    ///
    /// This is layout knowledge leaking one level up, accepted out loud: the
    /// list is the layout A14 establishes (`document.plist`, `pages/`,
    /// `layers/`, `assets/`), every save renames into one of them, and a
    /// document-format change that adds a top-level entry must update it.
    /// Paths a young document lacks do not participate — ENOENT is a date
    /// that is not there, not an error.
    private static let documentInteriorPaths = [
        "document.plist", "pages", "layers", "assets",
    ]

    /// The reserved suffix that classifies a directory as a document package.
    private static let documentSuffix = ".tubernotes"

    private nonisolated let rootURL: URL

    /// Adoption and the `.staging` sweep run inside the first root listing.
    /// Both are idempotent by construction — the flag saves the stats, it
    /// does not carry correctness.
    private var didAdoptAndSweep = false

    /// The prefs as last read from or written to disk — a cache of this
    /// store's own I/O, never a second authority.
    private var cachedPrefs: LibraryPrefs?

    /// `rootURL` is the `TuberLibrary` directory. Nothing is created here:
    /// `Documents/` and `Trash/` appear lazily, on the first operation that
    /// needs them, so constructing the store performs no I/O.
    package init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private nonisolated var documentsURL: URL { rootURL.appendingPathComponent("Documents") }
    private nonisolated var trashURL: URL { rootURL.appendingPathComponent("Trash") }
    private nonisolated var stagingURL: URL { rootURL.appendingPathComponent(".staging") }
    private nonisolated var favoritesURL: URL { rootURL.appendingPathComponent("favorites.plist") }
    private nonisolated var prefsURL: URL { rootURL.appendingPathComponent("library.plist") }

    /// The absolute package URL for the `EditorSession` handoff. Pure path
    /// arithmetic — no I/O, so callable from anywhere.
    package nonisolated func documentURL(forItemAt relativePath: String) -> URL {
        documentsURL.appendingPathComponent(relativePath)
    }

    // MARK: - Listing

    /// One folder's contents, `""` for the root. The first root listing sweeps
    /// `.staging/` and adopts the pre-library document, both idempotent.
    package func listFolder(_ folderPath: String) throws -> LibraryListing {
        if folderPath.isEmpty {
            try createDirectoryIfNeeded(documentsURL)
            if !didAdoptAndSweep {
                sweepStaging()
                adoptLegacyDocumentIfPresent()
                didAdoptAndSweep = true
            }
        }

        let folderURL = try folderDirectoryURL(folderPath)

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        } catch {
            // Refused, not emptied: the designed empty state renders only on
            // a successful empty listing.
            throw LibraryError.enumerationFailed(String(describing: error))
        }

        var items: [LibraryItem] = []
        var degradations: [String] = []
        let favorites = Set(readFavorites(degradations: &degradations))

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") {
                // Hidden entries are this store's own sidecars and set-asides
                // (`.folder.plist`, `*.corrupt`) or the OS's; none is an item
                // and none is worth a banner per listing.
                continue
            }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            guard isDirectory else {
                // Foreign files are inert: ignored, logged, never deleted.
                CanvasLog.event(.lifecycle, "library ignoring foreign file \(entry.path)")
                degradations.append("Ignored an unrecognized file: \(name)")
                continue
            }
            let relativePath = joined(folderPath, name)
            items.append(
                item(
                    at: relativePath,
                    url: entry,
                    isFavorite: favorites.contains(relativePath),
                    degradations: &degradations
                )
            )
        }

        return LibraryListing(folderPath: folderPath, items: items, degradations: degradations)
    }

    // MARK: - Creation

    /// Creates the folder directory and writes its decoration sidecar, in
    /// that order — structural step first, sidecar after.
    package func createFolder(
        named: String,
        in folderPath: String,
        decoration: FolderDecoration
    ) throws -> LibraryItem {
        let name = try Self.validated(name: named, isFolder: true)
        let parentURL = try folderDirectoryURL(folderPath, creatingRootIfNeeded: true)
        let directoryName = freeName(base: name, suffix: "", in: parentURL)
        let url = parentURL.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try writeDecorationSidecar(decoration, folderURL: url)

        let relativePath = joined(folderPath, directoryName)
        var ignored: [String] = []
        return item(at: relativePath, url: url, isFavorite: false, degradations: &ignored)
    }

    /// Reserves `<name>.tubernotes` and creates the empty directory only.
    /// The document's contents are `EditorSession`/`DocumentStore`'s job —
    /// this store never writes inside a package.
    package func createDocumentDirectory(
        named: String,
        in folderPath: String
    ) throws -> LibraryItem {
        let name = try Self.validated(name: named, isFolder: false)
        let parentURL = try folderDirectoryURL(folderPath, creatingRootIfNeeded: true)
        let directoryName = freeName(base: name, suffix: Self.documentSuffix, in: parentURL)
        let url = parentURL.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        let relativePath = joined(folderPath, directoryName)
        var ignored: [String] = []
        return item(at: relativePath, url: url, isFavorite: false, degradations: &ignored)
    }

    // MARK: - Mutation

    /// One atomic rename, then the favorites prefix-rewrite — so a crash
    /// between the two leaves a pruned favorite, never a dangling one.
    package func renameItem(at relativePath: String, to newName: String) throws -> LibraryItem {
        let sourceURL = documentURL(forItemAt: relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LibraryError.itemNotFound(relativePath)
        }
        let isDocument = relativePath.hasSuffix(Self.documentSuffix)
        let name = try Self.validated(name: newName, isFolder: !isDocument)
        if displayName(ofPathComponent: lastComponent(of: relativePath)) == name {
            var ignored: [String] = []
            return item(
                at: relativePath,
                url: sourceURL,
                isFavorite: readFavoritesQuietly().contains(relativePath),
                degradations: &ignored
            )
        }

        let parentPath = parent(of: relativePath)
        let parentURL = sourceURL.deletingLastPathComponent()
        let directoryName = freeName(
            base: name,
            suffix: isDocument ? Self.documentSuffix : "",
            in: parentURL
        )
        let destinationURL = parentURL.appendingPathComponent(directoryName)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

        let newPath = joined(parentPath, directoryName)
        rewriteFavorites(movedFrom: relativePath, to: newPath)

        var ignored: [String] = []
        return item(
            at: newPath,
            url: destinationURL,
            isFavorite: readFavoritesQuietly().contains(newPath),
            degradations: &ignored
        )
    }

    /// One atomic move, then the favorites prefix-rewrite to the post-suffix
    /// destination. A folder never moves into its own subtree.
    package func moveItem(at relativePath: String, toFolder folderPath: String) throws -> LibraryItem {
        let sourceURL = documentURL(forItemAt: relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LibraryError.itemNotFound(relativePath)
        }
        let isDocument = relativePath.hasSuffix(Self.documentSuffix)
        if !isDocument {
            if folderPath == relativePath || folderPath.hasPrefix(relativePath + "/") {
                throw LibraryError.destinationInsideSource
            }
        }
        if folderPath == parent(of: relativePath) {
            // Already there. Suffixing against its own reflection would
            // "resolve" a collision that does not exist.
            var ignored: [String] = []
            return item(
                at: relativePath,
                url: sourceURL,
                isFavorite: readFavoritesQuietly().contains(relativePath),
                degradations: &ignored
            )
        }
        let destinationFolderURL = try folderDirectoryURL(folderPath)

        let sourceName = lastComponent(of: relativePath)
        let directoryName = freeName(
            base: displayName(ofPathComponent: sourceName),
            suffix: isDocument ? Self.documentSuffix : "",
            in: destinationFolderURL
        )
        let destinationURL = destinationFolderURL.appendingPathComponent(directoryName)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

        let newPath = joined(folderPath, directoryName)
        rewriteFavorites(movedFrom: relativePath, to: newPath)

        var ignored: [String] = []
        return item(
            at: newPath,
            url: destinationURL,
            isFavorite: readFavoritesQuietly().contains(newPath),
            degradations: &ignored
        )
    }

    /// Rewrites the folder's `.folder.plist` whole — the recovery from a
    /// corrupt sidecar is the next write, and this is that write.
    package func setDecoration(_ d: FolderDecoration, forFolderAt relativePath: String) throws {
        let url = documentURL(forItemAt: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.itemNotFound(relativePath)
        }
        guard isFolderDirectory(url), !relativePath.hasSuffix(Self.documentSuffix) else {
            throw LibraryError.notAFolder(relativePath)
        }
        try writeDecorationSidecar(d, folderURL: url)
    }

    /// Copies into `.staging/<uuid>/` and lands with one atomic move, so a
    /// torn duplicate is debris under `.staging` that can never enumerate.
    package func duplicateDocument(at relativePath: String) throws -> LibraryItem {
        precondition(
            relativePath.hasSuffix(Self.documentSuffix),
            "duplicateDocument was handed a folder: \(relativePath)"
        )
        let sourceURL = documentURL(forItemAt: relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LibraryError.itemNotFound(relativePath)
        }

        let stagingDirectory = stagingURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let staged = stagingDirectory.appendingPathComponent(lastComponent(of: relativePath))
        // KNOWN DEFECT: the copy keeps the source's `documentID`, so two
        // packages share one identity until the fresh-ID rewrite lands
        // through `DocumentStore` (`Docs/Forks/Library/03-review.md` — M-B).
        // Nothing library-level keys on it tonight.
        try FileManager.default.copyItem(at: sourceURL, to: staged)

        let parentPath = parent(of: relativePath)
        let parentURL = sourceURL.deletingLastPathComponent()
        let directoryName = freeName(
            base: displayName(ofPathComponent: lastComponent(of: relativePath)),
            suffix: Self.documentSuffix,
            in: parentURL
        )
        let destinationURL = parentURL.appendingPathComponent(directoryName)
        try FileManager.default.moveItem(at: staged, to: destinationURL)
        try? FileManager.default.removeItem(at: stagingDirectory)

        let newPath = joined(parentPath, directoryName)
        var ignored: [String] = []
        return item(at: newPath, url: destinationURL, isFavorite: false, degradations: &ignored)
    }

    // MARK: - Favorites

    package func setFavorite(_ flag: Bool, at relativePath: String) throws {
        guard FileManager.default.fileExists(atPath: documentURL(forItemAt: relativePath).path)
        else {
            throw LibraryError.itemNotFound(relativePath)
        }
        var entries = readFavoritesQuietly()
        entries.removeAll { $0 == relativePath }
        if flag { entries.append(relativePath) }
        try writeFavorites(entries)
    }

    /// Resolves the favorites list against the tree. A dangling entry renders
    /// nothing and stays on disk — pruning happens only on the next favorites
    /// write, so a listing never mutates the sidecar it is reading.
    package func listFavorites() throws -> [LibraryItem] {
        var degradations: [String] = []
        var items: [LibraryItem] = []
        for path in readFavorites(degradations: &degradations) {
            let url = documentURL(forItemAt: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            items.append(item(at: path, url: url, isFavorite: true, degradations: &degradations))
        }
        return items
    }

    // MARK: - Trash

    /// One atomic move into `Trash/`, then the origin sidecar — named after
    /// the post-suffix trash name, so two same-named items trashed from
    /// different folders cannot cross origins. A crash between the two leaves
    /// a sidecar-less entry, which recovers to the root: pruned, not dangling.
    ///
    /// Favorites naming the trashed item are left to dangle deliberately —
    /// dangling entries render nothing and die on the next favorites write.
    package func trashItem(at relativePath: String) throws {
        let sourceURL = documentURL(forItemAt: relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LibraryError.itemNotFound(relativePath)
        }
        try createDirectoryIfNeeded(trashURL)

        let isDocument = relativePath.hasSuffix(Self.documentSuffix)
        let trashName = freeName(
            base: displayName(ofPathComponent: lastComponent(of: relativePath)),
            suffix: isDocument ? Self.documentSuffix : "",
            in: trashURL
        )
        try FileManager.default.moveItem(
            at: sourceURL,
            to: trashURL.appendingPathComponent(trashName)
        )
        let origin = TrashOrigin(originFolderPath: parent(of: relativePath))
        do {
            try encoded(origin).write(to: originSidecarURL(trashName: trashName), options: .atomic)
        } catch {
            // The move already landed; a lost sidecar is the stated default
            // (recover to root), never a reason to fail the trash.
            CanvasLog.event(.save, "trash origin sidecar write failed for \(trashName): \(error)")
        }
    }

    package func listTrash() throws -> [TrashItem] {
        guard FileManager.default.fileExists(atPath: trashURL.path) else { return [] }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: trashURL,
                includingPropertiesForKeys: [.isDirectoryKey, .addedToDirectoryDateKey]
            )
        } catch {
            throw LibraryError.enumerationFailed(String(describing: error))
        }

        var items: [TrashItem] = []
        var degradations: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            // Origin sidecars and their `.corrupt` set-asides are this
            // store's own files, not trash entries.
            if name.hasPrefix(".") || name.contains(".origin.plist") { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            guard isDirectory else {
                CanvasLog.event(.lifecycle, "trash ignoring foreign file \(entry.path)")
                continue
            }

            let isDocument = name.hasSuffix(Self.documentSuffix)
            let kind: LibraryItem.Kind
            if isDocument {
                kind = .document
            } else {
                let read = decoration(ofFolderAt: entry, degradations: &degradations)
                kind = .folder(read.0)
            }
            // The entry's own move-into-Trash date. The item's mtime is
            // deliberately preserved by the move, so it cannot say when the
            // trashing happened; the directory-membership date can.
            let values = try? entry.resourceValues(
                forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey]
            )
            let deletedAt = values?.addedToDirectoryDate
                ?? values?.contentModificationDate
                ?? .distantPast

            items.append(
                TrashItem(
                    id: name,
                    name: displayName(ofPathComponent: name),
                    kind: kind,
                    deletedAt: deletedAt,
                    originPath: readOrigin(trashName: name, degradations: &degradations)
                )
            )
        }
        return items
    }

    /// Moves the item back to its origin if that folder still exists, else to
    /// the root — then deletes the sidecar. A crash between the two leaves an
    /// inert orphan sidecar, swept with the next entry of the same name or by
    /// Empty Trash.
    package func recoverItem(named: String) throws -> LibraryItem {
        let sourceURL = trashURL.appendingPathComponent(named)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LibraryError.itemNotFound(named)
        }

        var degradations: [String] = []
        var destinationFolder = readOrigin(trashName: named, degradations: &degradations) ?? ""
        if !destinationFolder.isEmpty {
            let originURL = documentURL(forItemAt: destinationFolder)
            if !isFolderDirectory(originURL) || destinationFolder.hasSuffix(Self.documentSuffix) {
                // The origin is gone (or no longer a folder): the stated
                // default is the root, never a recreated ancestor chain.
                destinationFolder = ""
            }
        }
        try createDirectoryIfNeeded(documentsURL)
        let destinationFolderURL = try folderDirectoryURL(destinationFolder)

        let isDocument = named.hasSuffix(Self.documentSuffix)
        let directoryName = freeName(
            base: displayName(ofPathComponent: named),
            suffix: isDocument ? Self.documentSuffix : "",
            in: destinationFolderURL
        )
        let destinationURL = destinationFolderURL.appendingPathComponent(directoryName)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        try? FileManager.default.removeItem(at: originSidecarURL(trashName: named))

        var ignored: [String] = []
        return item(
            at: joined(destinationFolder, directoryName),
            url: destinationURL,
            isFavorite: false,
            degradations: &ignored
        )
    }

    package func deletePermanently(named: String) throws {
        let url = trashURL.appendingPathComponent(named)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.itemNotFound(named)
        }
        try FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: originSidecarURL(trashName: named))
    }

    /// Removes every entry in `Trash/`, sidecars included — the only walk of
    /// anything beyond one folder, and one of two permanent deletions.
    package func emptyTrash() throws {
        guard FileManager.default.fileExists(atPath: trashURL.path) else { return }
        for entry in try FileManager.default.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Preferences

    package func prefs() -> LibraryPrefs {
        if let cachedPrefs { return cachedPrefs }
        let read: LibraryPrefs
        do {
            let data = try Data(contentsOf: prefsURL)
            read = try PropertyListDecoder().decode(LibraryPrefs.self, from: data)
        } catch let error as NSError where Self.isFileNotFound(error) {
            read = .default
        } catch {
            // Corrupt: set the evidence aside, degrade to the default. A lost
            // sort preference is a log line, not an alert.
            CanvasLog.event(.lifecycle, "library.plist unreadable, set aside: \(error)")
            setAside(prefsURL)
            read = .default
        }
        cachedPrefs = read
        return read
    }

    package func setPrefs(_ p: LibraryPrefs) throws {
        try createDirectoryIfNeeded(rootURL)
        try encoded(p).write(to: prefsURL, options: .atomic)
        cachedPrefs = p
    }

    // MARK: - The production root

    /// `<Application Support>/TuberLibrary`, resolved without I/O — directory
    /// creation belongs to the store's own operations, on this actor.
    package static func defaultRootURL() -> URL {
        guard let url = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            fatalError("Application Support is unavailable")
        }
        return url.appendingPathComponent("TuberLibrary")
    }

    // MARK: - Adoption and staging

    /// Debris from a duplicate that never landed. Enumeration cannot see it
    /// (it is a sibling of `Documents/`), and the sweep makes it not exist.
    private func sweepStaging() {
        guard FileManager.default.fileExists(atPath: stagingURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: stagingURL)
            CanvasLog.event(.lifecycle, "swept .staging")
        } catch {
            CanvasLog.event(.lifecycle, "could not sweep .staging: \(error)")
        }
    }

    /// The one write this store makes outside a user action and outside its
    /// tree (`Contract.proposed.md` — L1): the pre-library document at the old
    /// fixed path is moved whole into `Documents/`. The source is the sibling
    /// of the library root — for the production root that is exactly
    /// `<Application Support>/JustACanvas.tubernotes`, the path
    /// `DocumentStore.defaultDirectoryURL()` names. Idempotent by
    /// construction: a crash before leaves the source to try again, a crash
    /// after leaves nothing to do. Deletable the day it stops mattering.
    private func adoptLegacyDocumentIfPresent() {
        let source = rootURL.deletingLastPathComponent()
            .appendingPathComponent("JustACanvas.tubernotes")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let name = freeName(base: "Just a Canvas", suffix: Self.documentSuffix, in: documentsURL)
        do {
            try FileManager.default.moveItem(
                at: source,
                to: documentsURL.appendingPathComponent(name)
            )
            CanvasLog.event(.lifecycle, "adopted the pre-library document as \(name)")
        } catch {
            // The source survives, so the next launch tries again; a failed
            // adoption must not refuse the library.
            CanvasLog.event(.lifecycle, "adoption failed, will retry next launch: \(error)")
        }
    }

    // MARK: - The name gate

    /// The one gate every user-supplied name passes. It refuses; it never
    /// corrects — the sanctioned adaptation at this level is the collision
    /// suffix, and that happens against the file system, not here.
    private static func validated(name: String, isFolder: Bool) throws -> String {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LibraryError.invalidName(reason: "a name cannot be empty")
        }
        if name.contains("/") || name.contains(":") {
            throw LibraryError.invalidName(reason: "a name cannot contain a path separator")
        }
        if name.hasPrefix(".") {
            throw LibraryError.invalidName(reason: "a name cannot start with a dot")
        }
        // A folder named `X.tubernotes` would classify as a document and
        // swallow its contents; document names take the suffix from the
        // store, never from the user.
        if isFolder, name.lowercased().hasSuffix(Self.documentSuffix) {
            throw LibraryError.invalidName(reason: "\(Self.documentSuffix) is a reserved suffix")
        }
        if name.lowercased().contains(".origin.plist") {
            throw LibraryError.invalidName(reason: ".origin.plist is a reserved name")
        }
        // 255 bytes is the file-system's component limit; headroom is the
        // document suffix this store appends plus a two-digit collision
        // suffix (" 99").
        let headroom = (isFolder ? 0 : Self.documentSuffix.utf8.count) + " 99".utf8.count
        if name.utf8.count + headroom > 255 {
            throw LibraryError.invalidName(reason: "the name is too long")
        }
        return name
    }

    /// The first free directory name for `base` (+ suffix), by asking the
    /// file system — `fileExists` on the real path, never a string comparison
    /// of listings: the device's data volume is case-sensitive while the
    /// pinned simulator's is not, so a compared listing would pass CI and lie
    /// on device.
    private func freeName(base: String, suffix: String, in directory: URL) -> String {
        var candidate = base + suffix
        var n = 2
        while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(candidate).path
        ) {
            candidate = "\(base) \(n)\(suffix)"
            n += 1
        }
        return candidate
    }

    // MARK: - Items from directory facts

    private func item(
        at relativePath: String,
        url: URL,
        isFavorite: Bool,
        degradations: inout [String]
    ) -> LibraryItem {
        let component = lastComponent(of: relativePath)
        let isDocument = component.hasSuffix(Self.documentSuffix)

        let kind: LibraryItem.Kind
        var degraded = false
        if isDocument {
            kind = .document
        } else {
            let read = decoration(ofFolderAt: url, degradations: &degradations)
            kind = .folder(read.0)
            degraded = read.degraded
        }

        let values = try? url.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        let created = values?.creationDate ?? .distantPast
        let ownModified = values?.contentModificationDate ?? .distantPast

        return LibraryItem(
            id: relativePath,
            name: displayName(ofPathComponent: component),
            kind: kind,
            createdAt: created,
            modifiedAt: isDocument
                ? documentModifiedDate(packageURL: url, fallback: ownModified)
                : ownModified,
            isFavorite: isFavorite,
            decorationDegraded: degraded
        )
    }

    /// The licensed stat exception: the newest mtime among the package's
    /// interior paths. Every save renames into one of them, and a rename into
    /// a directory updates that directory's mtime, so this tracks every save
    /// shape without opening the package or adding a durable field.
    private func documentModifiedDate(packageURL: URL, fallback: Date) -> Date {
        var newest: Date?
        for interior in Self.documentInteriorPaths {
            let url = packageURL.appendingPathComponent(interior)
            guard let date = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else {
                continue
            }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        // A package with none of the four yet — a reserved directory whose
        // first save has not landed — dates by its own directory.
        return newest ?? fallback
    }

    private func decoration(
        ofFolderAt url: URL,
        degradations: inout [String]
    ) -> (FolderDecoration, degraded: Bool) {
        let sidecar = url.appendingPathComponent(".folder.plist")
        let data: Data
        do {
            data = try Data(contentsOf: sidecar)
        } catch {
            degradations.append(
                "\(url.lastPathComponent): folder decoration missing; showing the default"
            )
            return (FolderDecoration(), true)
        }
        do {
            return (try PropertyListDecoder().decode(FolderDecoration.self, from: data), false)
        } catch {
            CanvasLog.event(.lifecycle, "corrupt .folder.plist at \(sidecar.path): \(error)")
            setAside(sidecar)
            degradations.append(
                "\(url.lastPathComponent): folder decoration unreadable, set aside; "
                    + "showing the default"
            )
            return (FolderDecoration(), true)
        }
    }

    private func writeDecorationSidecar(_ d: FolderDecoration, folderURL: URL) throws {
        try encoded(d).write(
            to: folderURL.appendingPathComponent(".folder.plist"),
            options: .atomic
        )
    }

    // MARK: - Favorites sidecar

    private func readFavorites(degradations: inout [String]) -> [String] {
        let data: Data
        do {
            data = try Data(contentsOf: favoritesURL)
        } catch {
            return []
        }
        do {
            return try PropertyListDecoder().decode([String].self, from: data)
        } catch {
            CanvasLog.event(.lifecycle, "corrupt favorites.plist, set aside: \(error)")
            setAside(favoritesURL)
            degradations.append("The favorites list was unreadable and has been reset")
            return []
        }
    }

    private func readFavoritesQuietly() -> [String] {
        var ignored: [String] = []
        return readFavorites(degradations: &ignored)
    }

    /// Rewritten whole, dangling entries pruned — the write is the only place
    /// pruning is licensed.
    private func writeFavorites(_ entries: [String]) throws {
        let pruned = entries.filter {
            FileManager.default.fileExists(atPath: documentURL(forItemAt: $0).path)
        }
        try createDirectoryIfNeeded(rootURL)
        try encoded(pruned).write(to: favoritesURL, options: .atomic)
    }

    /// The prefix rewrite: every entry that is the moved path or lives under
    /// it follows the move, so renaming a folder carries every starred
    /// descendant. Runs after the structural move, to the post-suffix path.
    private func rewriteFavorites(movedFrom oldPath: String, to newPath: String) {
        let entries = readFavoritesQuietly()
        guard entries.contains(where: { $0 == oldPath || $0.hasPrefix(oldPath + "/") }) else {
            return
        }
        let rewritten = entries.map { entry -> String in
            if entry == oldPath { return newPath }
            if entry.hasPrefix(oldPath + "/") {
                return newPath + entry.dropFirst(oldPath.count)
            }
            return entry
        }
        do {
            try writeFavorites(rewritten)
        } catch {
            // The move already landed. A failed rewrite leaves entries that
            // dangle — rendered as nothing, pruned on the next write.
            CanvasLog.event(.save, "favorites rewrite failed after moving \(oldPath): \(error)")
        }
    }

    // MARK: - Trash sidecar

    private struct TrashOrigin: Codable {
        var originFolderPath: String
    }

    private func originSidecarURL(trashName: String) -> URL {
        trashURL.appendingPathComponent("\(trashName).origin.plist")
    }

    private func readOrigin(trashName: String, degradations: inout [String]) -> String? {
        let sidecar = originSidecarURL(trashName: trashName)
        let data: Data
        do {
            data = try Data(contentsOf: sidecar)
        } catch {
            return nil
        }
        do {
            return try PropertyListDecoder().decode(TrashOrigin.self, from: data).originFolderPath
        } catch {
            CanvasLog.event(.lifecycle, "corrupt origin sidecar \(sidecar.path): \(error)")
            setAside(sidecar)
            degradations.append("\(trashName): original location unreadable; recovers to the root")
            return nil
        }
    }

    // MARK: - Paths and plumbing

    /// The directory a folder path names, verified to exist and be a folder.
    /// The root is created on demand when asked to be.
    private func folderDirectoryURL(
        _ folderPath: String,
        creatingRootIfNeeded: Bool = false
    ) throws -> URL {
        if folderPath.isEmpty {
            if creatingRootIfNeeded { try createDirectoryIfNeeded(documentsURL) }
            return documentsURL
        }
        let url = documentURL(forItemAt: folderPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LibraryError.itemNotFound(folderPath)
        }
        guard isDirectory.boolValue, !folderPath.hasSuffix(Self.documentSuffix) else {
            throw LibraryError.notAFolder(folderPath)
        }
        return url
    }

    private func isFolderDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private nonisolated func joined(_ folderPath: String, _ name: String) -> String {
        folderPath.isEmpty ? name : "\(folderPath)/\(name)"
    }

    private nonisolated func parent(of relativePath: String) -> String {
        relativePath.split(separator: "/").dropLast().joined(separator: "/")
    }

    private nonisolated func lastComponent(of relativePath: String) -> String {
        relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    }

    private nonisolated func displayName(ofPathComponent component: String) -> String {
        component.hasSuffix(Self.documentSuffix)
            ? String(component.dropLast(Self.documentSuffix.count))
            : component
    }

    /// Moves a corrupt sidecar to `<name>.corrupt` — never overwriting: the
    /// evidence outlives the recovery, and an existing set-aside suffixes.
    private func setAside(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        let target = freeName(base: url.lastPathComponent + ".corrupt", suffix: "", in: directory)
        do {
            try FileManager.default.moveItem(
                at: url,
                to: directory.appendingPathComponent(target)
            )
        } catch {
            CanvasLog.event(.lifecycle, "could not set aside \(url.path): \(error)")
        }
    }

    private func encoded(_ value: some Encodable) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private func createDirectoryIfNeeded(_ directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private static func isFileNotFound(_ error: NSError) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile { return true }
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    }
}
