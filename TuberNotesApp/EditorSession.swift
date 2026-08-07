import Foundation
import Observation

/// A layer edit the session refuses. Each is a caller's mistake or a page that
/// is not in a state to be edited — never a durable-form violation, which
/// `DocumentStore` owns and fails loud on.
enum LayerEditError: Error, Equatable {
    case sessionNotReady
    case pageNotFound(UUID)
    /// The page's own bytes are not here, or could not be read.
    case pageNotReady(UUID)
    /// The page carries a refused layer, so it takes no input.
    case pageRefusesInput(UUID)
    case layerNotFound(layerID: UUID, pageID: UUID)
}

/// Coordinates the canvas runtime and the document store (`Contract.md` — Owners).
///
/// It owns page order and identity, per-page ink state, and the active save
/// policy. Live drawings live in PencilKit and are captured only at save time.
/// `@Observable` is deliberate and narrow. SwiftUI observes `phase` and
/// `lastSaveError` — user-action-frequency values. It is forbidden to observe the
/// drawing, pan, zoom, or Pencil samples.
@MainActor
@Observable
final class EditorSession {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

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

        /// The layer list differs from what the last successful save wrote.
        /// Ink's own unsaved state is `ink`; this is the same fact for the
        /// list, and a page can carry either, both, or neither.
        private(set) var layersUnsaved = false

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

    private(set) var phase: Phase = .loading

    /// Surfaced so a failed autosave is visible
    private(set) var lastSaveError: String?

    /// The page the user is looking at. Page belongs to the session's
    var currentPageID: UUID { index.pageIDs[index.currentPageIndex] }

    /// The number of saved pages.
    var pageCount: Int { index.pageIDs.count }

    /// Read only by tests: `EditorSessionTests` draws through it to make
    /// `Contract.md` — Saving observable. The live canvas for the visible page,
    /// or `nil` before the runtime has laid out. The save path never reads it —
    /// `performOneSave` captures via `liveRuntime?.snapshot(at:)`.
    var currentCanvas: PageCanvasController? {
        liveRuntime?.livePage(at: index.currentPageIndex)
    }

    /// The paged canvas runtime, created once and owned here so that SwiftUI
    /// rebuilding its body cannot replace it.
    ///
    /// Created on first access, never in `init`, and that is not a style
    /// choice. `EditorSession` is built as the `App`'s `@State` initial value,
    /// which runs before UIKit has finished launching. A `PKCanvasView` built
    /// that early comes up with incomplete gesture state and takes UIKit down
    /// with it on the first touch — `-[UIGestureRecognizer
    /// _delayTouchesForEvent:]` inserting nil into an array. Every setting on
    /// the canvas was innocent; only the moment of construction mattered.
    ///
    /// First access is from the view body or `start()`, both after launch.
    var pages: PagedCanvasController {
        if let liveRuntime { return liveRuntime }
        let created = PagedCanvasController()
        created.contentForPage = { [weak self] pageIndex in
            self?.content(forPageAt: pageIndex) ?? .blank
        }
        created.onDrawingChanged = { [weak self] pageIndex in
            self?.drawingChanged(atPageIndex: pageIndex)
        }
        created.onPageRetiring = { [weak self] pageIndex, snapshot in
            self?.pageIsRetiring(atPageIndex: pageIndex, snapshot: snapshot)
        }
        created.onPageChanged = { [weak self] pageIndex in
            self?.currentPageChanged(to: pageIndex)
        }
        created.onReachedEndBoundary = { [weak self] in
            self?.appendPage()
        }
        liveRuntime = created
        return created
    }

    /// An intention from the SwiftUI root: which idealized shape a Pencil drag
    /// commits, or `nil` for ordinary freehand ink.
    ///
    /// Forwarded, not stored. The active tool is the paging runtime's state
    /// (`Contract.md` — Owners), and a copy kept here would be a second writer
    /// of it. This exists only so the root sends an intention to the session
    /// rather than reaching into the runtime, which is the one direction the
    /// owners diagram allows.
    func setShapeTool(_ kind: ShapeKind?) {
        pages.setShapeTool(kind)
    }

    @ObservationIgnored private var liveRuntime: PagedCanvasController?

    private let store: DocumentStore
    private let debounce: Duration

    /// The document index as last loaded or saved. `EditorSession` owns page
    /// identity and order (`Contract.md` — Owners); the canvas never sees it.
    ///
    /// It is not `@Observable` state: SwiftUI has nothing to render from it yet,
    /// and it changes at save frequency rather than user-action frequency.
    @ObservationIgnored private var index = DocumentIndex.newDocument(
        documentID: UUID(),
        pageID: UUID()
    )

    /// One `Page` per document page, in document order — the same order as
    /// `index.pageIDs`, which `alignedWithIndex()` enforces after every index
    /// mutation. Everything the session knows about a page's ink lives in its
    /// entry here; there is no second dictionary to disagree with it.
    @ObservationIgnored private var pageStates: [Page] = []

    /// Whether the index itself — page order or the current page — differs from
    /// what was last saved.
    private var indexDirty = false

