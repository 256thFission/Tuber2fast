import Foundation
import TuberModel

extension EditorSession {
    /// Everything the session knows about one page. There is no second place.
    ///
    /// The invariant this type states and the rest of the session cannot
    /// violate: **a page's authoritative unsaved ink is in exactly one place,
    /// and `ink` names it.** `durable` is a cache of what the last successful
    /// save wrote, and it is the only thing prune may drop — pruning it can
    /// cost a reload, never ink. Whether the page is dirty is derived from
    /// `ink`, never stored beside it.
    ///
    /// Every mutation is a named transition with a precondition, so an illegal
    /// transition fails at the transition rather than as a wrong answer three
    /// frames later (`Contract.md` — Invalid states fail loud).
    struct Page {
        let id: UUID

        /// Exactly what the last successful save wrote, while it is still
        /// held. A cache, never an authority.
        private(set) var durable: Data?

        /// The durable identity of the page's single ink layer. Minted here
        /// for a page that has never been saved in layered form — an appended
        /// page, a first launch, a pre-layer file being read forward — and
        /// replaced by the loaded identity when the page's bytes arrive, so
        /// the identity a save writes is the one already on disk.
        private(set) var inkLayerID = UUID()

        /// Layers this build refused on load — a typed refused state, never a
        /// dropped one. The page refuses input while any exist: a page is
        /// editable exactly when its ink layer is editable and no layer is
        /// refused or unreadable. Such a page can never dirty from ink, so no
        /// ordinary save can carry the refusal; `DocumentStore.save` refuses
        /// one anyway. Deleting the refused layer is the one repair, and it
        /// clears the entry here as it clears the envelope below.
        private(set) var refusedLayers: [RefusedLayer] = []

        /// The page's recognized layers below the ink, in order — the session's
        /// custody copy of the layer list it is the sole writer of
        /// (`Contract.md` — Owners, golden rule 5). Refs, never bytes.
        ///
        /// It is custody rather than a cache: without it, an ink save would
        /// write a layer list containing only ink and silently delete the
        /// page's images. `durable` may be dropped by a prune; this may not,
        /// while it holds an unsaved change.
        private(set) var staticLayers: [LayerEnvelope] = []

        /// Exactly the static layers the last successful save wrote, or the
        /// load found. `durable` is this for ink; this is the same thing for
        /// the list, and it is a record of what reached disk rather than a
        /// second authority over what the page contains.
        ///
        /// It exists because the split made "which layers changed" a question
        /// worth answering per layer rather than per page: without it, adding a
        /// second image to a page would rewrite the first image's file, which
        /// is the whole-page rewrite one level down. Refs only — a few dozen
        /// bytes a page, never ink and never asset bytes.
        private(set) var savedStaticLayers: [LayerEnvelope] = []

        /// The layer list differs from what the last successful save wrote.
        /// Ink's own unsaved state is `ink`; this is the same fact for the
        /// list, and a page can carry either, both, or neither.
        private(set) var layersUnsaved = false

        /// The static layers whose durable bytes differ from what the last
        /// successful save wrote. Compared by value, because an envelope is a
        /// value: a layer that was moved and moved back has not changed.
        var changedStaticLayers: [LayerEnvelope] {
            staticLayers.filter { !savedStaticLayers.contains($0) }
        }

        private(set) var ink: Ink

        enum Ink {
            /// Bytes requested; the page is not writable yet.
            case loading
            /// The page's bytes could not be read. Refused and surfaced,
            /// never shown as an editable blank: ink written on a blank that
            /// stands in for an unreadable page would replace a page that
            /// merely could not be read with one that is genuinely empty.
            case unreadable(String)
            /// The page holds no unsaved ink; `durable` is the truth.
            case clean
            /// The authority is the page's live canvas, which holds unsaved ink.
            case live
            /// The session holds the page's unsaved ink — taken into custody
            /// when the page's canvas retired, or kept from a save that failed.
            case held(UnsavedInk)
            /// A save captured this page's ink and has not returned or thrown.
            case saving(UnsavedInk)
        }

        /// Unsaved ink in the session's custody: still a drawing value, or
        /// already serialized by a save pass. Custody, not a second copy
        /// (`Contract.md` — Owners, golden rule 5).
        enum UnsavedInk {
            case drawing(DrawingSnapshot)
            case serialized(Data)
        }

        /// Derived, never stored (`Contract.md` — Saving): the page carries
        /// unsaved work — ink, its layer list, or both — that no save has yet
        /// captured.
        var isDirty: Bool {
            if layersUnsaved { return true }
            switch ink {
            case .live, .held: return true
            case .loading, .unreadable, .clean, .saving: return false
            }
        }

        init(loading id: UUID) {
            self.id = id
            self.durable = nil
            self.ink = .loading
        }

        init(clean id: UUID, durable: Data) {
            self.id = id
            self.durable = durable
            self.ink = .clean
        }

        /// An appended page. Its unsaved ink is empty bytes, held by the
        /// session until the first save writes them.
        init(appended id: UUID) {
            self.id = id
            self.durable = nil
            self.ink = .held(.serialized(Data()))
        }

        // MARK: Transitions

