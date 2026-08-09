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
        /// for a page that has no file yet — an appended page, a first launch,
        /// an inserted or duplicated page — and replaced by the loaded identity
        /// when the page's bytes arrive, so the identity a save writes is the
        /// one already on disk. There is no third case since the shim deletion:
        /// every page file this build can read already names its ink layer.
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
        ///
        /// **Keyed by layer, deliberately, and not a list like `staticLayers`
        /// beside it.** The only question ever asked of it is "what did the
        /// save write for *this* layer", asked once per layer on every save
        /// pass, and a list answers that by scanning. Order is `staticLayers`'s
        /// to state and is stated there; a second ordered copy would be a
        /// second claim about it.
        private(set) var savedStaticLayers: [UUID: LayerEnvelope] = [:]

        /// The layer list differs from what the last successful save wrote.
        /// Ink's own unsaved state is `ink`; this is the same fact for the
        /// list, and a page can carry either, both, or neither.
        private(set) var layersUnsaved = false

        /// The page exists on screen and nowhere else: it was appended and has
        /// never taken content, so no file was ever written for it.
        ///
        /// Swiping past the last page yields a page immediately (`Contract.md`
        /// — Navigation), and swiping past the last page is something a person
        /// does by reflex. A page nobody has written on is somewhere to stand,
        /// not a page of the document, so `EditorSession` withholds the
        /// trailing run of them from every save: an accidental overswipe cannot
        /// grow the file, and nothing has to reclaim anything later.
        ///
        /// It is cleared by the first thing that makes the page real — ink, or
        /// a layer — and from that moment the page saves like any other. It is
        /// a fact about the page's *durable* existence rather than about its
        /// ink, which is why it sits beside `ink` and not inside it: a
        /// never-written page's ink is genuinely clean, and the empty bytes it
        /// holds are exactly what a save of it would write.
        private(set) var neverWritten = false

        /// Which of the page's static layers differ from what the last
        /// successful save wrote. Compared by value, because an envelope is a
        /// value: a layer that was moved and moved back has not changed.
        ///
        /// IDs, because that is all the one caller ever wanted — it mapped the
        /// envelopes straight to their `layerID` and dropped them — and because
        /// the answer then costs one dictionary lookup and one comparison per
        /// layer. As a list on both sides this was a linear scan per layer, so
        /// the cost grew with the square of the layer count: the loop that
        /// punished the very thing the layer split was built to allow, sitting
        /// behind a computed property that reads free at its call site and runs
        /// once per dirty page on every debounced save.
        var changedStaticLayerIDs: Set<UUID> {
            var changed: Set<UUID> = []
            for layer in staticLayers where savedStaticLayers[layer.layerID] != layer {
                changed.insert(layer.layerID)
            }
            return changed
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

        /// An appended page: blank, writable, and not yet part of the document.
        ///
        /// Its ink is `clean` over the empty bytes — the same empty bytes the
        /// first launch's page is built with — because there is nothing unsaved
        /// about a page nobody has written on. That is what keeps an overswipe
        /// from arming the debounce, scheduling a save, and writing a page file
        /// the user never asked for; `neverWritten` is what keeps the index
        /// from naming it in the meantime.
        init(appended id: UUID) {
            self.id = id
            self.durable = Data()
            self.ink = .clean
            self.neverWritten = true
        }

        /// A copy of another page: a fresh identity for the page and for every
        /// layer of it, the source's ink already captured, and dirty by
        /// construction so the next pass writes the whole thing.
        ///
        /// **Fresh layer identities, shared assets.** A layer file is per
        /// layer, so two pages naming one `layerID` would contend for a single
        /// file and a delete on either would take the other's picture. The
        /// payloads are copied verbatim, so both layers name the same asset —
        /// which is exactly what the on-disk reference scan is built to
        /// answer, and what keeps duplicating a page carrying a fifty-megabyte
        /// import from copying fifty megabytes.
        ///
        /// `durable` is `nil` and not the source's bytes: it records what a
        /// successful save wrote *for this page*, and no save has written this
        /// page yet. Claiming otherwise would be a cache entry for a file that
        /// does not exist. Nothing reads it in the meantime — the ink is
        /// `.held`, which is where the copy's content actually lives.
        init(duplicating source: Page, id: UUID, capturedInk: UnsavedInk) {
            self.id = id
            self.durable = nil
            self.staticLayers = source.staticLayers.map { $0.withLayerID(UUID()) }
            // Nothing of this page has reached disk, so there is no record of
            // what a save wrote for it, and every layer counts as changed.
            self.savedStaticLayers = [:]
            self.layersUnsaved = true
            self.neverWritten = false
            self.ink = .held(capturedInk)
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
            savedStaticLayers = Self.keyed(loaded.staticLayers)
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
                // A layer makes the page real exactly as ink does — this is the
                // path an imported PDF page arrives by — so it is no longer a
                // page the document may withhold.
                neverWritten = false
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
                // The first stroke on an appended page is what makes it a page
                // of the document (`Contract.md` — Navigation).
                neverWritten = false
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
                // Or because the page has no file at all yet: a never-written
                // page stops being withheld the moment a written page lands
                // behind it, and the pass that discovers that must write it.
                precondition(
                    layersUnsaved || neverWritten,
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
            // The page has a file now, whatever it had before, so it is no
            // longer one the document may withhold.
            neverWritten = false
            if case .saving = ink { ink = .clean }
            // The same rule the ink follows, for the list: a list edited since
            // its capture is still unsaved, and says so, with no special case.
            savedStaticLayers = Self.keyed(layersWritten)
            if staticLayers == layersWritten { layersUnsaved = false }
        }

        /// A written layer list, by identity. `uniqueKeysWithValues` traps on a
        /// repeated `layerID`, which is the loud answer a page carrying the
        /// same layer twice deserves.
        private static func keyed(_ layers: [LayerEnvelope]) -> [UUID: LayerEnvelope] {
            Dictionary(uniqueKeysWithValues: layers.map { ($0.layerID, $0) })
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
            // A never-written page keeps its empty bytes for a blunter reason:
            // there is no file to reload them from. Dropping them would send
            // the page back to `.loading`, and the fetch it triggers would find
            // nothing and refuse a page that is merely blank.
            guard !neverWritten else { return }
            durable = nil
            if case .clean = ink { ink = .loading }
        }
    }
}