    private var dirty: Bool { indexDirty || pageStates.contains(where: \.isDirty) }

    /// Pages whose bytes are being fetched. Prevents a scroll back and forth
    /// from starting the same load repeatedly.
    @ObservationIgnored private var pageLoadsInFlight: Set<UUID> = []

    /// The save in progress, or `nil`. A save is in flight iff this is
    /// non-nil, and waiting for it is `await currentSave?.value` — a caller
    /// awaits the *specific* pass it observed, so no caller can return
    /// believing it flushed while another caller took the pass. The
    /// hand-rolled waiter array this replaces was never observed to leak, but
    /// it had to be re-audited every time it was touched; a task handle does
    /// not.
    private var currentSave: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// Saves that have failed in a row, reset by the first success.
    ///
    /// This is what makes a transient failure recover by itself: without it a
    /// failed save left the editor dirty with nothing scheduled, and durability
    /// resumed only if the user happened to draw again, tap Retry, or background
    /// the app (`Contract.md` — Saving, retry policy).
    private var consecutiveSaveFailures = 0

    /// How long the last whole-drawing serialization took. The debounce is
    /// derived from it so that a document large enough to be expensive to
    /// serialize does not chain back-to-back serializations (`Contract.md` —
    /// Saving). Zero until the first save, which is the same as no back-off.
    private var lastSerializeDuration: Duration = .zero

    /// Serializing is allowed to widen the debounce by this factor: a save that
    /// costs 200 ms of encoding earns 800 ms of quiet before the next one.
    private static let serializeBackoffFactor = 4

    /// The ceiling on retry back-off. Five seconds, because the wait is time the
    /// document spends knowingly unsaved: a longer ceiling only delays recovery
    /// once the cause clears, and the cause of a transient save failure is not
    /// worth a minute of exposure. A persistently failing store is bounded by
    /// this ceiling, not rescued by it.
    private static let maximumRetryDelay: Duration = .seconds(5)

    /// Failure doublings past this point are pointless — at the default
    /// 500 ms interval the fourth doubling already exceeds `maximumRetryDelay` —
    /// and an unbounded shift would overflow.
    private static let maximumFailureDoublings = 10

    /// Test-only: holds the save open between serialization and the store write.
    ///
    /// The retirement handover and the save acknowledgement are only observable
    /// against a save that is genuinely in flight. A real device earns that
    /// window from a large drawing's encode; tests earn it here rather than by
    /// sleeping and hoping (`inkSurvivesItsPageLeavingTheWindow` used to sleep
    /// 50 ms past the race it was written to catch). `nil` — the only value the
    /// app ever holds — costs nothing on the save path.
    @ObservationIgnored var serializationDelayForTesting: Duration?

    /// `RootCanvasView.task` may be restarted as views move through the scene
    /// lifecycle. Exactly one load is allowed to cross the store boundary; later
    /// callers await that attempt instead of racing a second load over live ink.
    private var startTask: Task<Void, Never>?

    /// `debounce` is injectable only so tests need not wait 500 ms of real time.
    /// The default is the only interval the app uses. It is a hard floor and
    /// never a ceiling: the adaptive debounce may widen it for a document that
    /// is expensive to serialize, and can never shorten it (`Contract.md` —
    /// Saving).
    /// Builds no UIKit object. See `canvas` for why that matters.
    init(store: DocumentStore, debounce: Duration = .milliseconds(500)) {
        self.store = store
        self.debounce = debounce
    }

    // MARK: - Launch

    /// Loads once, before the canvas becomes editable (`Contract.md` — Lifecycle).
    ///
    /// No document means first launch: generate the IDs and save an empty
    /// one-page document. Invalid data fails loudly and leaves what is on disk
    /// untouched — it is never replaced with a blank drawing.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        guard phase == .loading else { return }