        /// The page's saved bytes arrived from the store.
        mutating func bytesLoaded(_ loaded: LoadedPage) {
            guard case .loading = ink else {
                preconditionFailure(
                    "page \(id) received loaded bytes while \(ink); "
                        + "a load result must never replace newer ink"
                )
            }
            durable = loaded.inkData
            inkLayerID = loaded.inkLayerID
            staticLayers = loaded.staticLayers
            savedStaticLayers = loaded.staticLayers
            layersUnsaved = false
            refusedLayers = loaded.refusedLayers
            ink = .clean
        }

        /// The session rewrote this page's layer list — an import, a deletion.
        /// The list is durable state with one writer, so the change is recorded
        /// here and lands through the ordinary save path, exactly as ink does.
        mutating func layerListChanged(
            to layers: [LayerEnvelope],
            refusedLayers newRefusals: [RefusedLayer]
        ) {
            switch ink {
            case .clean, .live, .held, .saving:
                staticLayers = layers
                refusedLayers = newRefusals
                layersUnsaved = true
            case .loading, .unreadable:
                preconditionFailure(
                    "page \(id) changed its layer list while \(ink); a page whose "
                        + "own bytes are not here has no list to change"
                )
            }
        }

        /// The page's saved bytes could not be read.
        mutating func loadFailed(_ message: String) {
            guard case .loading = ink else {
                preconditionFailure("page \(id) reported a load failure while \(ink)")
            }
            ink = .unreadable(message)
        }

        /// The user edited the page's live canvas. Whatever the session was
        /// holding for this page is superseded: the canvas is the authority now.
        mutating func edited() {
            switch ink {
            case .clean, .live, .held, .saving:
                ink = .live
            case .loading, .unreadable:
                preconditionFailure(
                    "page \(id) reported an edit while \(ink); "
                        + "a page without its bytes must not accept ink"
                )
            }
        }

        /// The page's canvas is being released; the session takes custody of
        /// its drawing. Synchronous, before the release — `Contract.md` —
        /// Navigation.
        mutating func retired(handingOver snapshot: DrawingSnapshot) {
            switch ink {
            case .live:
                ink = .held(.drawing(snapshot))
            case .clean, .held, .saving:
                // The canvas's content is already accounted for: it equals
                // the durable bytes, the held value it was rebuilt from, or
                // the batch an in-flight save captured. Nothing newer exists
                // to take custody of.
                break
            case .loading, .unreadable:
                preconditionFailure(
                    "page \(id) retired a canvas while \(ink); "
                        + "such a page has no ink-bearing canvas to retire"
                )
            }
        }

        /// A save pass captured this page's unsaved ink into its batch.
        mutating func beginSaving(_ captured: UnsavedInk) {
            switch ink {
            case .live, .held:
                ink = .saving(captured)
            case .clean:
                // A page whose ink is clean is still captured when its layer
                // list changed: a page file is written whole, so the ink it is
                // written with is the ink already on disk. Without the layer
                // change there would be nothing to write, which is the
                // violation the other cases trap.
                precondition(
                    layersUnsaved,
                    "page \(id) captured for saving while clean with nothing unsaved"
                )
                ink = .saving(captured)
            case .loading, .unreadable:
                preconditionFailure("page \(id) captured for saving while \(ink)")
            case .saving:
                preconditionFailure(
                    "page \(id) captured twice; there is never more than one "
                        + "capture/save operation in flight"
                )
            }
        }

        /// The in-flight save serialized this page's drawing. Recorded so a
        /// failed write keeps the bytes rather than paying the encode twice,
        /// and so a rebuild during the save reads the freshest value. A page
        /// edited since capture is `.live` again and keeps its newer authority.
        mutating func serializedWhileSaving(_ data: Data) {
            if case .saving = ink { ink = .saving(.serialized(data)) }
        }

        /// The store returned: these bytes are durable. Acknowledgement
        /// follows evidence — the page becomes clean only if nothing edited it
        /// since its capture; one edited during the save is `.live` again and
        /// stays dirty with no special case (`Contract.md` — Saving).
        mutating func saveSucceeded(written data: Data, layersWritten: [LayerEnvelope]) {
            durable = data
            if case .saving = ink { ink = .clean }
            // The same rule the ink follows, for the list: a list edited since
            // its capture is still unsaved, and says so, with no special case.
            savedStaticLayers = layersWritten
            if staticLayers == layersWritten { layersUnsaved = false }
        }

        /// The store threw. The page stays dirty and keeps the bytes the save
        /// already paid to encode, so the retry serializes nothing twice.
        mutating func saveFailed(restoring data: Data) {
            if case .saving = ink { ink = .held(.serialized(data)) }
        }

        /// Drops the prunable cache once the page is far from the visible one.
        /// Only `durable` is droppable; unsaved ink is never touched
        /// (`Contract.md` — Performance, held-bytes bound).
        mutating func evicted() {
            // A page holding an unsaved layer change keeps its durable bytes:
            // they are the ink the pending page write must be written with, and
            // dropping them would leave the page dirty forever with nothing the
            // save path could capture. Unsaved work is never what a prune drops.
            guard !layersUnsaved else { return }
            durable = nil
            if case .clean = ink { ink = .loading }
        }
    }
}
