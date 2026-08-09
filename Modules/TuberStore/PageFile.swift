import Foundation
import TuberModel

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
/// One form is read and the same one is written, so both halves of `Codable`
/// are synthesized: a page file naming no layers has no reading at all and
/// throws, which is what makes a truncated or hand-damaged file surface as an
/// unreadable page rather than as a blank one.
struct PageFile: Codable, Sendable, Equatable {
    let pageID: UUID
    let layerIDs: [UUID]

    init(pageID: UUID, layerIDs: [UUID]) {
        self.pageID = pageID
        self.layerIDs = layerIDs
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
package struct PageWrite: Sendable, Equatable {
    package let pageID: UUID
    /// The page's layers, in order, ink last.
    package let layers: [LayerEnvelope]
    /// The subset whose files must be rewritten. A layer named by `layers` and
    /// absent here is asserted to be already durable, byte for byte.
    package let changedLayerIDs: Set<UUID>

    package init(pageID: UUID, layers: [LayerEnvelope], changedLayerIDs: Set<UUID>) {
        self.pageID = pageID
        self.layers = layers
        self.changedLayerIDs = changedLayerIDs
    }

    /// A page written whole: every layer changed. The first save of a document
    /// and the tests use it; the ordinary autosave path does not, because
    /// "every layer changed" is exactly what an ink edit is not.
    package init(pageID: UUID, layers: [LayerEnvelope]) {
        self.init(
            pageID: pageID,
            layers: layers,
            changedLayerIDs: Set(layers.map(\.layerID))
        )
    }
}