        let started = Task { [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startTask = started
        await started.value
    }

    private func performStart() async {
        do {
            if let loaded = try await store.load() {
                index = loaded
                pageStates = loaded.pageIDs.map { Page(loading: $0) }
                // The opening window, fetched before any canvas exists, so the
                // first pages are built with their ink rather than as blanks
                // that have to be reloaded.
                await fetchPageData(forPagesAround: loaded.currentPageIndex)
            } else {
                index = DocumentIndex.newDocument(documentID: UUID(), pageID: UUID())
                // Empty bytes are the blank page. Serializing an empty
                // `PKDrawing` to get the same meaning would drag PencilKit into
                // this file, which `Contract.md` — Owners confines to the
                // canvas runtime. The page state is built first so the layer
                // identity written to disk is the one the session keeps.
                let firstPage = Page(clean: index.pageIDs[0], durable: Data())
                try await store.save(
                    index: index,
                    changedPages: [firstPage.id: [inkEnvelope(for: firstPage, payload: Data())]]
                )
                pageStates = [firstPage]
            }
            alignedWithIndex()
            phase = .ready
            pages.setPages(count: index.pageIDs.count, currentPageIndex: index.currentPageIndex)
            // Editing opens only now, after the loaded drawings are installed.
            // Each canvas enforces the ordering; the session decides when it
            // holds, and a page whose bytes have not arrived stays closed.
            pages.markEditable()
            CanvasLog.event(
                .lifecycle,
                "session ready; pages=\(index.pageIDs.count) "
                    + "current=\(index.currentPageIndex)"
            )
        } catch {
            phase = .failed(String(describing: error))
            CanvasLog.event(.lifecycle, "session failed to start: \(error)")
        }
    }

    // MARK: - Page state

    /// The one lookup from identity to state. Pages are never removed, so a
    /// missing entry is a broken invariant, not an answerable question.
    private func stateIndex(of pageID: UUID) -> Int {
        guard let found = pageStates.firstIndex(where: { $0.id == pageID }) else {
            preconditionFailure("no state for page \(pageID); pages are never removed")
        }
        return found
    }

    /// `pageStates` and `index.pageIDs` are the same list in the same order.
    /// Checked after every mutation of either, so a drift fails at the mutation
    /// that caused it.
    private func alignedWithIndex() {
        precondition(
            pageStates.map(\.id) == index.pageIDs,
            "page states have drifted from the document index"
        )
    }

    // MARK: - Page content

    /// What the runtime should build a page with, answered from the page's one
    /// ink state. Unsaved ink outranks anything on disk: it is newer by
    /// construction, which is what stops a fast turn away and back from
    /// restoring pre-edit ink.
    private func content(forPageAt pageIndex: Int) -> PagedCanvasController.PageContent {
        // Out of range only when the runtime lays out before `start()` has
        // populated the session — reachable in tests alone, where hosting
        // order is the setup's choice.
        guard pageStates.indices.contains(pageIndex) else { return .blank }
        if let refused = pageStates[pageIndex].refusedLayers.first {
            // The refusal is the layer's, but the input refusal is the
            // page's: a page is editable exactly when its ink layer is
            // editable and no layer is refused or unreadable. The same
            // placeholder path as an unreadable page, because both mean
            // "shown, not writable, and it says why".
            //
            // PROVISIONAL WORDING: the final user-facing sentence belongs to
            // the failure-taxonomy work; the scope is decided here.
            return .unreadable(Self.refusalMessage(refused))
        }
        switch pageStates[pageIndex].ink {
        case .loading:
            let around = index.currentPageIndex
            Task { [weak self] in
                await self?.fetchPageData(forPagesAround: around)
            }
            return .loading
        case .unreadable(let message):
            return .unreadable(message)
        case .clean:
            guard let data = pageStates[pageIndex].durable else {
                preconditionFailure(
                    "page \(pageIndex) is clean but its durable bytes are missing"
                )
            }
            return data.isEmpty ? .blank : .ink(data)
        case .live:
            preconditionFailure(
                "asked to rebuild page \(pageIndex) while its live canvas is the authority"
            )
        case .held(let unsaved), .saving(let unsaved):
            switch unsaved {
            case .drawing(let snapshot):
                return .retained(snapshot)
            case .serialized(let data):
                return data.isEmpty ? .blank : .ink(data)
            }
        }
    }

    /// What a page carrying a refused layer says instead of taking ink.
    ///
    /// PROVISIONAL WORDING, all of it: `failure-has-a-taxonomy` owns the
    /// sentences. What is decided here, and is not provisional, is the scope —
    /// the layer is refused, the page refuses input, the document opens.
    private static func refusalMessage(_ refused: RefusedLayer) -> String {
        switch refused.reason {
        case .unknownKind:
            "This page carries a layer of kind \"\(refused.kind)\" "
                + "that this version of TuberNotes cannot open."
        case .unreadablePayload:
            "This page carries a \(refused.kind) layer whose contents "
                + "could not be read."
        case .unsupportedAssetFormat(_, let format):
            "This page carries a \(refused.kind) layer in a format "
                + "(\"\(format)\") that this version of TuberNotes cannot open."
        case .missingAsset(let assetID):
            "This page references an image (\(assetID.uuidString)) "
                + "that is missing from this notebook."
        }
    }

    /// Loads the saved bytes for the pages around `pageIndex` that are not
    /// already held, and rebuilds any page that was shown before its ink arrived.
    ///
    /// The radius is one wider than the runtime's live window, so an ordinary
    /// turn finds the next page's bytes already here.
    ///
    /// One page failing to read refuses itself and does not stall the rest of
    /// the window: the failure is surfaced here at the session boundary and the
    /// page is marked unreadable, never rendered as an editable blank
    /// (`Contract.md` — Invalid states fail loud, on the read path).
    private func fetchPageData(forPagesAround pageIndex: Int) async {
        let lower = max(0, pageIndex - Self.prefetchRadius)
        let upper = min(index.pageIDs.count - 1, pageIndex + Self.prefetchRadius)
        guard lower <= upper else { return }

        for candidate in lower...upper {
            let pageID = index.pageIDs[candidate]
            guard case .loading = pageStates[stateIndex(of: pageID)].ink,
                  !pageLoadsInFlight.contains(pageID) else { continue }

            pageLoadsInFlight.insert(pageID)
            defer { pageLoadsInFlight.remove(pageID) }

            do {
                let loaded = try await store.loadPage(pageID)
                // The page list can change while this is in flight; write the
                // bytes under the identity they were loaded for, never under
                // an index.
                pageStates[stateIndex(of: pageID)].bytesLoaded(loaded)
            } catch {
                CanvasLog.event(
                    .lifecycle,
                    "page \(pageID) failed to load: \(error)"
                )
                pageStates[stateIndex(of: pageID)].loadFailed(String(describing: error))
            }
            if let current = index.pageIDs.firstIndex(of: pageID) {
                liveRuntime?.reloadPage(at: current)
            }
        }
    }

    /// Drops held durable bytes for pages far from the visible one.
    ///
    /// Without this, the cache would grow with every page visited — the
    /// monotonic retention `Contract.md` — Performance forbids, wearing a
    /// different hat. Only the durable cache is droppable; a page's unsaved
    /// ink is never touched, which is the "any page whose ink is not yet
    /// saved" clause of the held-bytes bound.
    private func pruneDurableBytes() {
        let lower = max(0, index.currentPageIndex - Self.prefetchRadius)
        let upper = min(index.pageIDs.count - 1, index.currentPageIndex + Self.prefetchRadius)
        guard lower <= upper else { return }

        for stateIndex in pageStates.indices where !(lower...upper).contains(stateIndex) {
            pageStates[stateIndex].evicted()
        }
    }

    /// One page either side of the runtime's live window.
    private static let prefetchRadius = 2

    // MARK: - Appending

    /// Adds a blank page at the end and turns to it.
    ///
    /// KNOWN DEFECT: the page is durable immediately here, rather than on first
    /// ink. Nothing drops a
    /// never-written trailing page at save time: this holds empty bytes as the
    /// page's unsaved ink, and `DocumentStore.save` writes every
    /// entry in `changedPages` with no emptiness check. An accidental swipe
    /// past the end therefore grows the document permanently.
    ///
    /// This is a knowing divergence, and the contract is the side that is
    /// right. Appending eagerly was the smaller change and loses no ink.
    private func appendPage() {
        // Appending during an in-flight save is safe, and refusing it violated
        // Navigation's "immediately": the save holds its captured index by
        // value, `DocumentStore.save` validates its batch against that capture,
        // and the appended page's dirty state survives the pass untouched —
        // `performOneSave`'s exit re-arms, so the next pass writes both.
        guard phase == .ready else { return }

        let appended = UUID()
        pageStates.append(Page(appended: appended))
        index = index.withPages(index.pageIDs + [appended], currentPageIndex: index.pageIDs.count)
        indexDirty = true
        alignedWithIndex()

        pages.setPages(count: index.pageIDs.count, currentPageIndex: index.currentPageIndex)
        CanvasLog.event(
            .canvas,
            "appended page \(index.currentPageIndex); pages=\(index.pageIDs.count)"
        )
        markDirty()
    }

    // MARK: - Autosave

    /// The one place a drawing change is judged to be user editing.
    ///
    /// What keeps a load from dirtying the document is the wiring order in
    /// `PagedCanvasController.makePage`, not a guard here: PencilKit reports a
    /// programmatic assignment synchronously, so the callback is attached only
    /// after the install and never sees it.
    ///
    /// The phase guard remains for `.failed`, where autosaving would overwrite a
    /// document that could not be read, and for `.loading`, where no page should
    /// be reporting anything yet.
    private func drawingChanged(atPageIndex pageIndex: Int) {
        guard phase == .ready, pageStates.indices.contains(pageIndex) else { return }
        // A page whose bytes are not held has no canvas — it is a placeholder
        // in the runtime — so `edited()`'s trap for `.loading` and
        // `.unreadable` is unreachable from here rather than a case to route
        // around. Ink cannot be misaccounted if it was never accepted.
        pageStates[pageIndex].edited()
        markDirty()
    }

    /// Takes custody of a page's ink as its canvas is released.
    ///
    /// Synchronous, and that is the whole point (`Contract.md` — Navigation,
    /// Saving: "a page leaving the live window hands over a value rather than
    /// starting a second capture"). Taking the value here leaves the save path
    /// as the only code that serializes, which is what makes the contract's
    /// claim that stale generations cannot exist true rather than aspirational.
    ///
    /// Handing over a promise instead — a `Task` that serialized and wrote the
    /// bytes back later — left a window in which the page had no canvas and no
    /// held ink. A save landing in that window found only the last bytes that
    /// reached disk, wrote those over the newer ink, and marked the page clean.
    private func pageIsRetiring(atPageIndex pageIndex: Int, snapshot: DrawingSnapshot) {
        guard phase == .ready, pageStates.indices.contains(pageIndex) else { return }
        pageStates[pageIndex].retired(handingOver: snapshot)
    }

    /// The visible page settled on a new index.
    private func currentPageChanged(to pageIndex: Int) {
        guard phase == .ready, index.pageIDs.indices.contains(pageIndex) else { return }
        guard pageIndex != index.currentPageIndex else { return }

        index = index.withPages(index.pageIDs, currentPageIndex: pageIndex)
        indexDirty = true
        alignedWithIndex()
        pruneDurableBytes()
        Task { [weak self] in
            await self?.fetchPageData(forPagesAround: pageIndex)
        }
        markDirty()
    }

    private func markDirty() {
        // The debounce is not reset while a save is in flight;
        // `performOneSave`'s exit re-arms for anything that changed during it
        // (`Contract.md` — Saving: "Work arriving during a save receives a
        // fresh debounce after that save returns"). That exit is the *single*
        // owner of the duty — an early return here used to drop it.
        guard currentSave == nil else { return }
        scheduleSave()
    }

    private func scheduleSave(after delay: Duration? = nil) {
        let interval = delay ?? adaptiveDebounce
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.performAutosavePass()
        }
    }

