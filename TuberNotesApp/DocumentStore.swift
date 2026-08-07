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
                .save,
                "refusing to open \(indexURL.path): \(data.count) bytes, "
                    + "starts \(prefix), error \(error)"
            )
            throw error
        }
    }

    /// One page's layers, validated against the layer invariants. Throws if
    /// the page file is missing, names a different page than the one asked
    /// for, or violates an invariant — those are invalid states, not refusals.
    ///
    /// A layer whose kind this build does not recognize is refused at the
    /// layer's own scope: it comes back as a typed `RefusedLayer`, the rest of
    /// the page loads, and the document opens. The store remembers the page so
    /// that a later save cannot silently drop what it refused.
    func loadPage(_ pageID: UUID) throws -> LoadedPage {
        let data = try Data(contentsOf: pageURL(pageID))
        let page = try PropertyListDecoder().decode(PageFile.self, from: data)
        guard page.pageID == pageID else {
            throw DocumentIndexError.pageIDMismatch(expected: pageID, found: page.pageID)
        }
        let (ink, refused) = try Self.validated(layers: page.layers, pageID: pageID)
        if !refused.isEmpty { pagesRefusedOnLoad.insert(pageID) }
        return LoadedPage(
            inkLayerID: ink.layerID,
            inkData: ink.payload,
            refusedLayers: refused
        )
    }

    /// The layer invariants of phase 1, checked in one place for both
    /// directions: a page has exactly one `ink` layer, that layer is last in
    /// the list, and its transform is identity. An unrecognized kind is not a
    /// violation — it is returned as a refusal for the caller to scope.
    private static func validated(
        layers: [LayerEnvelope],
        pageID: UUID
    ) throws -> (ink: LayerEnvelope, refused: [RefusedLayer]) {
        var refused: [RefusedLayer] = []
        var inkLayers: [LayerEnvelope] = []
        for layer in layers {
            switch layer.recognizedKind {
            case .ink:
                inkLayers.append(layer)
            case nil:
                refused.append(RefusedLayer(layerID: layer.layerID, kind: layer.kind))
            }
        }
        guard inkLayers.count == 1, let ink = inkLayers.first else {
            throw LayerError.notExactlyOneInkLayer(pageID: pageID, count: inkLayers.count)
        }
        guard layers.last == ink else {
            throw LayerError.inkLayerNotLast(pageID: pageID)
        }
        guard ink.pageSpaceTransform.isIdentity else {
            throw LayerError.nonIdentityInkTransform(layerID: ink.layerID)
        }
        return (ink, refused)
    }

    /// Pages whose file, as read this session, carried a layer this build
    /// refused. Like `lastKnownIndex` this is a record of the store's own
    /// reads, not a second authority: it exists so `save` can fail loud
    /// rather than silently drop a refused layer. The session never dirties
    /// such a page — it refuses input — so this guard firing is a defect.
    private var pagesRefusedOnLoad: Set<UUID> = []

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
    ///
    /// The layer *list* is the caller's — `EditorSession` is its one writer,
    /// exactly as it is page order's — and the store only refuses lists that
    /// violate the layer invariants. A page this store loaded with a refused
    /// layer is refused outright: writing it would replace a list carrying a
    /// layer this build cannot re-encode, which is the silent drop the layer
    /// model forbids. Refusing the save is the smaller mechanism than
    /// preserving the original envelope bytes through a re-encode, and it is
    /// behavior-neutral, because a page carrying a refused layer refuses
    /// input and therefore never has anything to save.
    func save(index: DocumentIndex, changedPages: [UUID: [LayerEnvelope]]) throws {
        let validated = try index.validated()

        for pageID in changedPages.keys where !validated.pageIDs.contains(pageID) {
            throw DocumentIndexError.missingPageFile(pageID)
        }

        // Every page is validated before any page is written, so a batch that
        // would fail cannot leave half its pages already rewritten.
        for (pageID, layers) in changedPages {
            guard !pagesRefusedOnLoad.contains(pageID) else {
                throw LayerError.refusedLayerWouldBeLost(pageID: pageID)
            }
            let (_, refused) = try Self.validated(layers: layers, pageID: pageID)
            if let first = refused.first {
                throw LayerError.unknownKindOnSave(layerID: first.layerID, kind: first.kind)
            }
        }

        try createDirectoriesIfNeeded()

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        for (pageID, layers) in changedPages {
            let page = PageFile(pageID: pageID, layers: layers)
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
            .save,
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
