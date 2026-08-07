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
/// A document is a directory: one index file, one file per page under
/// `pages/`, and the imported originals under `assets/`. Every individual write
/// is atomic; there is no atomicity across files, and none is needed because
/// writes go leaf to root — assets, then page files, then the index — so an
/// interrupted save leaves an orphan at some level and a dangling ref at none.
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
    private var assetsDirectoryURL: URL { directoryURL.appendingPathComponent("assets") }

    private func pageURL(_ pageID: UUID) -> URL {
        pagesDirectoryURL.appendingPathComponent("\(pageID.uuidString).plist")
    }

    private func assetURL(_ assetID: UUID, _ format: AssetFormat) -> URL {
        assetsDirectoryURL.appendingPathComponent(
            "\(assetID.uuidString).\(format.fileExtension)"
        )
    }

    /// The URL a ref names, or `nil` when this build cannot name its file at
    /// all — an unrecognized format is refused, never guessed at.
    private func assetURL(_ ref: ImageLayerRef) -> URL? {
        guard let fileName = ref.fileName else { return nil }
        return assetsDirectoryURL.appendingPathComponent(fileName)
    }

    // MARK: - Assets

    /// Writes one imported original. **Assets are write-once and immutable**
    /// (`Docs/Forks/CanvasFeatureComplete.md` — Durable form): there is no
    /// update entry point, and this one refuses an ID that already exists.
    ///
    /// Refused loudly rather than accepted as an identity-verifying no-op, on
    /// two grounds. The cheap one: verifying identity means reading the whole
    /// existing asset back — tens of megabytes — to authorize a write no
    /// correct caller makes, where refusing costs one `stat`. The load-bearing
    /// one: write-once is what makes an asset-derived render impossible to
    /// stale, so a silently tolerated overwrite would break the property the
    /// render cache's whole safety argument rests on. Asset IDs are minted per
    /// import, so reaching this means an ID was reused, which is a defect in
    /// whatever minted it, not a condition to smooth over. A failed import
    /// retries with a fresh ID and leaves an inert orphan behind.
    ///
    /// This is the leaf of the leaf-to-root write order: the asset is durable
    /// before any page file may name it, and `save` enforces that rather than
    /// trusting it.
    func writeAsset(_ bytes: Data, assetID: UUID, format: AssetFormat) throws {
        let url = assetURL(assetID, format)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AssetError.assetAlreadyExists(assetID: assetID)
        }
        try createDirectoryIfNeeded(assetsDirectoryURL)
        try bytes.write(to: url, options: .atomic)
        CanvasLog.event(.save, "wrote asset \(assetID) (\(format.rawValue), \(bytes.count) bytes)")
    }

    /// One asset's original bytes. Decoding them is the canvas runtime's, off
    /// this actor and off the main thread; reading them is this store's, because
    /// `DocumentStore` is the only thing here that touches files.
    func loadAsset(assetID: UUID, format: AssetFormat) throws -> Data {
        try Data(contentsOf: assetURL(assetID, format))
    }

    func assetExists(assetID: UUID, format: AssetFormat) -> Bool {
        FileManager.default.fileExists(atPath: assetURL(assetID, format).path)
    }

    private func assetExists(_ ref: ImageLayerRef) -> Bool {
        guard let url = assetURL(ref) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Deletes an asset no layer references any more — delete-inline
    /// reclamation, the mirror of the write order: the page file drops the ref
    /// first, the asset dies second. Returns whether it deleted anything.
    ///
    /// The question "is anything still referencing this?" is answered from the
    /// page files on disk, not from memory, and that is what makes the ordering
    /// sound rather than merely intended: a caller whose page write failed
    /// still has the ref on disk, so the scan finds it and the asset lives.
    ///
    /// **When it cannot tell, it deletes nothing.** A layer whose kind or
    /// payload this build cannot open might reference any asset, so one
    /// anywhere in the document suspends reclamation entirely. That is the
    /// conservative half of the sweep-on-open that `failure-has-a-taxonomy`
    /// gates: deleting the wrong file is a durability failure, and an
    /// unreclaimed asset is merely heavy.
    ///
    /// Cost: one small decode per page file, at the frequency a user deletes a
    /// layer. It is not on an interaction path and not on the save path.
    @discardableResult
    func deleteAssetIfUnreferenced(assetID: UUID, format: AssetFormat) throws -> Bool {
        let url = assetURL(assetID, format)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        if FileManager.default.fileExists(atPath: pagesDirectoryURL.path) {
            let pageFiles = try FileManager.default.contentsOfDirectory(
                at: pagesDirectoryURL,
                includingPropertiesForKeys: nil
            )
            for pageFile in pageFiles where pageFile.pathExtension == "plist" {
                let page = try PropertyListDecoder().decode(
                    PageFile.self,
                    from: Data(contentsOf: pageFile)
                )
                if Self.references(assetID, in: page.layers) { return false }
            }
        }

        try FileManager.default.removeItem(at: url)
        CanvasLog.event(.save, "reclaimed asset \(assetID); its last layer was deleted")
        return true
    }

    /// Whether these layers may reference `assetID` — deliberately "may": a
    /// layer this build cannot open counts as a reference, because the
    /// alternative is deleting a file something is using.
    private static func references(_ assetID: UUID, in layers: [LayerEnvelope]) -> Bool {
        for layer in layers {
            switch classify(layer) {
            case .ink:
                continue
            case .image(_, let ref):
                if ref.assetID == assetID { return true }
            case .refused(let refusal):
                switch refusal.reason {
                case .unsupportedAssetFormat(let referenced, _):
                    if referenced == assetID { return true }
                case .unknownKind, .unreadablePayload:
                    CanvasLog.event(
                        .save,
                        "not reclaiming asset \(assetID): layer \(refusal.layerID) "
                            + "of kind \(refusal.kind) cannot be read, so what it "
                            + "references is unknown"
                    )
                    return true
                case .missingAsset:
                    // Never produced by classification, which does not look at
                    // the file system.
                    continue
                }
            }
        }
        return false
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
    /// the page loads, and the document opens. What keeps a later save from
    /// dropping the refusal lives in `save`, which re-reads the file it is
    /// about to replace — never in memory here.
    ///
    /// A layer whose asset file is not there is refused the same way, at the
    /// same scope: a dangling asset ref is fatal to its layer, and the page
    /// refuses input while carrying one, but the document opens.
    func loadPage(_ pageID: UUID) throws -> LoadedPage {
        let data = try Data(contentsOf: pageURL(pageID))
        let page = try PropertyListDecoder().decode(PageFile.self, from: data)
        guard page.pageID == pageID else {
            throw DocumentIndexError.pageIDMismatch(expected: pageID, found: page.pageID)
        }
        let validated = try Self.validated(layers: page.layers, pageID: pageID)

        // The one check that needs the file system, so it lives here rather
        // than in the pure validation above.
        var refused = validated.refused
        for image in validated.images where !assetExists(image.ref) {
            CanvasLog.event(
                .lifecycle,
                "page \(pageID): layer \(image.layer.layerID) references missing "
                    + "asset \(image.ref.assetID)"
            )
            refused.append(
                RefusedLayer(
                    layerID: image.layer.layerID,
                    kind: image.layer.kind,
                    reason: .missingAsset(image.ref.assetID)
                )
            )
        }

        return LoadedPage(
            inkLayerID: validated.ink.layerID,
            inkData: validated.ink.payload,
            staticLayers: validated.staticLayers,
            refusedLayers: refused
        )
    }

    /// One page's layers, sorted into what this build can act on.
    private struct ValidatedLayers {
        let ink: LayerEnvelope
        /// Every recognized layer below the ink, in order.
        let staticLayers: [LayerEnvelope]
        let images: [(layer: LayerEnvelope, ref: ImageLayerRef)]
        let refused: [RefusedLayer]
    }

    /// The layer invariants, checked in one place for both directions: layer
    /// IDs are unique within the page, a page has exactly one `ink` layer,
    /// that layer is last in the list, its transform is identity, and every
    /// asset-backed layer's transform is invertible. A layer this build cannot
    /// open is not a violation — it is returned as a refusal for the caller to
    /// scope.
    ///
    /// Nothing here touches the file system, so it is the same check on the
    /// way in and on the way out.
    private static func validated(
        layers: [LayerEnvelope],
        pageID: UUID
    ) throws -> ValidatedLayers {
        // Unique within the page, mirroring the document-level "Page IDs are
        // unique and stable" rule one level down.
        var seen = Set<UUID>()
        for layer in layers where !seen.insert(layer.layerID).inserted {
            throw LayerError.duplicateLayerID(pageID: pageID, layerID: layer.layerID)
        }

        var refused: [RefusedLayer] = []
        var inkLayers: [LayerEnvelope] = []
        var staticLayers: [LayerEnvelope] = []
        var images: [(layer: LayerEnvelope, ref: ImageLayerRef)] = []
        for layer in layers {
            switch classify(layer) {
            case .ink(let ink):
                inkLayers.append(ink)
            case .image(let envelope, let ref):
                guard envelope.pageSpaceTransform.isInvertible else {
                    throw LayerError.nonInvertibleLayerTransform(layerID: envelope.layerID)
                }
                staticLayers.append(envelope)
                images.append((envelope, ref))
            case .refused(let refusal):
                refused.append(refusal)
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
        return ValidatedLayers(
            ink: ink,
            staticLayers: staticLayers,
            images: images,
            refused: refused
        )
    }

    /// What one envelope is to this build. The refusal cases are the whole
    /// reason `kind` and `format` are durable strings rather than enums.
    private enum LayerClassification {
        case ink(LayerEnvelope)
        case image(LayerEnvelope, ImageLayerRef)
        case refused(RefusedLayer)
    }

    private static func classify(_ layer: LayerEnvelope) -> LayerClassification {
        switch layer.recognizedKind {
        case .ink:
            return .ink(layer)
        case .image:
            let ref: ImageLayerRef
            do {
                ref = try ImageLayerRef(payload: layer.payload)
            } catch {
                return .refused(
                    RefusedLayer(
                        layerID: layer.layerID,
                        kind: layer.kind,
                        reason: .unreadablePayload
                    )
                )
            }
            guard ref.recognizedFormat != nil else {
                return .refused(
                    RefusedLayer(
                        layerID: layer.layerID,
                        kind: layer.kind,
                        reason: .unsupportedAssetFormat(
                            assetID: ref.assetID,
                            format: ref.format
                        )
                    )
                )
            }
            return .image(layer, ref)
        case nil:
            return .refused(
                RefusedLayer(layerID: layer.layerID, kind: layer.kind, reason: .unknownKind)
            )
        }
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
    ///
    /// The layer *list* is the caller's — `EditorSession` is its one writer,
    /// exactly as it is page order's — and the store only refuses lists that
    /// violate the layer invariants. A page whose file on disk carries a
    /// refused layer is refused outright: writing it would replace a list
    /// carrying a layer this build cannot re-encode, which is the silent drop
    /// the layer model forbids. Refusing the save is the smaller mechanism
    /// than preserving the original envelope bytes through a re-encode, and
    /// it is behavior-neutral, because a page carrying a refused layer
    /// refuses input and therefore never has anything to save.
    func save(index: DocumentIndex, changedPages: [UUID: [LayerEnvelope]]) throws {
        let validated = try index.validated()

        for pageID in changedPages.keys where !validated.pageIDs.contains(pageID) {
            throw DocumentIndexError.missingPageFile(pageID)
        }

        // Every page is validated before any page is written, so a batch that
        // would fail cannot leave half its pages already rewritten.
        for (pageID, layers) in changedPages {
            let validatedLayers = try Self.validated(layers: layers, pageID: pageID)
            if let first = validatedLayers.refused.first {
                throw LayerError.refusedLayerOnSave(layerID: first.layerID, kind: first.kind)
            }
            // Leaf-to-root, enforced rather than described: a page file may
            // not name an asset that is not already durable. With this check,
            // an interruption anywhere in an import leaves an orphan asset —
            // inert — and no page file can ever name one that is missing.
            for image in validatedLayers.images where !assetExists(image.ref) {
                throw LayerError.danglingAssetRef(
                    layerID: image.layer.layerID,
                    assetID: image.ref.assetID
                )
            }
            try refuseIfExistingFileCarriesAnUnrewritableLayer(pageID)
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

    /// Refuses to overwrite a page file that carries a layer this build could
    /// not write back — the guarantee that a refused layer is never silently
    /// dropped, sound by construction rather than by convention.
    ///
    /// "Could not write back", not "refused": a layer refused only because its
    /// **asset** is missing is fully understood as an envelope, and refusing to
    /// rewrite its page would make the page unrepairable, because deleting the
    /// broken layer is the repair and deleting it is a save.
    ///
    /// The check reads the file `save` is about to replace, so it holds for
    /// every store instance and every save entry point, not just one that
    /// happened to `loadPage` first; an in-memory record of refused loads
    /// would be blind to a page a second store never read. One small decode
    /// per changed page, on the actor and off the main thread by
    /// construction, on a path that already does file I/O by design — and it
    /// runs before any write, preserving validation-before-any-write.
    ///
    /// An existing file that cannot be decoded at all refuses the save the
    /// same way, by rethrowing: overwriting bytes this build cannot read is
    /// the same blind drop with a different cause. Such a page is
    /// `unreadable` in the session and never dirties, so a save reaching
    /// this is already a defect surfacing, not a path to smooth over.
    private func refuseIfExistingFileCarriesAnUnrewritableLayer(_ pageID: UUID) throws {
        let url = pageURL(pageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = try PropertyListDecoder().decode(
            PageFile.self,
            from: Data(contentsOf: url)
        )
        for layer in existing.layers {
            guard case .refused(let refusal) = Self.classify(layer),
                  !refusal.isReconstructable
            else { continue }
            throw LayerError.refusedLayerWouldBeLost(pageID: pageID)
        }
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
        for directory in [directoryURL, pagesDirectoryURL] {
            try createDirectoryIfNeeded(directory)
        }
    }

    /// `assets/` is created by the first asset write and not before, so a
    /// document that never imported anything does not carry an empty directory
    /// through every copy and backup of its package.
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