    /// The debounce actually used: the default interval, widened when the last
    /// serialization was expensive (`Contract.md` — Saving).
    ///
    /// A fixed interval chains serializations back to back once serialization
    /// is expensive: at 200 ms per serialization a 500 ms debounce spends most
    /// of its time encoding. Small documents measure near zero and stay at
    /// exactly the floor, so their behavior is unchanged.
    ///
    /// KNOWN DEFECT: `lastSerializeDuration` sums across every dirty page, so
    /// this interval grows with *how many pages changed* rather than with what
    /// writing a page costs. Pages restored from already-serialized bytes
    /// contribute zero to that sum, so a save consisting only of retired pages
    /// records a duration of zero and discards the previous warm measurement.
    ///
    /// KNOWN DEFECT: the measurement is warm-only. `lastSerializeDuration`
    /// starts at zero and is written only in `performOneSave`, so the first
    /// save of a session gets no backoff at all. Measured at 20,000 strokes /
    /// 4.6 MB: 126 ms cold against 48 ms warm — so the first save after launch,
    /// which is also the one most likely to be interrupted, is systematically
    /// under-estimated.
    private var adaptiveDebounce: Duration {
        max(debounce, lastSerializeDuration * Self.serializeBackoffFactor)
    }

    /// Exponential back-off for a retry after a failed save: the first retry
    /// waits the ordinary debounce interval and each further consecutive failure
    /// doubles it, capped (`Contract.md` — Saving).
    ///
    /// The cap matters more than the curve. A disk that is full or a container
    /// that is unavailable will not clear in the next 20 ms, and retrying at
    /// interaction frequency against a failing store is the spin the
    /// background-flush path is explicitly written to avoid.
    private var retryDelay: Duration {
        let doublings = min(max(consecutiveSaveFailures - 1, 0), Self.maximumFailureDoublings)
        return min(adaptiveDebounce * (1 << doublings), Self.maximumRetryDelay)
    }

