import Foundation

/// The sole writer of the saved document (`Contract.md` — Owners, Durable form).
///
/// It is an actor so that encoding and disk I/O are off the main actor by
/// construction rather than by discipline, and so two saves can never interleave.
/// This is the one actor the contract permits beyond the main actor.
///
/// The store never reaches into the canvas. It receives complete immutable
/// values and returns only after they are durable.
///
/// A document is a directory: one index file, and one file per page under
/// `pages/`. Every individual write is atomic; there is no atomicity across
/// files, and none is needed because page files are always written before the
/// index that references them.
actor DocumentStore {
    private let directoryURL: URL

    /// The index as it currently exists on disk, as far as this store knows.
    ///
    /// It is what makes "write the index only if it changed" a decision rather
    /// than a guess. It is a cache of the store's own writes and reads, not a
    /// second authority: it is only ever assigned from a value that was just
    /// read from or successfully written to disk.
    private var lastKnownIndex: DocumentIndex?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    private var indexURL: URL { directoryURL.appendingPathComponent("document.plist") }
    private var pagesDirectoryURL: URL { directoryURL.appendingPathComponent("pages") }

    private func pageURL(_ pageID: UUID) -> URL {
        pagesDirectoryURL.appendingPathComponent("\(pageID.uuidString).plist")
    }

    // MARK: - Load

    /// The document index, or `nil` when no document exists — a first launch,
    /// not an error.
    ///
    /// A decode error, an unsupported version, invalid geometry, or an index
    /// naming a page file that is not there all throw, and nothing on disk is
    /// modified.
    func load() throws -> DocumentIndex? {
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch let error as NSError where Self.isFileNotFound(error) {
            return nil
        }

        do {
            let decoded = try PropertyListDecoder().decode(DocumentIndex.self, from: data)
            let index = try decoded.validated()
            // A dangling reference is fatal and an orphan is not
            // (`Contract.md` — Durable form). Existence only: reading every
            // page here would make opening a notebook scale with its total
            // size, which is the thing this format exists to avoid.
            for pageID in index.pageIDs where !FileManager.default.fileExists(
                atPath: pageURL(pageID).path
            ) {
                throw DocumentIndexError.missingPageFile(pageID)
            }
            lastKnownIndex = index
            return index
        } catch {
            // A refusal to open a document is the most alarming thing this type
            // can do, so it says exactly what it read.
            let prefix = data.prefix(8).map { String(format: "%02x", $0) }.joined()
            CanvasLog.event(
                CanvasLog.save, "save",
                "refusing to open \(indexURL.path): \(data.count) bytes, "
                    + "starts \(prefix), error \(error)"
            )
            throw error
        }
    }

    /// One page's drawing bytes. Throws if the page file is missing or names a
    /// different page than the one asked for.
    func loadPage(_ pageID: UUID) throws -> Data {
        let data = try Data(contentsOf: pageURL(pageID))
        let page = try PropertyListDecoder().decode(PageFile.self, from: data)
        guard page.pageID == pageID else {
            throw DocumentIndexError.pageIDMismatch(expected: pageID, found: page.pageID)
        }
        return page.drawingData
    }

    // MARK: - Save

    /// Writes the pages whose ink changed, then the index if it changed.
    ///
    /// The ordering is the contract's, not an optimization: a crash after the
    /// page writes and before the index write leaves an unreferenced page file,
    /// which `load` ignores. The reverse order would leave the index naming a
    /// file that does not exist, which is a document that cannot be opened.
    ///
    /// Passing a page that did not change is a defect rather than a waste: it is
    /// the whole-document rewrite this format exists to prevent.
    func save(index: DocumentIndex, changedPages: [UUID: Data]) throws {
        let validated = try index.validated()

        for pageID in changedPages.keys where !validated.pageIDs.contains(pageID) {
            throw DocumentIndexError.missingPageFile(pageID)
        }

        try createDirectoriesIfNeeded()

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        for (pageID, drawingData) in changedPages {
            let page = PageFile(pageID: pageID, drawingData: drawingData)
            try encoder.encode(page).write(to: pageURL(pageID), options: .atomic)
        }

        // The cached index is a hint about disk, never an authority on it. If
        // the file is not actually there — a failed earlier write, or anything
        // that removed it underneath us — skipping the write would leave page
        // files with no index naming them, which is the unopenable document
        // `Contract.md` — Durable form's write ordering exists to prevent. One
        // `stat` per save is nothing next to the page write it guards.
        let indexNeedsWriting = lastKnownIndex != validated
            || !FileManager.default.fileExists(atPath: indexURL.path)
        if indexNeedsWriting {
            try encoder.encode(validated).write(to: indexURL, options: .atomic)
            lastKnownIndex = validated
        }

        CanvasLog.event(
            CanvasLog.save, "save",
            "wrote \(changedPages.count) page file(s) of \(validated.pageIDs.count); "
                + "index rewritten=\(indexNeedsWriting)"
        )
    }

    /// Deletes page files no page ID references. Orphans are inert, so this is
    /// housekeeping and never part of a save's durability guarantee.
    func deleteOrphanedPages(keeping pageIDs: [UUID]) throws {
        let kept = Set(pageIDs.map { "\($0.uuidString).plist" })
        let contents = try? FileManager.default.contentsOfDirectory(
            at: pagesDirectoryURL,
            includingPropertiesForKeys: nil
        )
        for url in contents ?? [] where !kept.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Files

    private func createDirectoriesIfNeeded() throws {
        for directory in [directoryURL, pagesDirectoryURL]
        where !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private static func isFileNotFound(_ error: NSError) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile { return true }
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    }
}

extension DocumentStore {
    /// The one document of this milestone. A later multi-document milestone owns
    /// naming; this is deliberately a fixed path, not a scheme.
    private static func applicationSupport() -> URL {
        guard let url = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            fatalError("Application Support is unavailable")
        }
        return url
    }

    /// Directory creation belongs to `save`, on the store actor. Resolving these
    /// URLs performs no synchronous creation while the SwiftUI app value is
    /// being initialized.
    static func defaultDirectoryURL() -> URL {
        applicationSupport().appendingPathComponent("JustACanvas.tubernotes")
    }
}
