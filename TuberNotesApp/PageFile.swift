import Foundation

/// The page file and the shape of one page's write, phase 3 of
/// `Docs/Forks/CanvasFeatureComplete.md`: layer envelopes split out of the page
/// file into `layers/<layerID>.plist`, one envelope per file.
///
/// The split lands here and not earlier because here is where the property it
/// buys first becomes observable: with a 50 MB import on the page, "annotating
/// page 4 writes one small file, never the pdf envelope, never the asset" is a
/// claim a test can make. Before a heavy kind existed there was nothing to
/// observe, and a directory level that proves nothing is a directory level that
/// costs.

/// One page's durable contents: its own `pageID` and the **ordered list of
/// layer IDs** that make it up. The envelopes themselves are one file each,
/// under `layers/`.
///
/// `pageID` is repeated here only so that a page file read from disk can be
/// checked against the name it was filed under. It is the one deliberate
/// exception to the no-duplication rule, and it exists to catch a mixed-up or
/// truncated directory rather than to be read as authority. Layer files carry
/// their own `layerID` for the same reason and are checked the same way.
///
/// ## Three forms are read; exactly one is written
///
/// Following phase 1's precedent literally — read both forms, write forward on
/// the page's next save, never migrate eagerly:
///
/// | On disk | Written by | Read as |
/// |---|---|---|
/// | `{ pageID, drawingData }` | before phase 1 | one `ink` layer, ID minted at read |
/// | `{ pageID, layers }` | phases 1–2 | those envelopes, inline |
/// | `{ pageID, layerIDs }` | phase 3 onward | those layer files, in order |
///
/// `encode(to:)` writes the third form and only ever the third form, so a
/// superseded form cannot be written back by any code path — which is the
/// property that makes write-forward a fact rather than a discipline. Tests
/// that must put an older form on disk own their own fixture type for it,
/// exactly as phase 1's `LegacyPageFile` does.
struct PageFile: Codable, Sendable, Equatable {
    let pageID: UUID
    let layerIDs: [UUID]

    /// The envelopes, when this page file was read in a pre-split form and
    /// carries them itself. `nil` for a page in the current form, whose
    /// envelopes are in `layers/`.
    ///
    /// It is not encoded. Its only readers are the load path, which uses these
    /// envelopes instead of reading layer files, and the save path, which reads
    /// its presence as "this page has not been split yet, so write all of its
    /// layer files forward".
    let inlineLayers: [LayerEnvelope]?

    /// The current form: a page as an ordered list of layer IDs.
    init(pageID: UUID, layerIDs: [UUID]) {
        self.pageID = pageID
        self.layerIDs = layerIDs
        self.inlineLayers = nil
    }

    private init(pageID: UUID, inlineLayers: [LayerEnvelope]) {
        self.pageID = pageID
        self.layerIDs = inlineLayers.map(\.layerID)
        self.inlineLayers = inlineLayers
    }

    private enum CodingKeys: String, CodingKey {
        case pageID
        case layerIDs
        /// The phase 1–2 form: envelopes inline in the page file. Read-only —
        /// encoding never writes it.
        case layers
        /// The pre-layer form: bare drawing bytes. Read-only for the same
        /// reason, and still read because a document written before phase 1 is
        /// still a document.
        case drawingData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pageID = try container.decode(UUID.self, forKey: .pageID)

        if let ids = try container.decodeIfPresent([UUID].self, forKey: .layerIDs) {
            self.init(pageID: pageID, layerIDs: ids)
            return
        }
        if let envelopes = try container.decodeIfPresent([LayerEnvelope].self, forKey: .layers) {
            self.init(pageID: pageID, inlineLayers: envelopes)
            return
        }
        // A pre-layer page file is a one-ink-layer page. The layer's identity
        // is minted at read time and becomes durable only when the page is next
        // written, so the file on disk is untouched until then.
        //
        // Minted means per-decode: such a page's layerID differs across load,
        // evict, and reload until its first split save durably pins one. Phase
        // 1 recorded this as benign-today and load-bearing at phase 3, because
        // `layers/<layerID>.plist` makes layer identity referenceable. It holds
        // here: the mint reaches disk as a layer *file name* only through the
        // same save that writes the page file naming it, and both are written
        // in one pass, leaf first. Nothing can point at a mint that a save has
        // not pinned.
        let drawingData = try container.decode(Data.self, forKey: .drawingData)
        self.init(
            pageID: pageID,
            inlineLayers: [
                LayerEnvelope(
                    layerID: UUID(),
                    kind: .ink,
                    payload: drawingData,
                    pageSpaceTransform: .identity
                )
            ]
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageID, forKey: .pageID)
        try container.encode(layerIDs, forKey: .layerIDs)
    }
}

/// One page's contribution to a save: its complete ordered layer list, and
/// which of those layers' bytes actually changed.
///
/// Both are needed and neither is derivable from the other. The **complete**
/// list is what makes validation total — a page's invariants (exactly one ink
/// layer, ink last, its transform identity) are properties of the whole list,
/// and a store that only saw the changed layers could not check them without
/// reading back every layer it was not asked to write. The **changed set** is
/// what makes the write minimal, and it comes from the caller because the
/// caller is the one thing that knows: `EditorSession` is the sole writer of a
/// page's layer list and tracks, per layer, what the last successful save
/// wrote. The alternative — the store comparing each envelope against the file
/// on disk — would read the ink layer back on every save to discover it had not
/// changed, which is the read this whole format exists to avoid.
///
/// The claim is not taken on trust. Before any write the store checks that
/// every layer named by the page either is being written now or already has a
/// file, so a caller that understates what changed produces a loud refusal
/// rather than a page file naming a layer that is not there.
struct PageWrite: Sendable, Equatable {
    let pageID: UUID
    /// The page's layers, in order, ink last.
    let layers: [LayerEnvelope]
    /// The subset whose files must be rewritten. A layer named by `layers` and
    /// absent here is asserted to be already durable, byte for byte.
    let changedLayerIDs: Set<UUID>

    init(pageID: UUID, layers: [LayerEnvelope], changedLayerIDs: Set<UUID>) {
        self.pageID = pageID
        self.layers = layers
        self.changedLayerIDs = changedLayerIDs
    }

    /// A page written whole: every layer changed. The first save of a document
    /// and the tests use it; the ordinary autosave path does not, because
    /// "every layer changed" is exactly what an ink edit is not.
    init(pageID: UUID, layers: [LayerEnvelope]) {
        self.init(
            pageID: pageID,
            layers: layers,
            changedLayerIDs: Set(layers.map(\.layerID))
        )
    }
}