    /// Flushes the currently dirty work: waits out any save already in flight,
    /// then runs one pass of its own. One pass, not a loop — work that arrives
    /// while the pass runs receives a fresh debounce from `performOneSave`'s
    /// exit, which is the single owner of that duty.
    func saveIfNeeded() async {
        await currentSave?.value

        guard dirty else { return }
        debounceTask?.cancel()
        debounceTask = nil
        if let save = beginSave() { await save.value }
        // Still dirty, or failed? performOneSave's exit armed the fresh
        // debounce or the backed-off retry; returning here is not abandoning it.
    }

    /// One debounced pass only. Edits made while that pass is running receive a
    /// fresh debounce instead of causing back-to-back whole-drawing
    /// serializations during continuous Pencil input.
    private func performAutosavePass() async {
        guard phase == .ready, dirty, currentSave == nil else { return }
        if let save = beginSave() { await save.value }
    }

    /// Starts a save if none is running, and returns the task that owns the
    /// pass — the already-running one otherwise, so every caller awaits the
    /// specific pass it observed rather than a broadcast.
    ///
    /// The capture happens *here*, synchronously, before the task is spawned:
    /// the moment `beginSave` returns a new task, that task owns a complete
    /// generation. Deferring the capture into the task would open a gap
    /// between "a save is in flight" and "the generation is captured" in
    /// which an edit could slip into a pass that reports itself as having
    /// begun before it.
    ///
    /// Capture is total (`Contract.md` — Saving): the switch is exhaustive
    /// with no `else`, so there is no fourth place a dirty page's ink could
    /// be and no silent omission. A live page yields its canvas's drawing; one
    /// that has left the live window yields the value the session took custody
    /// of as it retired. A page that cannot be captured is a violation and
    /// traps at its transition, never a page quietly reported clean while its
    /// ink existed nowhere.
    @discardableResult
    private func beginSave() -> Task<Void, Never>? {
        if let currentSave { return currentSave }
        guard phase == .ready, dirty else { return nil }

        let capturedIndex = index
        let capturedIndexWasDirty = indexDirty
        indexDirty = false

        var captures: [Capture] = []
        for pageIndex in pageStates.indices {
            // Captured with the ink, because the page file is written whole:
            // the list this pass writes is the list as it is now, and a later
            // edit to it is a later pass's work, never this one's.
            let layers = pageStates[pageIndex].staticLayers
            switch pageStates[pageIndex].ink {
            case .loading, .unreadable:
                continue
            case .clean:
                // Clean ink and a changed layer list: the page file still has
                // to be rewritten, and the ink it is rewritten with is exactly
                // what the last save wrote.
                guard pageStates[pageIndex].layersUnsaved else { continue }
                guard let durable = pageStates[pageIndex].durable else {
                    preconditionFailure(
                        "page \(pageStates[pageIndex].id) has an unsaved layer list "
                            + "but no durable ink to write it with"
                    )
                }
                pageStates[pageIndex].beginSaving(.serialized(durable))
                captures.append(Capture(pageStates[pageIndex].id, .serialized(durable), layers))
            case .live:
                guard let snapshot = liveRuntime?.snapshot(at: pageIndex) else {
                    preconditionFailure(
                        "page \(pageStates[pageIndex].id) is live but its canvas "
                            + "yielded no snapshot"
                    )
                }
                pageStates[pageIndex].beginSaving(.drawing(snapshot))
                captures.append(Capture(pageStates[pageIndex].id, .drawing(snapshot), layers))
            case .held(let unsaved):
                pageStates[pageIndex].beginSaving(unsaved)
                captures.append(Capture(pageStates[pageIndex].id, unsaved, layers))
            case .saving:
                preconditionFailure(
                    "page \(pageStates[pageIndex].id) was already saving when a new "
                        + "capture began; there is never more than one in flight"
                )
            }
        }

        let save = Task { [weak self] in
            guard let self else { return }
            await self.performOneSave(
                capturedIndex: capturedIndex,
                capturedIndexWasDirty: capturedIndexWasDirty,
                captures: captures
            )
        }
        currentSave = save
        return save
    }

