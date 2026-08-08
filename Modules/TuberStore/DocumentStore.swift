import Foundation
import TuberCore
import TuberModel

/// The sole writer of the saved document (`Contract.md` — Owners, Durable form).
///
/// It is an actor so that encoding and disk I/O are off the main actor by
/// construction rather than by discipline, and so two saves can never interleave.
/// This is the one actor the contract permits beyond the main actor.
///
/// The store never reaches into the canvas. It receives complete immutable
/// values and returns only after they are durable.
///
/// A document is a directory: one index file, one file per page under `pages/`,
/// one file per layer under `layers/`, and the imported originals under
/// `assets/`. Every individual write is atomic; there is no atomicity across
/// files, and none is needed because writes go leaf to root — assets, then
/// layer files, then page files, then the index — so an interrupted save leaves
/// an orphan at some level and a dangling ref at none. Deletion is the mirror,
/// root to leaf: the page file drops the ref, the layer file dies, the asset
/// dies last.
package actor DocumentStore {
    private let directoryURL: URL

    /// The index as it currently exists on disk, as far as this store knows.
    ///
    /// It is what makes "write the index only if it changed" a decision rather
    /// than a guess. It is a cache of the store's own writes and reads, not a
    /// second authority: it is only ever assigned from a value that was just
    /// read from or successfully written to disk.
    private var lastKnownIndex: DocumentIndex?

    /// The index on disk is in a superseded form and must be written forward.
    ///
    /// Phase 1's precedent, at the index: read both forms, write forward on the
    /// next save, never migrate eagerly. It lives here rather than on
    /// `DocumentIndex` because it is a fact about the *file*, and because the
    /// clearing has to happen at the write — a flag the caller carried would
    /// either rewrite the index on every save forever or need the caller to
    /// know it had been honoured.
    ///
    /// A document that is never saved again keeps its old index, which is what
    /// "never migrate eagerly" means.
    private var indexOnDiskIsSupersededForm = false

    package init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    private var indexURL: URL { directoryURL.appendingPathComponent("document.plist") }
    private var pagesDirectoryURL: URL { directoryURL.appendingPathComponent("pages") }
    private var layersDirectoryURL: URL { directoryURL.appendingPathComponent("layers") }
    private var assetsDirectoryURL: URL { directoryURL.appendingPathComponent("assets") }

    private func pageURL(_ pageID: UUID) -> URL {
        pagesDirectoryURL.appendingPathComponent("\(pageID.uuidString).plist")
    }

    private func layerURL(_ layerID: UUID) -> URL {
        layersDirectoryURL.appendingPathComponent("\(layerID.uuidString).plist")
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
    package func writeAsset(_ bytes: Data, assetID: UUID, format: AssetFormat) throws {
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
    package func loadAsset(assetID: UUID, format: AssetFormat) throws -> Data {
        try Data(contentsOf: assetURL(assetID, format))
    }

    func assetExists(assetID: UUID, format: AssetFormat) -> Bool {
        FileManager.default.fileExists(atPath: assetURL(assetID, format).path)
    }

    private func assetExists(_ ref: ImageLayerRef) -> Bool {
        guard let url = assetURL(ref) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A `pdf` ref always names a file, unlike an image ref: the kind names the
    /// encoding, so there is no unrecognized format to refuse.
    private func assetURL(_ ref: PDFLayerRef) -> URL {
        assetsDirectoryURL.appendingPathComponent(ref.fileName)
    }

    private func assetExists(_ ref: PDFLayerRef) -> Bool {
        FileManager.default.fileExists(atPath: assetURL(ref).path)
    }

    /// Deletes an asset no layer references any more — delete-inline
    /// reclamation, the mirror of the write order: the page file drops the ref
    /// first, the asset dies second. Returns whether it deleted anything.
    ///
    /// The question "is anything still referencing this?" is answered from the
    /// files on disk, not from memory: a caller whose page write failed still
    /// has the old ref on disk, so the scan finds it and the asset lives.
    ///
    /// **That soundness has a boundary: the scan is blind to layer lists that
    /// exist only in memory.** A list a save has not yet landed — an import
    /// whose save failed — references the asset in the session and nowhere
    /// this scan looks, so deleting on its behalf would destroy a write-once
    /// asset its surviving layers still need. The caller owns that guard:
    /// `EditorSession.deleteLayer` reclaims only while no page holds an
    /// unsaved layer list.
    ///
    /// **Since the split, it scans every layer file, not only the referenced
    /// ones** — a strictly larger set than "what the pages name", so it can
    /// only ever be more conservative. That is deliberate. An orphan layer file
    /// pinning an asset costs bytes; a live layer whose asset was reclaimed
    /// underneath it costs the document. Pre-split page files still carry their
    /// envelopes inline, so those are scanned too and a document part-way
    /// through migration is answered correctly.
    ///
    /// **When it cannot tell, it deletes nothing.** A layer whose kind or
    /// payload this build cannot open might reference any asset, so one
    /// anywhere in the document suspends reclamation entirely. That is the
    /// conservative half of the sweep-on-open that `failure-has-a-taxonomy`
    /// gates: deleting the wrong file is a durability failure, and an
    /// unreclaimed asset is merely heavy.
    ///
    /// Cost: one small decode per layer file, at the frequency a user deletes a
    /// layer. It is not on an interaction path and not on the save path. The
    /// split made this cheaper per file, not dearer: a layer file is one
    /// envelope, where a page file used to be every envelope on the page
    /// including its ink.
    @discardableResult
    package func deleteAssetIfUnreferenced(assetID: UUID, format: AssetFormat) throws -> Bool {
        let url = assetURL(assetID, format)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        // Pre-split page files, whose envelopes are still inline.
        for pageFile in try plistFiles(in: pagesDirectoryURL) {
            let page = try PropertyListDecoder().decode(
                PageFile.self,
                from: Data(contentsOf: pageFile)
            )
            guard let inline = page.inlineLayers else { continue }
            if Self.references(assetID, in: inline) { return false }
        }

        for layerFile in try plistFiles(in: layersDirectoryURL) {
            let layer = try PropertyListDecoder().decode(
                LayerEnvelope.self,
                from: Data(contentsOf: layerFile)
            )
            if Self.references(assetID, in: [layer]) { return false }
        }

        try FileManager.default.removeItem(at: url)
        CanvasLog.event(.save, "reclaimed asset \(assetID); its last layer was deleted")
        return true
    }

    /// Deletes one page's file, if the index on disk no longer names it — the
    /// **first** step of the root-to-leaf deletion order, above layer files
    /// and assets.
    ///
    /// Referenced-ness is answered from the index on disk, for the reason the
    /// two steps below answer from the level above them: a page delete whose
    /// index write failed still has the page named on disk, so the scan finds
    /// it and the page file lives.
    ///
    /// **Its position in the order is load-bearing, and getting it wrong is
    /// silent.** `deleteLayerFileIfUnreferenced` decides by scanning page
    /// files; while this page's own file is still on disk it still names every
    /// one of the page's layers, so every layer file survives — and
    /// `deleteAssetIfUnreferenced` then scans those surviving layer files and
    /// keeps their assets too. Reclaiming leaves first therefore reclaims
    /// *nothing at all*, and leaves orphan layer files pinning assets for the
    /// life of the document. Root first, always.
    ///
    /// A missing index is not an error: the whole document is gone, so nothing
    /// references anything and the page file may go.
    @discardableResult
    package func deletePageFileIfUnreferenced(pageID: UUID) throws -> Bool {
        let url = pageURL(pageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        if FileManager.default.fileExists(atPath: indexURL.path) {
            let index = try PropertyListDecoder().decode(
                DocumentIndex.self,
                from: Data(contentsOf: indexURL)
            )
            if index.pageIDs.contains(pageID) { return false }
        }

        try FileManager.default.removeItem(at: url)
        CanvasLog.event(.save, "deleted page file \(pageID); the index no longer names it")
        return true
    }

    /// Deletes one layer's file, if no page still names it — the middle step of
    /// the root-to-leaf deletion order, between the page file dropping the ref
    /// and the asset dying.
    ///
    /// Referenced-ness is answered from the page files on disk for the same
    /// reason asset reclamation is: a delete whose page write failed still has
    /// the layer named on disk, so the scan finds it and the layer file lives.
    /// The scan is cheap in a way it could not have been before the split — a
    /// page file is now a list of IDs, so nothing has to decode an envelope to
    /// answer it.
    @discardableResult
    package func deleteLayerFileIfUnreferenced(layerID: UUID) throws -> Bool {
        let url = layerURL(layerID)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        for pageFile in try plistFiles(in: pagesDirectoryURL) {
            let page = try PropertyListDecoder().decode(
                PageFile.self,
                from: Data(contentsOf: pageFile)
            )
            if page.layerIDs.contains(layerID) { return false }
        }

        try FileManager.default.removeItem(at: url)
        CanvasLog.event(.save, "deleted layer file \(layerID); no page names it")
        return true
    }

    /// Every property list directly inside a directory, or nothing at all when
    /// the directory does not exist — `assets/` and `layers/` are created by
    /// their first write, so absence is a document that has none, not a fault.
    private func plistFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "plist" }
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
            case .pdf(_, let ref):
                // One import is one asset and one layer per source page, so an
                // asset is normally referenced by as many layers as the PDF has
                // pages. Deleting one of them must not take the file the other
                // forty-nine are still showing.
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
    package func load() throws -> DocumentIndex? {
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
            indexOnDiskIsSupersededForm = index.wasReadInSupersededForm
            if index.wasReadInSupersededForm {
                CanvasLog.event(
                    .lifecycle,
                    "index read in the pre-per-page-geometry form; \(index.pages.count) "
                        + "page(s) took the document-wide geometry and it will be "
                        + "written forward on the next save"
                )
            }
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
    package func loadPage(_ pageID: UUID) throws -> LoadedPage {
        let data = try Data(contentsOf: pageURL(pageID))
        let page = try PropertyListDecoder().decode(PageFile.self, from: data)
        guard page.pageID == pageID else {
            throw DocumentIndexError.pageIDMismatch(expected: pageID, found: page.pageID)
        }
        let validated = try Self.validated(
            layers: try layers(of: page),
            pageID: pageID
        )

        // The one check that needs the file system, so it lives here rather
        // than in the pure validation above.
        var refused = validated.refused
        for backed in validated.assetBacked where !assetExists(backed.ref) {
            CanvasLog.event(
                .lifecycle,
                "page \(pageID): layer \(backed.layer.layerID) references missing "
                    + "asset \(backed.ref.assetID)"
            )
            refused.append(
                RefusedLayer(
                    layerID: backed.layer.layerID,
                    kind: backed.layer.kind,
                    reason: .missingAsset(backed.ref.assetID)
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

    /// One page's layer envelopes, wherever they live.
    ///
    /// A page file in the current form names its layers and they are one file
    /// each; a page file written before phase 3 carries them inline and is read
    /// exactly as written until its next save moves it forward. Both produce
    /// the same list, so everything downstream of here — validation, refusal
    /// scoping, the save path's checks — is blind to which form it came from.
    ///
    /// **A dangling layer ref is fatal, an orphan layer file is inert.** The
    /// same rule as page files, one level down: a named layer that is not there
    /// throws, and a layer file nothing names is simply never read.
    private func layers(of page: PageFile) throws -> [LayerEnvelope] {
        if let inline = page.inlineLayers { return inline }
        return try page.layerIDs.map { layerID in
            let url = layerURL(layerID)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LayerError.missingLayerFile(pageID: page.pageID, layerID: layerID)
            }
            let envelope = try PropertyListDecoder().decode(
                LayerEnvelope.self,
                from: Data(contentsOf: url)
            )
            guard envelope.layerID == layerID else {
                throw LayerError.layerFileIDMismatch(
                    expected: layerID,
                    found: envelope.layerID
                )
            }
            return envelope
        }
    }

    /// An asset-backed layer's file, resolved. The two questions the store asks
    /// of every such layer — does the asset exist, and which asset is it — have
    /// the same answer whatever the kind, so they are asked in one place and
    /// the kinds converge here.
    private struct ResolvedAsset: Equatable {
        let assetID: UUID
        let fileName: String
    }

    private func assetExists(_ resolved: ResolvedAsset) -> Bool {
        FileManager.default.fileExists(
            atPath: assetsDirectoryURL.appendingPathComponent(resolved.fileName).path
        )
    }

    /// One page's layers, sorted into what this build can act on.
    private struct ValidatedLayers {
        let ink: LayerEnvelope
        /// Every recognized layer below the ink, in order.
        let staticLayers: [LayerEnvelope]
        let assetBacked: [(layer: LayerEnvelope, ref: ResolvedAsset)]
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
        var assetBacked: [(layer: LayerEnvelope, ref: ResolvedAsset)] = []
        for layer in layers {
            switch classify(layer) {
            case .ink(let ink):
                inkLayers.append(ink)
            case .image(let envelope, let ref):
                guard envelope.pageSpaceTransform.isInvertible else {
                    throw LayerError.nonInvertibleLayerTransform(layerID: envelope.layerID)
                }
                guard let fileName = ref.fileName else {
                    // `classify` refuses an unrecognized format before it can
                    // reach here, so this is a defect in this file rather than
                    // a condition data can produce.
                    preconditionFailure(
                        "layer \(envelope.layerID) classified as an image but names no file"
                    )
                }
                staticLayers.append(envelope)
                assetBacked.append(
                    (envelope, ResolvedAsset(assetID: ref.assetID, fileName: fileName))
                )
            case .pdf(let envelope, let ref):
                guard envelope.pageSpaceTransform.isInvertible else {
                    throw LayerError.nonInvertibleLayerTransform(layerID: envelope.layerID)
                }
                guard ref.sourcePageIndex >= 0 else {
                    throw LayerError.negativeSourcePageIndex(
                        layerID: envelope.layerID,
                        index: ref.sourcePageIndex
                    )
                }
                staticLayers.append(envelope)
                assetBacked.append(
                    (envelope, ResolvedAsset(assetID: ref.assetID, fileName: ref.fileName))
                )
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
            assetBacked: assetBacked,
            refused: refused
        )
    }

    /// What one envelope is to this build. The refusal cases are the whole
    /// reason `kind` and `format` are durable strings rather than enums.
    private enum LayerClassification {
        case ink(LayerEnvelope)
        case image(LayerEnvelope, ImageLayerRef)
        case pdf(LayerEnvelope, PDFLayerRef)
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
        case .pdf:
            let ref: PDFLayerRef
            do {
                ref = try PDFLayerRef(payload: layer.payload)
            } catch {
                return .refused(
                    RefusedLayer(
                        layerID: layer.layerID,
                        kind: layer.kind,
                        reason: .unreadablePayload
                    )
                )
            }
            // No format check, and no format field to check: a `pdf` layer's
            // asset is a PDF by definition of the kind. See `PDFLayerRef`.
            return .pdf(layer, ref)
        case nil:
            return .refused(
                RefusedLayer(layerID: layer.layerID, kind: layer.kind, reason: .unknownKind)
            )
        }
    }

    // MARK: - Save

    /// Writes the layer files that changed, then the page files whose layer
    /// lists changed, then the index if it changed.
    ///
    /// The ordering is the contract's, not an optimization: leaf to root, so an
    /// interruption leaves an orphan at some level and a dangling ref at none.
    /// A crash after the layer writes and before the page write leaves layer
    /// files nothing names; after the page writes and before the index write,
    /// a page file nothing names. Both are ignored on load. Every reverse
    /// order names a file that does not exist, which is a document that cannot
    /// be opened.
    ///
    /// **A save writes only what changed, at the finest granularity the form
    /// has** — which since the split is one layer. Ink on page 4 of a fifty-page
    /// import writes page 4's ink layer file and nothing else: not the `pdf`
    /// envelope beneath it, not page 4's own page file, whose layer list did
    /// not change, not the other pages, not the asset, not the index. That
    /// sentence is the whole reason this level exists, and
    /// `PDFLayerTests.inkOnOnePageWritesOnlyThatPagesInkLayer` is it as an
    /// assertion.
    ///
    /// Passing a page that did not change is a defect rather than a waste: it is
    /// the whole-document rewrite this format exists to prevent. Passing a page
    /// whose layers all turn out to be unchanged is not — that is what an
    /// index-only save looks like from here, and it writes nothing.
    ///
    /// The layer *list* is the caller's — `EditorSession` is its one writer,
    /// exactly as it is page order's — and the store only refuses lists that
    /// violate the layer invariants. A page whose file on disk names a layer
    /// this build cannot re-encode, and which this write would drop, is refused
    /// outright: that is the silent drop the layer model forbids. Refusing the
    /// save is the smaller mechanism than preserving the original envelope
    /// bytes through a re-encode. The refusal's scope is the page — see the
    /// per-page planning below and `PageSaveRefusal`.
    package func save(index: DocumentIndex, pages: [PageWrite]) throws {
        let validated = try index.validated()

        var seenPages = Set<UUID>()
        for write in pages {
            guard validated.pageIDs.contains(write.pageID) else {
                throw DocumentIndexError.missingPageFile(write.pageID)
            }
            precondition(
                seenPages.insert(write.pageID).inserted,
                "page \(write.pageID) appears twice in one save; a page has one "
                    + "generation per pass and there is never more than one pass"
            )
        }

        // Everything is decided before anything is written, so a page that
        // would fail cannot leave half its files already replaced.
        //
        // **A refusal is the page's, never the batch's.** A page that cannot
        // be planned — a write that would drop a layer this build cannot
        // rewrite, a dangling asset ref — refuses its own save and no other
        // page's: every page that plans cleanly is written and durable first,
        // and the refusal is thrown after them, carrying every refused page,
        // so it is loud without punishing the pages that did nothing wrong.
        // Refusing the whole batch left ink on every other page knowingly
        // unsaved for as long as one poisoned page existed, which is a
        // durability failure the contract does not ask for.
        var plans: [PagePlan] = []
        var refusals: [PageRefusal] = []
        for write in pages {
            do {
                plans.append(try plan(for: write))
            } catch {
                CanvasLog.event(.save, "page \(write.pageID) refused its save: \(error)")
                refusals.append(
                    PageRefusal(pageID: write.pageID, reason: String(describing: error))
                )
            }
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        if plans.contains(where: { !$0.layersToWrite.isEmpty }) {
            try createDirectoryIfNeeded(layersDirectoryURL)
        }
        var layerFilesWritten = 0
        for plan in plans {
            for layer in plan.layersToWrite {
                try encoder.encode(layer).write(
                    to: layerURL(layer.layerID),
                    options: .atomic
                )
                layerFilesWritten += 1
            }
        }

        if plans.contains(where: \.pageFileNeedsWriting) {
            try createDirectoriesIfNeeded()
        }
        var pageFilesWritten = 0
        for plan in plans where plan.pageFileNeedsWriting {
            let page = PageFile(pageID: plan.pageID, layerIDs: plan.layerIDs)
            try encoder.encode(page).write(to: pageURL(plan.pageID), options: .atomic)
            pageFilesWritten += 1
        }

        // The cached index is a hint about disk, never an authority on it. If
        // the file is not actually there — a failed earlier write, or anything
        // that removed it underneath us — skipping the write would leave page
        // files with no index naming them, which is the unopenable document
        // `Contract.md` — Durable form's write ordering exists to prevent. One
        // `stat` per save is nothing next to the page write it guards.
        //
        // An index still in a superseded form is rewritten even when nothing
        // about the document changed — the page-file rule one level up
        // (`PagePlan.pageFileNeedsWriting` rewrites a page file whose envelopes
        // are still inline). `encode(to:)` writes only the current form, so
        // one write is the whole migration and the flag is cleared by it.
        let indexNeedsWriting = lastKnownIndex != validated
            || indexOnDiskIsSupersededForm
            || !FileManager.default.fileExists(atPath: indexURL.path)
        // A refused page whose page file never landed must not be named by the
        // index: the refusal would silently convert into a dangling page ref,
        // which is an unopenable document. Withholding the index write keeps
        // such a page an orphan-in-waiting instead, and the thrown refusal
        // says the index was not written so the caller keeps it dirty.
        let refusedPageIsMissingOnDisk = refusals.contains {
            !FileManager.default.fileExists(atPath: pageURL($0.pageID).path)
        }
        var indexWritten = false
        if indexNeedsWriting && !refusedPageIsMissingOnDisk {
            try createDirectoriesIfNeeded()
            try encoder.encode(validated).write(to: indexURL, options: .atomic)
            lastKnownIndex = validated
            indexOnDiskIsSupersededForm = false
            indexWritten = true
        }

        CanvasLog.event(
            .save,
            "wrote \(layerFilesWritten) layer file(s) and \(pageFilesWritten) page "
                + "file(s) across \(pages.count) changed page(s) of "
                + "\(validated.pageIDs.count); index rewritten=\(indexWritten); "
                + "refused=\(refusals.count)"
        )

        if !refusals.isEmpty {
            throw PageSaveRefusal(refusedPages: refusals, indexWritten: indexWritten)
        }
    }

    /// What one page's write will actually touch, decided before anything is
    /// written.
    private struct PagePlan {
        let pageID: UUID
        let layerIDs: [UUID]
        let layersToWrite: [LayerEnvelope]
        let pageFileNeedsWriting: Bool
    }

    private func plan(for write: PageWrite) throws -> PagePlan {
        let validatedLayers = try Self.validated(layers: write.layers, pageID: write.pageID)
        if let first = validatedLayers.refused.first {
            throw LayerError.refusedLayerOnSave(layerID: first.layerID, kind: first.kind)
        }
        // Leaf-to-root, enforced rather than described: no file may name an
        // asset that is not already durable. With this check, an interruption
        // anywhere in an import leaves an orphan asset — inert — and no layer
        // file can ever name one that is missing.
        for backed in validatedLayers.assetBacked where !assetExists(backed.ref) {
            throw LayerError.danglingAssetRef(
                layerID: backed.layer.layerID,
                assetID: backed.ref.assetID
            )
        }

        let existing = try existingPageFile(write.pageID)
        let layerIDs = write.layers.map(\.layerID)

        // A page file this build has not split yet writes all of its layers
        // forward, whatever the caller claims changed — the caller is talking
        // about envelope *values*, and none of these layers has a file yet.
        // Phase 1's write-forward precedent, one level down: read the old form,
        // write the new one on the page's next save, never migrate eagerly.
        let isAlreadySplit = existing.map { $0.inlineLayers == nil } ?? false
        let layersToWrite = isAlreadySplit
            ? write.layers.filter { write.changedLayerIDs.contains($0.layerID) }
            : write.layers

        // The caller's claim about what changed, checked rather than trusted: a
        // layer this write neither carries nor finds on disk would become a
        // dangling ref the moment the page file lands.
        let willBeWritten = Set(layersToWrite.map(\.layerID))
        for layerID in layerIDs where !willBeWritten.contains(layerID) {
            guard FileManager.default.fileExists(atPath: layerURL(layerID).path) else {
                throw LayerError.danglingLayerRef(pageID: write.pageID, layerID: layerID)
            }
        }

        try refuseIfThisWriteWouldDropAnUnrewritableLayer(write.pageID, existing, keeping: layerIDs)

        // The page file is bytes about identity and order alone, so it is
        // rewritten exactly when identity or order changed — or when the file
        // is in a superseded form, or absent.
        let pageFileNeedsWriting = existing.map {
            $0.inlineLayers != nil || $0.layerIDs != layerIDs || $0.pageID != write.pageID
        } ?? true

        return PagePlan(
            pageID: write.pageID,
            layerIDs: layerIDs,
            layersToWrite: layersToWrite,
            pageFileNeedsWriting: pageFileNeedsWriting
        )
    }

    /// The page file `save` is about to replace, or `nil` if there is none.
    ///
    /// A file that cannot be decoded at all rethrows, refusing the save:
    /// overwriting bytes this build cannot read is a blind drop with a
    /// different cause. Such a page is `unreadable` in the session and never
    /// dirties, so a save reaching this is a defect surfacing rather than a
    /// path to smooth over.
    private func existingPageFile(_ pageID: UUID) throws -> PageFile? {
        let url = pageURL(pageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try PropertyListDecoder().decode(PageFile.self, from: Data(contentsOf: url))
    }

    /// Refuses a write that would drop a layer this build could not write back
    /// — the guarantee that a refused layer is never silently dropped, sound by
    /// construction rather than by convention.
    ///
    /// "Could not write back", not "refused": a layer refused only because its
    /// **asset** is missing is fully understood as an envelope, and refusing to
    /// rewrite its page would make the page unrepairable, because deleting the
    /// broken layer is the repair and deleting it is a save.
    ///
    /// Since the split it reads only the layers this write **drops**, which is
    /// both cheaper and more precise than reading the whole page was: a layer
    /// the write keeps keeps its own file untouched and cannot be lost by
    /// anything happening here. It reads the file `save` is about to replace,
    /// so it holds for every store instance and every save entry point, not
    /// just one that happened to `loadPage` first; an in-memory record of
    /// refused loads would be blind to a page a second store never read. It
    /// runs before any write, preserving validation-before-any-write.
    ///
    /// A dropped layer whose *file* is already gone is let through: there is
    /// nothing left to lose, and the write is the repair for a page whose ref
    /// was dangling.
    private func refuseIfThisWriteWouldDropAnUnrewritableLayer(
        _ pageID: UUID,
        _ existing: PageFile?,
        keeping layerIDs: [UUID]
    ) throws {
        guard let existing else { return }
        let kept = Set(layerIDs)

        if let inline = existing.inlineLayers {
            for layer in inline where !kept.contains(layer.layerID) {
                try refuseIfUnrewritable(layer, pageID: pageID)
            }
            return
        }

        for layerID in existing.layerIDs where !kept.contains(layerID) {
            let url = layerURL(layerID)
            guard FileManager.default.fileExists(atPath: url.path) else {
                CanvasLog.event(
                    .save,
                    "page \(pageID) drops layer \(layerID), whose file was already "
                        + "gone; the write repairs a dangling ref"
                )
                continue
            }
            let envelope = try PropertyListDecoder().decode(
                LayerEnvelope.self,
                from: Data(contentsOf: url)
            )
            try refuseIfUnrewritable(envelope, pageID: pageID)
        }
    }

    private func refuseIfUnrewritable(_ layer: LayerEnvelope, pageID: UUID) throws {
        guard case .refused(let refusal) = Self.classify(layer),
              !refusal.isReconstructable
        else { return }
        throw LayerError.refusedLayerWouldBeLost(pageID: pageID)
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
    package static func defaultDirectoryURL() -> URL {
        applicationSupport().appendingPathComponent("JustACanvas.tubernotes")
    }
}