    /// One page's whole unsaved generation: its ink, and the layer list that
    /// ink belongs to. Both are captured at the same instant, so the file this
    /// pass writes is one coherent moment of the page rather than two.
    private struct Capture {
        let pageID: UUID
        let unsaved: Page.UnsavedInk
        let staticLayers: [LayerEnvelope]

        init(_ pageID: UUID, _ unsaved: Page.UnsavedInk, _ staticLayers: [LayerEnvelope]) {
            self.pageID = pageID
            self.unsaved = unsaved
            self.staticLayers = staticLayers
        }
    }

    /// The body of one save pass: serialize, write, acknowledge. Runs only
    /// inside the task `beginSave` registered as `currentSave`, over the
    /// generation `beginSave` captured, and clears the handle on the way out.
    private func performOneSave(
        capturedIndex: DocumentIndex,
        capturedIndexWasDirty: Bool,
        captures: [Capture]
    ) async {
        // Serialize off the main actor, on the save path, never at the
        // handover (`Contract.md` — Performance). Ink a previous pass already
        // serialized — a failed save's restored bytes, an appended blank —
        // costs nothing again.
        var changedPages: [UUID: Data] = [:]
        var totalDuration: Duration = .zero
        for capture in captures {
            let data: Data
            switch capture.unsaved {
            case .serialized(let alreadySerialized):
                data = alreadySerialized
            case .drawing(let snapshot):
                let serialized = await snapshot.serialized()
                data = serialized.data
                totalDuration += serialized.duration
            }
            changedPages[capture.pageID] = data
            pageStates[stateIndex(of: capture.pageID)].serializedWhileSaving(data)
        }
        // Measured where the work happens rather than timed again here: the next
        // debounce is derived from this cost (`Contract.md` — Saving).
        lastSerializeDuration = totalDuration

        if let delay = serializationDelayForTesting {
            try? await Task.sleep(for: delay)
        }

        // The session is the one writer of a page's layer list (`Docs/Forks/
        // CanvasFeatureComplete.md` — One value, one writer), so the envelopes
        // are built here, not in the store: the page's static layers in order,
        // then its one ink layer, identity transform, under the identity loaded
        // from or first written to disk. Ink last is by construction here and
        // checked again by the store on the way in and on the way out.
        var changedLayers: [UUID: [LayerEnvelope]] = [:]
        for capture in captures {
            guard let data = changedPages[capture.pageID] else { continue }
            let page = pageStates[stateIndex(of: capture.pageID)]
            changedLayers[capture.pageID] =
                capture.staticLayers + [inkEnvelope(for: page, payload: data)]
        }

        do {
            // Only the pages that were edited. The store rewrites the index only
            // if it changed, so an ordinary ink save touches exactly one file.
            try await store.save(index: capturedIndex, changedPages: changedLayers)
            // Acknowledgement follows evidence: only now, with the write
            // returned, does any page become clean — and only one nothing
            // edited since its capture.
            for capture in captures {
                guard let data = changedPages[capture.pageID] else { continue }
                pageStates[stateIndex(of: capture.pageID)].saveSucceeded(
                    written: data,
                    layersWritten: capture.staticLayers
                )
            }
            lastSaveError = nil
            consecutiveSaveFailures = 0
        } catch {
            // The pages stay dirty and keep the bytes this pass already paid
            // to encode. The index returns to dirty only if it was dirty at
            // capture or became so during the save.
            for (pageID, data) in changedPages {
                pageStates[stateIndex(of: pageID)].saveFailed(restoring: data)
            }
            indexDirty = indexDirty || capturedIndexWasDirty
            lastSaveError = String(describing: error)
            consecutiveSaveFailures += 1
        }

        currentSave = nil

        // The one exit that owns re-arming (`Contract.md` — Saving: "Work
        // arriving during a save receives a fresh debounce after that save
        // returns"). Every early return that used to drop this duty —
        // markDirty, performAutosavePass, resumeForForeground under an
        // in-flight save — now relies on it instead of half-owning it. A
        // failed pass arms the backed-off retry; without it a transient
        // failure parked the editor dirty with no timer running and recovery
        // waited on the user drawing again, tapping Retry, or a scene
        // transition.
        if dirty {
            scheduleSave(after: lastSaveError == nil ? nil : retryDelay)
        }
    }

    /// The page's single ink layer, as the durable form carries it: the
    /// serialized drawing as payload, identity transform, last — and, with
    /// one layer, only — in the list.
    private func inkEnvelope(for page: Page, payload: Data) -> LayerEnvelope {
        LayerEnvelope(
            layerID: page.inkLayerID,
            kind: .ink,
            payload: payload,
            pageSpaceTransform: .identity
        )
    }

    // MARK: - Layers

    /// Imports one image as a layer on a page, beneath its ink.
    ///
    /// Leaf to root, in this order and for this reason: the asset is written
    /// first and is durable before any page file names it, so an interruption
    /// at any point leaves an orphan asset — inert, merely heavy — and never a
    /// page file naming an asset that is not there. `DocumentStore.save`
    /// enforces the same order rather than trusting this one caller.
    ///
    /// `sourceWidth` and `sourceHeight` are the image's own extent, in any
    /// consistent unit: only their ratio is used, to fit the image inside the
    /// page. Nothing about the source is durable — the layer's
    /// `pageSpaceTransform` maps the image's unit square into page space, so
    /// placement never restates what the asset's own bytes say.
    ///
    /// No UI calls this, and it is on no interaction path: it awaits a file
    /// write and then a save. It is the entry point phase 2's durable half is
    /// testable through, and the one the import UI will call when it exists.
    ///
    /// The save is immediate rather than debounced. A debounce exists to
    /// coalesce Pencil-frequency edits; an import is one discrete action whose
    /// heavy bytes are already on disk, and every millisecond it stays unsaved
    /// is a millisecond the asset is an orphan.
    @discardableResult
    func importImage(
        _ bytes: Data,
        format: AssetFormat,
        sourceWidth: Double,
        sourceHeight: Double,
        onPage pageID: UUID? = nil
    ) async throws -> UUID {
        guard phase == .ready else { throw LayerEditError.sessionNotReady }
        let targetPageID = pageID ?? currentPageID
        try requireLayerListIsEditable(targetPageID)

        // The leaf, first and on its own: nothing yet references it, so a
        // failure here leaves the document exactly as it was.
        let assetID = UUID()
        try await store.writeAsset(bytes, assetID: assetID, format: format)

        // The page may have moved through states while that write ran.
        try requireLayerListIsEditable(targetPageID)

        let layerID = UUID()
        let envelope = try LayerEnvelope.image(
            layerID: layerID,
            ref: ImageLayerRef(assetID: assetID, format: format),
            pageSpaceTransform: .fittingSource(
                width: sourceWidth,
                height: sourceHeight,
                inPageOfWidth: index.pageWidth,
                height: index.pageHeight
            )
        )

        let page = stateIndex(of: targetPageID)
        // Appended, so it lands above the page's existing static layers and
        // below the ink. Ink last is not a rule this site remembers: the save
        // path builds `staticLayers + [ink]`, so it cannot write anything else.
        pageStates[page].layerListChanged(
            to: pageStates[page].staticLayers + [envelope],
            refusedLayers: pageStates[page].refusedLayers
        )
        CanvasLog.event(
            .canvas,
            "imported asset \(assetID) as layer \(layerID) on page \(targetPageID)"
        )

        await saveIfNeeded()
        return layerID
    }

    /// Deletes one layer from a page — **the** site that deletes layers, and
    /// therefore the site delete-inline asset reclamation lives at.
    ///
    /// Root to leaf, the mirror of the write order: the page file drops the ref
    /// first, the asset dies second. An interruption between them leaves an
    /// orphan asset, never a dangling ref.
    ///
    /// Reclamation is safe whether or not that save succeeded, and not because
    /// this checks: the store answers "does anything still reference this?"
    /// from the page files on disk, so a page write that failed leaves the ref
    /// there and the asset lives.
    ///
    /// Crash orphans still accumulate — an import interrupted before its page
    /// write, a delete interrupted before its asset write — and that is
    /// accepted for now. Sweep-on-open is deferred behind
    /// `failure-has-a-taxonomy`, because a sweep that deletes the wrong file is
    /// a durability failure and needs the taxonomy to say what it does when it
    /// cannot tell. An orphan is inert and merely heavy.
    func deleteLayer(_ layerID: UUID, fromPage pageID: UUID) async throws {
        guard phase == .ready else { throw LayerEditError.sessionNotReady }
        guard index.pageIDs.contains(pageID) else {
            throw LayerEditError.pageNotFound(pageID)
        }
        let page = stateIndex(of: pageID)
        guard let deleted = pageStates[page].staticLayers.first(
            where: { $0.layerID == layerID }
        ) else {
            throw LayerEditError.layerNotFound(layerID: layerID, pageID: pageID)
        }

        let refusalsBefore = pageStates[page].refusedLayers.count
        pageStates[page].layerListChanged(
            to: pageStates[page].staticLayers.filter { $0.layerID != layerID },
            // Deleting the layer clears its refusal with it: dropping a layer
            // whose asset is missing is the one repair for such a page, and the
            // page is editable again the moment nothing on it is refused.
            refusedLayers: pageStates[page].refusedLayers.filter { $0.layerID != layerID }
        )
        CanvasLog.event(.canvas, "deleted layer \(layerID) from page \(pageID)")

        await saveIfNeeded()

        // Re-resolved rather than reused: `page` was computed before an await,
        // and an index that outlives one is the class of bug this file already
        // carries elsewhere. Pages are append-only today, which makes this
        // caution rather than a fix.
        if pageStates[stateIndex(of: pageID)].refusedLayers.count != refusalsBefore,
           let visible = index.pageIDs.firstIndex(of: pageID) {
            // A page that was refusing input may now accept it, so the runtime
            // rebuilds the placeholder into a canvas. Only ever reached from a
            // page that had a refusal, which is a page with no live canvas.
            liveRuntime?.reloadPage(at: visible)
        }

        await reclaimAsset(of: deleted)
    }

    /// Deletes the asset a just-deleted layer referenced, if it was the last
    /// reference to it. A failure here costs an orphan, never data, so it is
    /// reported and not thrown: the layer is already gone from the page.
    private func reclaimAsset(of deleted: LayerEnvelope) async {
        guard deleted.recognizedKind == .image else { return }
        do {
            let ref = try ImageLayerRef(payload: deleted.payload)
            guard let format = ref.recognizedFormat else { return }
            try await store.deleteAssetIfUnreferenced(assetID: ref.assetID, format: format)
        } catch {
            CanvasLog.event(
                .save,
                "layer \(deleted.layerID) deleted, but its asset was not reclaimed: "
                    + "\(error); it is an inert orphan"
            )
        }
    }

    /// A page whose layer list may be rewritten: its own bytes are here, and it
    /// is not refusing input. A page carrying a refused layer takes no edit of
    /// any kind — that is what "the page refuses input" means — except the
    /// deletion that repairs it.
    private func requireLayerListIsEditable(_ pageID: UUID) throws {
        guard index.pageIDs.contains(pageID) else {
            throw LayerEditError.pageNotFound(pageID)
        }
        let page = stateIndex(of: pageID)
        guard pageStates[page].refusedLayers.isEmpty else {
            throw LayerEditError.pageRefusesInput(pageID)
        }
        switch pageStates[page].ink {
        case .clean, .live, .held, .saving:
            return
        case .loading, .unreadable:
            throw LayerEditError.pageNotReady(pageID)
        }
    }

    // MARK: - Lifecycle

    /// Cancels the debounce and makes a best-effort save with whatever execution
    /// time iPadOS provides. Only a returned save is acknowledged; if time
    /// expires the editor stays dirty and retries after foregrounding.
    ///
    /// One pass, deliberately. The lease is bounded,
    /// so unbounded work cannot finish on it anyway, and every extra iteration is
    /// another chance to be killed mid-write for ink that was already captured by
    /// the pass before it. If the session is still dirty when this returns it
    /// stays dirty — the pass's own exit arms a timer and `resumeForForeground`
    /// retries, which is exactly what
    /// `Contract.md` — Lifecycle promises ("no promised flush duration").
    func flushForBackground() async {
        debounceTask?.cancel()
        debounceTask = nil

        // An in-flight save already owns a captured generation; awaiting that
        // *specific* task is what makes the following pass the second and last
        // one — and what makes it impossible to return believing this flushed
        // while another caller took the pass, which is how the lease used to
        // be handed back with a save still writing.
        await currentSave?.value
        if let save = beginSave() { await save.value }
    }

    /// Retries a save left unacknowledged by backgrounding. It never overlays a
    /// loaded drawing onto newer live ink — nothing is loaded here. A save
    /// still in flight re-arms at its own exit, so nothing is dropped by
    /// returning early here.
    func resumeForForeground() {
        guard phase == .ready, dirty, currentSave == nil else { return }
        scheduleSave()
    }
}
