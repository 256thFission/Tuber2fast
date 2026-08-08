import Foundation
import Observation
import TuberCanvas
import TuberCore
import TuberModel
import TuberRender
import TuberStore

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
    /// The layer is locked against transforms. Locked is a bit on the
    /// envelope, not a property of the kind — a locked layer is still
    /// selectable and still deletable.
    case layerIsLocked(layerID: UUID, pageID: UUID)
    /// A source page smaller than this build can display — a receipt, a ticket,
    /// a cropped fragment. Its fit-width scale is past the document's own zoom
    /// ceiling, which `PageCanvasController.establishZoomIfNeeded` traps on.
    ///
    /// Refused at import rather than trapped at layout, because geometry is
    /// persisted before the page is ever laid out: without this the page is
    /// written, the document is reopened, and the trap fires on **every**
    /// subsequent open with no way back in. The bound is
    /// `PageProjection.smallestDisplayablePagePoints`, which states the
    /// derivation.
    case pageTooSmallToDisplay(width: Double, height: Double, minimum: Double)
    /// The page carries no `pdf` layer, so there is no worksheet to throw
    /// away. A refusal rather than a silent success: the caller is a button,
    /// and a button that does nothing and says nothing reads as broken.
    case noPDFLayerOnPage(UUID)
}

/// What a session does when `load()` answers `nil`: whether nobody has ever
/// created this document, or somebody has and its index is gone.
///
/// The distinction is the caller's to state, because the store cannot tell the
/// two apart and the wrong default destroys data — see `performStart()`.
package enum OpenIntent {
    /// A `nil` load is a refusal. For a package something enumerated — a
    /// library row, a picked directory — "no index" means damaged, not new.
    case openExisting
    /// A `nil` load is first launch: create and save an empty one-page
    /// document. The pre-library default, and the only intent the explicit
    /// new-document path may carry, because that path creates the directory
    /// itself and nothing else has ever named it.
    case createIfAbsent
}

/// What `close()` hands back: whether the session's ink is all on disk.
package enum CloseOutcome: Equatable {
    /// Nothing is dirty. The session is dead — it refuses every edit from
    /// here on and is never restarted; reopening builds a new session.
    case clean
    /// The final pass failed or pages remain dirty. The session is still
    /// fully alive and its retry machinery keeps draining; the string is the
    /// failure a caller may surface. Releasing a dirty session is never an
    /// outcome (`Docs/Contract.proposed.md` L4).
    case dirty(String)
}

/// Coordinates the canvas runtime and the document store (`Contract.md` — Owners).
///
/// It owns page order and identity, per-page ink state, and the active save
/// policy. Live drawings live in PencilKit and are captured only at save time.
/// `@Observable` is deliberate and narrow. SwiftUI observes `phase`,
/// `lastSaveError`, and `shapeTool` — user-action-frequency values, and the
/// last of them a read-through of the runtime's own rather than a copy. It is
/// forbidden to observe the drawing, pan, zoom, or Pencil samples.
@MainActor
@Observable
final class EditorSession {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
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
    /// `performOneSave` captures via `liveRuntime?.snapshot(ofPage:)`.
    var currentCanvas: PageCanvasController? {
        liveRuntime?.livePage(currentPageID)
    }

    /// Read only by tests: the prefetch warm is observable nowhere else —
    /// "the neighbour's composite is already in the cache before its canvas
    /// exists" is a claim about this actor's contents.
    ///
    /// `#if DEBUG` is the idiom for every `…ForTesting` member left in this
    /// app, and it is chosen over `@_spi(Testing)` for one reason:
    /// `@_spi` restricts *who may name* a member and still compiles it into
    /// the binary people hold, while the test bundle already reaches internal
    /// members through `@testable` and gains nothing from the annotation. The
    /// tests build Debug — `project.yml`'s scheme says so — and the build that
    /// ships to an iPad is Release, so a member that does not exist there
    /// cannot be read, set, or awaited by anything. That mattered concretely:
    /// two of these could suspend a production path.
    #if DEBUG
    var staticRendererForTesting: StaticLayerRenderer { staticRenderer }

    /// Read only by tests: a page's layer list as the session holds it. For a
    /// page whose layer write failed it exists nowhere else — not on disk, and
    /// not in the runtime unless that page happens to be live — and the seam
    /// that answers the runtime is not a surface a test may read through.
    func staticLayersForTesting(forPageAt pageIndex: Int) -> [LayerEnvelope] {
        staticLayers(forPage: index.pageIDs[pageIndex])
    }

    /// Read only by tests: a page's identity by position. Tests think in page
    /// numbers because a person does; the seam they drive is identity-keyed,
    /// and this is the one translation between the two.
    func pageIDForTesting(at pageIndex: Int) -> UUID {
        index.pageIDs[pageIndex]
    }
    #endif

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
        let created = PagedCanvasController(
            session: RuntimeSeam(session: self),
            staticRenderer: staticRenderer
        )
        liveRuntime = created
        return created
    }

    /// Answers the runtime's questions on this session's behalf.
    ///
    /// A separate object rather than `EditorSession: PagedCanvasSession`, and
    /// the reason is ownership. The runtime holds what it was built with
    /// strongly — that is what lets the reference be non-optional, and
    /// non-optional is the whole point of the protocol: an unwired seam is a
    /// compile error rather than a page answering `.blank` or a handover
    /// dropped in silence. A session that conformed directly would then be
    /// retained by the runtime it owns, and neither would ever be released.
    ///
    /// So the runtime owns this, this refers back `unowned`, and the session
    /// owns the runtime. The reference is safe by construction — nothing here
    /// can outlive the session two links above it — and the ownership is
    /// exactly what the `[weak self]` closures this replaces had: the runtime
    /// keeps no session alive.
    ///
    /// It forwards and decides nothing. Every out-of-range and not-yet-started
    /// answer belongs to the session's own methods, which is where a reader
    /// looking for "what does this document say about page 4" will look.
    private final class RuntimeSeam: PagedCanvasSession {
        private unowned let session: EditorSession

        init(session: EditorSession) {
            self.session = session
        }

        func canvasContent(forPage pageID: UUID) -> PagedCanvasController.PageContent {
            session.content(forPage: pageID)
        }

        func staticLayers(forPage pageID: UUID) -> [LayerEnvelope] {
            session.staticLayers(forPage: pageID)
        }

        func projection(forPage pageID: UUID) -> PageProjection {
            session.projection(forPage: pageID)
        }

        func drawingChanged(onPage pageID: UUID) {
            session.drawingChanged(onPage: pageID)
        }

        func layerTransformed(
            onPage pageID: UUID,
            layerID: UUID,
            to transform: PageSpaceTransform
        ) -> Bool {
            session.layerTransformed(onPage: pageID, layerID: layerID, to: transform)
        }

        func pageIsRetiring(_ pageID: UUID, handingOver snapshot: DrawingSnapshot) {
            session.pageIsRetiring(pageID, snapshot: snapshot)
        }

        func currentPageChanged(to pageID: UUID) {
            session.currentPageChanged(to: pageID)
        }

        func reachedEndBoundary() {
            session.appendPage()
        }
    }

    /// An intention from the SwiftUI root: which idealized shape a Pencil drag
    /// commits, or `nil` for ordinary freehand ink.
    ///
    /// Forwarded, not stored. The active tool is the paging runtime's state
    /// (`Contract.md` — Owners), and a copy kept here would be a second writer
    /// of it. This exists only so the root sends an intention to the session
    /// rather than reaching into the runtime, which is the one direction the
    /// owners diagram allows. What the root draws afterwards comes back the
    /// same way, through `shapeTool`.
    func setShapeTool(_ kind: ShapeKind?) {
        withMutation(keyPath: \.shapeTool) { pages.setShapeTool(kind) }
    }

    /// Which shape the Pencil commits right now, as the runtime has it.
    ///
    /// A read-through, never storage: the value is `PagedCanvasController`'s
    /// (`Contract.md` — Owners, the active tool), and the chrome that lights a
    /// button renders this snapshot rather than keeping its own copy to drift.
    /// `access`/`withMutation` is Observation's own hook for a computed
    /// property whose storage lives elsewhere — it is what makes a snapshot of
    /// someone else's state observable without becoming a second writer of it.
    ///
    /// `liveRuntime`, not `pages`: reading the tool must not be what builds a
    /// canvas. Before the runtime exists there is no shape tool, and `nil` —
    /// freehand — is the true answer.
    var shapeTool: ShapeKind? {
        access(keyPath: \.shapeTool)
        return liveRuntime?.shapeTool
    }

    @ObservationIgnored private var liveRuntime: PagedCanvasController?

    private let store: any DocumentStoring
    private let intent: OpenIntent
    private let debounce: Duration

    /// What the debounce waits on. `ContinuousClock` in the app; see `init`.
    private let clock: any Clock<Duration>

    /// Flattens a page's static layers into one texture, off-main. Built here
    /// because it reads asset bytes through the store, and the store is the
    /// session's; handed to the paging runtime, which is where it is used.
    ///
    /// Builds no UIKit object, so constructing it in `init` is safe where
    /// building a canvas would not be — see `pages`.
    @ObservationIgnored private let staticRenderer: StaticLayerRenderer

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
    ///
    /// **Dedup, not staleness** (`CONTRIBUTING.md` — Cancellation), and no
    /// task handle on purpose. A page load is not superseded by a turn: its
    /// bytes are filed under the page's own ID whenever they land, a page that
    /// left the window still needs them when it returns, and a load abandoned
    /// half way leaves the page `.loading` — which the contract's *Lifecycle*
    /// says is not editable. Cancelling here would trade a bounded disk read
    /// for a page that says nothing and takes no ink.
    @ObservationIgnored private var pageLoadsInFlight: Set<UUID> = []

    /// The save in progress, or `nil`. A save is in flight iff this is
    /// non-nil, and waiting for it is `await currentSave?.value` — a caller
    /// awaits the *specific* pass it observed, so no caller can return
    /// believing it flushed while another caller took the pass. The
    /// hand-rolled waiter array this replaces was never observed to leak, but
    /// it had to be re-audited every time it was touched; a task handle does
    /// not.
    ///
    /// **Protected: never cancelled** (`CONTRIBUTING.md` — Cancellation). This
    /// task owns pages already marked `.saving`, and only its own return path
    /// moves them out of that state. Cancelling it strands them there — ink
    /// that is neither on disk nor recapturable, which is the one outcome that
    /// outranks every saving of work this rule exists to do.
    private var currentSave: Task<Void, Never>?

    /// The debounce, and the counter-example: cancelling this is the ordinary
    /// path — every edit re-arms it — because it drops a *timer* and never a
    /// capture.
    private var debounceTask: Task<Void, Never>?

    /// Saves that have failed in a row, reset by the first success.
    ///
    /// This is what makes a transient failure recover by itself: without it a
    /// failed save left the editor dirty with nothing scheduled, and durability
    /// resumed only if the user happened to draw again, tap Retry, or background
    /// the app (`Contract.md` — Saving, retry policy).
    private var consecutiveSaveFailures = 0

    /// What one page's serialization costs, as last measured: the **slowest**
    /// page of the last pass that serialized anything. The debounce is derived
    /// from it so that a document large enough to be expensive to serialize
    /// does not chain back-to-back serializations (`Contract.md` — Saving).
    ///
    /// Per page rather than per pass, because the next pass is almost always
    /// one page — the page under the Pencil — and this number is an estimate of
    /// what that one will cost. Summing across the pass answered a different
    /// question: a five-page flick that retires four pages at once would have
    /// widened the quiet before every later single-page save by four pages'
    /// worth of work that is not going to happen again.
    ///
    /// Written only by a pass that actually serialized. A pass made entirely of
    /// bytes an earlier pass already encoded — a retry after a failed save, an
    /// index-only write — measures nothing, and recording its zero would throw
    /// away a real measurement of an expensive document in favour of an
    /// observation about a pass that did no encoding.
    ///
    /// `private(set)`: one writer, and the suite reads it to compare one pass's
    /// measurement against another's, which is the only way the difference
    /// between a maximum and a sum is observable at all.
    private(set) var lastSerializeDuration: Duration = EditorSession.coldSerializeEstimate

    /// What one serialization is assumed to cost before this session has
    /// measured one.
    ///
    /// Not zero. `lastSerializeDuration` is written only by a pass that
    /// serialized, so a zero start gave the first save of a session no back-off
    /// at all — and the first serialization of a drawing is the *expensive*
    /// one: measured at 20,000 strokes / 4.6 MB, 126 ms cold against 48 ms
    /// warm. The one save most likely to be interrupted was the one estimated
    /// least well.
    ///
    /// A constant, and a single measured one, rather than a model over the
    /// document's size. There is exactly one data point; a bytes-per-
    /// millisecond curve fitted through it would be a claim this project has
    /// not earned, and it would apply to a page whose ink has not been read
    /// yet. What this buys is honest and small: at the default 500 ms floor
    /// the first interval of a session becomes 504 ms rather than 500 ms, and
    /// it is the floor that decides again as soon as one real measurement
    /// exists.
    static let coldSerializeEstimate: Duration = .milliseconds(126)

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

    /// `RootCanvasView.task` may be restarted as views move through the scene
    /// lifecycle. Exactly one load is allowed to cross the store boundary; later
    /// callers await that attempt instead of racing a second load over live ink.
    ///
    /// **Protected: never cancelled** (`CONTRIBUTING.md` — Cancellation). It
    /// is the one load that has to complete before any canvas is editable; a
    /// cancelled start leaves a session stuck in `.loading` with no second
    /// attempt, because this handle is what makes the attempt singular.
    private var startTask: Task<Void, Never>?

    /// Set synchronously the moment `close()` is entered, before its first
    /// suspension, and never cleared: from that instant the session refuses
    /// *new* work — edits, turns, appends, imports — while the save path's own
    /// machinery keeps running, because a dirty closing session survives
    /// precisely to drain (`Docs/Contract.proposed.md` L4). The refusals live
    /// at the intake sites, not in `scheduleSave` or `performOneSave`, whose
    /// retry rearm must keep working under this flag.
    private var isClosing = false

    /// The one teardown. A second `close()` awaits this rather than starting
    /// another; `nil` iff `close()` has never been called.
    private var closeTask: Task<CloseOutcome, Never>?

    /// The teardown concluded with nothing dirty. Terminal: such a session is
    /// dead and refuses everything, including `resumeForForeground`.
    private var isClosedClean = false

    /// `debounce` is injectable only so tests need not wait 500 ms of real time.
    /// The default is the only interval the app uses. It is a hard floor and
    /// never a ceiling: the adaptive debounce may widen it for a document that
    /// is expensive to serialize, and can never shorten it (`Contract.md` —
    /// Saving).
    ///
    /// `clock` is the one seam the debounce waits on. It exists so a test can
    /// hold time still rather than sleep past an interval and hope — a wait
    /// that outruns the interval it sits inside is a failure about the
    /// machine's load, not about the code. The app passes nothing and gets
    /// `ContinuousClock`, which is the only clock it ever uses.
    ///
    /// Builds no UIKit object. See `canvas` for why that matters.
    init(
        store: any DocumentStoring,
        intent: OpenIntent = .createIfAbsent,
        debounce: Duration = .milliseconds(500),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.store = store
        self.intent = intent
        self.debounce = debounce
        self.clock = clock
        self.staticRenderer = StaticLayerRenderer(store: store)
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
        // A session that has begun closing never starts. Without this a
        // never-started session that closed clean would still take the one
        // load — and its create branch — after the caller was told it is dead.
        if isClosing {
            CanvasLog.event(.lifecycle, "start() on a closing or closed session; ignored")
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
            } else if intent == .openExisting {
                // A `nil` load on a package something enumerated is a damaged
                // document — its index gone, its pages possibly alive — and
                // is refused, byte-identical afterward. Falling through to
                // the create branch would save a fresh empty document into
                // the wreckage: the blank-unreadable-page sin at document
                // scale (`Docs/Forks/Library/03-review.md` B2). "nil means no
                // document exists" stays true only where nothing enumerated
                // one, which is what `OpenIntent` states.
                phase = .failed("This document has no index.")
                CanvasLog.event(.lifecycle, "open refused: the package has no index")
                return
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
            pages.setPages(index.pageIDs, current: currentPageID)
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

    /// The one lookup from identity to state, for the callers that must fail
    /// loud when it is absent.
    ///
    /// ## Two worlds cross this boundary, and they earn different policies
    ///
    /// **Reports from the canvas runtime** — a drawing changed, a page retired,
    /// a layer moved, a turn settled — are synchronous with respect to
    /// page-list mutations: every mutation reconciles the runtime *before the
    /// mutating call returns*, and that reconcile retires a departed page's
    /// canvas before releasing it. A report naming a page this session no
    /// longer holds therefore cannot be produced by any sequence the session
    /// permits, so it is a defect and it traps here (`Contract.md` — Invalid
    /// states fail loud).
    ///
    /// **Returns from the store** — a page load, an asset write — are
    /// asynchronous and deliberately uncancelled, so they can legitimately
    /// outlive the page that asked for them. Those callers use
    /// `stateIndexIfPresent(of:)` and drop the result loudly; `fetchPageData`
    /// is the one that matters. That is a finding of fact about the load path
    /// rather than leniency, and it is the same distinction the runtime's own
    /// decode token draws one level down: cancel so the work stops, compare so
    /// what finished cannot install stale.
    private func stateIndex(of pageID: UUID) -> Int {
        guard let found = stateIndexIfPresent(of: pageID) else {
            preconditionFailure(
                "no state for page \(pageID); a report about a page this session "
                    + "does not hold means a page-list mutation did not reconcile "
                    + "the runtime before it returned"
            )
        }
        return found
    }

    /// The same lookup, for the callers that may legitimately ask about a page
    /// this session does not have: the store's asynchronous returns, and the
    /// runtime's *questions* asked before `start()` has populated the session —
    /// reachable in tests alone, where hosting order is the setup's choice.
    ///
    /// A separate spelling rather than a softening of `stateIndex(of:)`, so
    /// that the callers which must fail loud keep doing so: an answerable
    /// question and a broken invariant look identical at the call site
    /// otherwise.
    private func stateIndexIfPresent(of pageID: UUID) -> Int? {
        pageStates.firstIndex(where: { $0.id == pageID })
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
    private func content(forPage pageID: UUID) -> PagedCanvasController.PageContent {
        // Unknown only when the runtime lays out before `start()` has
        // populated the session — reachable in tests alone, where hosting
        // order is the setup's choice.
        guard let pageIndex = stateIndexIfPresent(of: pageID) else { return .blank }
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
                    "page \(pageID) is clean but its durable bytes are missing"
                )
            }
            return data.isEmpty ? .blank : .ink(data)
        case .live:
            preconditionFailure(
                "asked to rebuild page \(pageID) while its live canvas is the authority"
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

    /// What sits beneath a page's ink: its recognized layers, in order.
    ///
    /// **A page carrying a refused layer answers empty.** Such a page is a
    /// placeholder rather than a canvas, so nothing asks — but if anything ever
    /// does, the answer must not be the layers it *could* read. A stack missing
    /// the layer it refused would render as a picture that looks correct and is
    /// not, which is the one failure the layer model exists to prevent.
    private func staticLayers(forPage pageID: UUID) -> [LayerEnvelope] {
        guard let pageIndex = stateIndexIfPresent(of: pageID) else { return [] }
        guard pageStates[pageIndex].refusedLayers.isEmpty else { return [] }
        return pageStates[pageIndex].staticLayers
    }

    /// What a page's canvas is built with: that page's own geometry, and the
    /// document's zoom cap.
    ///
    /// Out of range only when the runtime lays out before `start()` has
    /// populated the session, exactly as `content(forPageAt:)` can be. The
    /// canonical page is the right answer there for the same reason `.blank`
    /// is: the session replaces the slot the moment it knows better, through
    /// `setPages`.
    private func projection(forPage pageID: UUID) -> PageProjection {
        index.pageIDs.firstIndex(of: pageID)
            .flatMap { index.projection(ofPageAt: $0) } ?? .canonical
    }

    /// Drops every cached composite whose page has left the live window plus
    /// the prefetch radius — the render cache's eviction policy, driven from
    /// the one place that knows page order.
    ///
    /// The same radius and the same moment as `pruneDurableBytes`, because it
    /// is the same rule wearing a different hat: nothing is retained because it
    /// might be wanted again (`Contract.md` — Performance).
    ///
    /// This is also where the warm happens — phase 3c's "at turn: prefetch"
    /// bullet. Its gate, `turn-settles-once`, is met: a turn commits once, at
    /// rest, on the settle callbacks
    /// (`PagedCanvasControllerTests.halfDragCommitsNothing`,
    /// `pageChangeIsReportedOnceWhenSettled`, `flingAcrossPagesReportsOneTurn`),
    /// so an abandoned half-drag reaches here zero times and a completed turn
    /// exactly once — nothing can double-decode. The visible page's layers
    /// travel as the protected set, so warming can never answer byte-bound
    /// pressure by evicting the composite on screen; a warm for a page that
    /// leaves the window before it lands is dropped by the next retain, which
    /// is this path's droppability.
    private func retainRenderedLayers() {
        let current = index.currentPageIndex
        let lower = max(0, current - Self.prefetchRadius)
        let upper = min(pageStates.count - 1, current + Self.prefetchRadius)
        guard lower <= upper else { return }

        var live: Set<UUID> = []
        for pageIndex in lower...upper {
            for layer in pageStates[pageIndex].staticLayers { live.insert(layer.layerID) }
        }
        let visible = Set(pageStates[current].staticLayers.map(\.layerID))
        let renderer = staticRenderer
        Task { await renderer.retain(layerIDs: live, protecting: visible) }
    }

    /// Warms the prefetch window's other pages' base composites, outermost
    /// first, so the nearest neighbour is the most recently inserted when the
    /// byte bound bites.
    ///
    /// Called after the turn's `fetchPageData` returns, not beside the
    /// retain: a neighbour's layer list arrives with its bytes, and warming
    /// before the fetch would find every un-visited page empty and warm
    /// nothing. The window is re-read here rather than captured at the turn,
    /// which is what makes a warm for an already-departed window a no-op
    /// rather than wasted decode.
    ///
    /// A page carrying a refusal is skipped for the reason
    /// `staticLayers(forPageAt:)` answers it empty: no partial composite may
    /// exist to be mistaken for a correct one. The decode runs on the
    /// renderer's global-executor path, never here and never on main; a page
    /// already cached or already rendering costs one dictionary look.
    private func warmNeighbourComposites() {
        let current = index.currentPageIndex
        let lower = max(0, current - Self.prefetchRadius)
        let upper = min(pageStates.count - 1, current + Self.prefetchRadius)
        guard lower <= upper else { return }
        let renderer = staticRenderer

        for pageIndex in (lower...upper).sorted(by: {
            abs($0 - current) > abs($1 - current)
        }) where pageIndex != current {
            guard pageStates[pageIndex].refusedLayers.isEmpty,
                  !pageStates[pageIndex].staticLayers.isEmpty,
                  let geometry = index.geometry(ofPageAt: pageIndex),
                  let detail = liveRuntime?.compositeDetail(forPage: pageStates[pageIndex].id)
            else { continue }
            let request = StaticLayerRequest(
                layers: pageStates[pageIndex].staticLayers,
                geometry: geometry,
                pixelsPerPagePoint: detail
            )
            Task { await renderer.warm(request) }
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
            "This page references a source file (\(assetID.uuidString)) "
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

        // **The identities, taken before the first await.** The bounds were
        // computed above against the list as it is now, and each iteration
        // below suspends; indexing `index.pageIDs` after one of those
        // suspensions would read whatever page has moved into that position.
        // A snapshot of identities cannot go stale — it can only name a page
        // that no longer exists, which the lookups below answer for.
        let candidates = Array(index.pageIDs[lower...upper])

        for pageID in candidates {
            // The page may have been deleted by a mutation that ran during an
            // earlier iteration's await.
            guard let waiting = stateIndexIfPresent(of: pageID) else { continue }
            guard case .loading = pageStates[waiting].ink,
                  !pageLoadsInFlight.contains(pageID) else { continue }

            pageLoadsInFlight.insert(pageID)
            defer { pageLoadsInFlight.remove(pageID) }

            do {
                let loaded = try await store.loadPage(pageID)
                // A store return, not a runtime report: page loads are
                // deliberately never cancelled ("dedup, not staleness"), so a
                // load *will* outlive a page deleted while it was in flight.
                // Its bytes are a cache entry for a page that no longer exists,
                // so dropping them loses nothing — and trapping here would turn
                // an ordinary delete during a fetch into a crash.
                guard let landing = stateIndexIfPresent(of: pageID) else {
                    CanvasLog.event(
                        .lifecycle,
                        "page \(pageID) loaded after it was removed from the "
                            + "document; its bytes are dropped"
                    )
                    continue
                }
                pageStates[landing].bytesLoaded(loaded)
            } catch {
                CanvasLog.event(
                    .lifecycle,
                    "page \(pageID) failed to load: \(error)"
                )
                guard let landing = stateIndexIfPresent(of: pageID) else { continue }
                pageStates[landing].loadFailed(String(describing: error))
            }
            liveRuntime?.reloadPage(pageID)
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
    ///
    /// **It is defined by that relationship, not by its value.** The runtime
    /// keeps `PagedCanvasController.windowRadius` pages either side live; this
    /// is that plus one, so a page entering the window always finds its bytes
    /// and its warmed composite already here rather than starting a load under
    /// the finger. When the window grew to two (device verdict, 2026-08-07)
    /// this grew with it — leaving it at 2 would have meant the outermost live
    /// page was also the outermost prefetched one, and every turn would build a
    /// canvas for bytes that had not been asked for yet.
    private static let prefetchRadius = 3

    // MARK: - Appending

    /// Adds a blank page at the end and turns to it.
    ///
    /// The page is on screen immediately and durable only once it takes ink
    /// (`Contract.md` — Navigation). `Page(appended:)` builds it clean over
    /// empty bytes and flagged `neverWritten`, and `durableIndex` withholds the
    /// trailing run of such pages from every save, so the swipe that overshot
    /// the last page costs one entry in `pageStates` until the user either
    /// writes on it or leaves — never a page file and never a line in the
    /// index.
    private func appendPage() {
        // Appending during an in-flight save is safe, and refusing it violated
        // Navigation's "immediately": the save holds its captured index by
        // value, `DocumentStore.save` validates its batch against that capture,
        // and this page is not in either — it is withheld until it takes ink,
        // and the ink is what re-arms (`performOneSave`'s exit owns that).
        if isClosing {
            CanvasLog.event(.lifecycle, "page append after close; ignored")
            return
        }
        guard phase == .ready else { return }

        // **The canonical geometry, always** — which is what makes mixed
        // geometry the normal state of an annotated import rather than an edge
        // case: swiping past the last page of a landscape worksheet lands you
        // on a portrait page. The appended page is this application's own page,
        // not a continuation of whatever was imported before it, and a blank
        // page shaped like the last import would make the shape of a new page
        // depend on where you happened to be standing.
        let appended = PageRecord(id: UUID(), geometry: .canonical)
        pageStates.append(Page(appended: appended.id))
        index = index.withPages(index.pages + [appended], currentPageIndex: index.pages.count)
        // The session's own index changed, so it says so. The pass this arms
        // writes nothing: the index it hands the store is `durableIndex`, which
        // for an unwritten trailing page is byte for byte the one already on
        // disk, and the store writes an index only when it differs.
        indexDirty = true
        alignedWithIndex()

        pages.setPages(index.pageIDs, current: currentPageID)
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
    private func drawingChanged(onPage pageID: UUID) {
        if isClosing {
            // After close no canvas should exist to send this; one arriving is
            // a caller holding a released editor. Ignored rather than trapped
            // — UIKit can race a change notification against the Back that
            // triggered the close — but loud, because losing it is losing the
            // invariant, not the ink: a closing session's ink was captured by
            // the final pass or is still live in the canvas that sent this.
            CanvasLog.event(
                .lifecycle,
                "drawing change on page \(pageID) after close; ignored — "
                    + "no canvas should exist to send one"
            )
            return
        }
        guard phase == .ready else { return }
        // Traps for an unknown page rather than returning: see `stateIndex(of:)`.
        // A canvas reporting a stroke for a page this session does not hold has
        // outlived a mutation that failed to reconcile the runtime, and the
        // stroke is about to be accounted to whatever page is nearby.
        let pageIndex = stateIndex(of: pageID)
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
    private func pageIsRetiring(_ pageID: UUID, snapshot: DrawingSnapshot) {
        guard phase == .ready else { return }
        // Traps for an unknown page rather than returning, and this is the
        // report where that matters most: a handover the session cannot file is
        // a page's unsaved ink with nowhere to go. A *deleted* page never
        // reaches here — the reconciler retires it without handing over — so
        // arriving here for a page the session does not hold means a canvas
        // outlived its page without that reconcile.
        pageStates[stateIndex(of: pageID)].retired(handingOver: snapshot)
    }

    /// The visible page settled on a new page.
    private func currentPageChanged(to pageID: UUID) {
        if isClosing {
            CanvasLog.event(.lifecycle, "page turn to \(pageID) after close; ignored")
            return
        }
        guard phase == .ready, let pageIndex = index.pageIDs.firstIndex(of: pageID) else { return }
        guard pageIndex != index.currentPageIndex else { return }

        index = index.withPages(index.pages, currentPageIndex: pageIndex)
        indexDirty = true
        alignedWithIndex()
        pruneDurableBytes()
        retainRenderedLayers()
        Task { [weak self] in
            await self?.fetchPageData(forPagesAround: pageIndex)
            // Only after the fetch: a prefetch-distance page's layer list
            // arrives with its bytes, and this is the one moment — a settled
            // turn, which fires exactly once — the fork doc's "at turn:
            // prefetch" attaches to.
            self?.warmNeighbourComposites()
        }
        markDirty()
    }

    private func markDirty() {
        // New work arms no debounce on a closing session — the intakes above
        // this are each refused already; this is the backstop. The save
        // path's own rearm is `performOneSave`'s exit, not here, so the
        // retry that drains a dirty close keeps running under the flag.
        guard !isClosing else { return }
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
        debounceTask = Task { [weak self, clock] in
            // Cancellation is the ordinary outcome here — every edit cancels
            // the pending debounce and arms a fresh one — so it is caught and
            // named rather than swallowed by a `try?` that would answer a
            // genuine failure with the same silence.
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
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
    /// exactly the floor from their first save onwards — before it, every
    /// session starts at `coldSerializeEstimate` and so four milliseconds above
    /// the floor.
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

    /// The document as a save would write it: `index`, minus the trailing run
    /// of pages nobody has written on.
    ///
    /// Swiping past the last page yields a page immediately, because a turn
    /// that lands on nothing is not a page turn — and an overswipe is something
    /// a person does by reflex, repeatedly. A page created that way and never
    /// written on is not a page the user asked for, so it becomes part of the
    /// saved document at its first ink and not before (`Contract.md` —
    /// Navigation). Without this, a stray flick grew the file permanently and
    /// nothing ever reclaimed it.
    ///
    /// **Only a trailing run.** A blank page with written pages after it — a
    /// PDF imported past one — would renumber every page behind it if it
    /// vanished from the file, so it is durable like any other; only what hangs
    /// off the end can be withheld, and only until it takes ink.
    ///
    /// The current page follows: the user may be standing on a page the
    /// document does not have, and what the document remembers is the last page
    /// it does. This is the one deliberate divergence between the pages on
    /// screen and the pages in the file.
    private var durableIndex: DocumentIndex {
        var count = pageStates.count
        while count > 1, pageStates[count - 1].neverWritten {
            // A withheld page must have nothing to write, or this pass would
            // capture ink for a page the index it writes does not name — the
            // dangling reference `Contract.md` — Durable form calls fatal.
            // `neverWritten` is cleared by the first ink and the first layer,
            // so this holds by construction and fails loud if it stops.
            precondition(
                !pageStates[count - 1].isDirty,
                "page \(pageStates[count - 1].id) is unwritten and dirty at once"
            )
            count -= 1
        }
        guard count < index.pages.count else { return index }
        return index.withPages(
            Array(index.pages.prefix(count)),
            currentPageIndex: min(index.currentPageIndex, count - 1)
        )
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
    ///
    /// The index it captures is `durableIndex` rather than `index`: a trailing
    /// page nobody has written on is on screen and not in the document.
    @discardableResult
    private func beginSave() -> Task<Void, Never>? {
        if let currentSave { return currentSave }
        guard phase == .ready, dirty else { return nil }

        let capturedIndex = durableIndex
        let capturedIndexWasDirty = indexDirty
        indexDirty = false

        // A page the captured index does not name has no file to write into:
        // writing one would be the orphan the write ordering forbids, and
        // naming it in the index without writing one would be the dangling ref
        // it forbids harder. The withheld run is exactly this difference.
        let durablePageIDs = Set(capturedIndex.pageIDs)

        var captures: [Capture] = []
        for pageIndex in pageStates.indices where durablePageIDs.contains(pageStates[pageIndex].id) {
            // Captured with the ink, because a page's generation is one
            // coherent moment: the list this pass writes is the list as it is
            // now, and a later edit to it is a later pass's work, never this
            // one's. `changed` is the subset whose files this pass must
            // actually replace — since the split, that is the difference
            // between rewriting a 50 MB import's envelope on every stroke and
            // rewriting one small ink file.
            let layers = pageStates[pageIndex].staticLayers
            let changedStatic = pageStates[pageIndex].changedStaticLayerIDs
            let inkLayerID = pageStates[pageIndex].inkLayerID
            switch pageStates[pageIndex].ink {
            case .loading, .unreadable:
                continue
            case .clean:
                // Clean ink and a changed layer list. The ink layer's file
                // already holds exactly these bytes, so this pass does not
                // rewrite it; what changed is the list, and possibly the
                // envelopes in it.
                //
                // Or clean ink and no file at all: an unwritten page the
                // captured index *does* name is one a written page landed
                // behind, so it stopped being withheld and this pass owes it
                // its first file — blank, but present, because the index about
                // to name it must not dangle. Its ink layer is written with it
                // for the same reason: there is nothing on disk to keep.
                let firstWrite = pageStates[pageIndex].neverWritten
                guard pageStates[pageIndex].layersUnsaved || firstWrite else { continue }
                guard let durable = pageStates[pageIndex].durable else {
                    preconditionFailure(
                        "page \(pageStates[pageIndex].id) has an unsaved layer list "
                            + "but no durable ink to write it with"
                    )
                }
                pageStates[pageIndex].beginSaving(.serialized(durable))
                captures.append(
                    Capture(
                        pageStates[pageIndex].id,
                        .serialized(durable),
                        layers,
                        firstWrite ? changedStatic.union([inkLayerID]) : changedStatic
                    )
                )
            case .live:
                guard let snapshot = liveRuntime?.snapshot(ofPage: pageStates[pageIndex].id) else {
                    preconditionFailure(
                        "page \(pageStates[pageIndex].id) is live but its canvas "
                            + "yielded no snapshot"
                    )
                }
                pageStates[pageIndex].beginSaving(.drawing(snapshot))
                captures.append(
                    Capture(
                        pageStates[pageIndex].id,
                        .drawing(snapshot),
                        layers,
                        changedStatic.union([inkLayerID])
                    )
                )
            case .held(let unsaved):
                pageStates[pageIndex].beginSaving(unsaved)
                captures.append(
                    Capture(
                        pageStates[pageIndex].id,
                        unsaved,
                        layers,
                        changedStatic.union([inkLayerID])
                    )
                )
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
        /// Which of the page's layers this pass must actually write. Captured
        /// with everything else rather than recomputed at write time, because
        /// it describes the same instant the ink and the list were taken from.
        let changedLayerIDs: Set<UUID>

        init(
            _ pageID: UUID,
            _ unsaved: Page.UnsavedInk,
            _ staticLayers: [LayerEnvelope],
            _ changedLayerIDs: Set<UUID>
        ) {
            self.pageID = pageID
            self.unsaved = unsaved
            self.staticLayers = staticLayers
            self.changedLayerIDs = changedLayerIDs
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
        var slowestPage: Duration?
        for capture in captures {
            let data: Data
            switch capture.unsaved {
            case .serialized(let alreadySerialized):
                data = alreadySerialized
            case .drawing(let snapshot):
                let serialized = await snapshot.serialized()
                data = serialized.data
                slowestPage = max(slowestPage ?? .zero, serialized.duration)
            }
            changedPages[capture.pageID] = data
            pageStates[stateIndex(of: capture.pageID)].serializedWhileSaving(data)
        }
        // Measured where the work happens rather than timed again here: the next
        // debounce is derived from this cost (`Contract.md` — Saving). A pass
        // that encoded nothing leaves the last real measurement standing —
        // `nil` here is "not measured", which is not the same as "free".
        if let slowestPage { lastSerializeDuration = slowestPage }

        // The session is the one writer of a page's layer list (`Docs/Forks/
        // CanvasFeatureComplete.md` — One value, one writer), so the envelopes
        // are built here, not in the store: the page's static layers in order,
        // then its one ink layer, identity transform, under the identity loaded
        // from or first written to disk. Ink last is by construction here and
        // checked again by the store on the way in and on the way out.
        var writes: [PageWrite] = []
        for capture in captures {
            guard let data = changedPages[capture.pageID] else { continue }
            let page = pageStates[stateIndex(of: capture.pageID)]
            writes.append(
                PageWrite(
                    pageID: capture.pageID,
                    layers: capture.staticLayers + [inkEnvelope(for: page, payload: data)],
                    changedLayerIDs: capture.changedLayerIDs
                )
            )
        }

        do {
            // Only the pages that were edited, and within them only the layers
            // that changed. The store rewrites a page file only if its layer
            // list changed and the index only if it changed, so an ordinary ink
            // save touches exactly one file.
            try await store.save(index: capturedIndex, pages: writes)
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
        } catch let refusal as PageSaveRefusal {
            // The store's refusal is per page, and so is the acknowledgement:
            // every page the refusal does not name was written and is durable,
            // so it becomes clean exactly as a fully successful pass would
            // make it. Only the refused pages stay dirty, holding their
            // already-serialized bytes, and the refusal is surfaced loudly —
            // one poisoned page must never leave every other page's ink
            // knowingly unsaved.
            let refusedIDs = Set(refusal.refusedPages.map(\.pageID))
            for capture in captures {
                guard let data = changedPages[capture.pageID] else { continue }
                if refusedIDs.contains(capture.pageID) {
                    pageStates[stateIndex(of: capture.pageID)].saveFailed(restoring: data)
                } else {
                    pageStates[stateIndex(of: capture.pageID)].saveSucceeded(
                        written: data,
                        layersWritten: capture.staticLayers
                    )
                }
            }
            indexDirty = indexDirty || (capturedIndexWasDirty && !refusal.indexWritten)
            lastSaveError = String(describing: refusal)
            consecutiveSaveFailures += 1
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
        // `isClosing` on every layer entry point: an edit arriving after
        // `close()` is a caller violating the lifecycle, and the refusal is
        // the thrown kind the entry already speaks — before the asset write,
        // so a refused import leaves no orphan.
        guard phase == .ready, !isClosing else { throw LayerEditError.sessionNotReady }
        let targetPageID = pageID ?? currentPageID
        try requireLayerListIsEditable(targetPageID)

        // The leaf, first and on its own: nothing yet references it, so a
        // failure here leaves the document exactly as it was.
        let assetID = UUID()
        try await store.writeAsset(bytes, assetID: assetID, format: format)

        // The page may have moved through states while that write ran — and so
        // may the session: a close that landed inside the asset write refuses
        // the layer, leaving the asset an inert orphan rather than the page
        // list a closed session swore it would not touch.
        guard !isClosing else { throw LayerEditError.sessionNotReady }
        try requireLayerListIsEditable(targetPageID)

        let layerID = UUID()
        // The geometry of **the page it lands on**, not the document's — there
        // is no document geometry any more. An image dropped on a landscape
        // worksheet fits that worksheet; the same image on the portrait page
        // after it fits differently, which is what "the zoom floor derives from
        // the page it belongs to" means one level down.
        guard let targetIndex = index.pageIDs.firstIndex(of: targetPageID),
              let geometry = index.geometry(ofPageAt: targetIndex)
        else {
            throw LayerEditError.pageNotFound(targetPageID)
        }
        let envelope = try LayerEnvelope.image(
            layerID: layerID,
            ref: ImageLayerRef(assetID: assetID, format: format),
            pageSpaceTransform: .fittingSource(
                width: sourceWidth,
                height: sourceHeight,
                inPageOfWidth: geometry.width,
                height: geometry.height
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

        // The page's ink is untouched, so its canvas is not rebuilt — only what
        // sits beneath it changes. Before the save, deliberately: the composite
        // renders from the asset, which is already durable, and making the user
        // wait for a page write to see their own import would be a save on an
        // interaction path in everything but name.
        liveRuntime?.reloadStaticLayers(onPage: targetPageID)

        await saveIfNeeded()
        return layerID
    }

    /// Imports one PDF: **one source page becomes one document page**, each
    /// carrying one `pdf` layer with the page's own ink layer above it.
    ///
    /// One import is one asset, however many pages the PDF has. The source
    /// bytes are written once, unnormalized and never rewritten, and every
    /// appended page's layer points at that one file with its own
    /// `sourcePageIndex`. Fifty pages of a fifty-page worksheet cost one copy
    /// of the worksheet.
    ///
    /// Leaf to root, in this order and for this reason: the asset is durable
    /// before any layer file names it, so an interruption at any point leaves
    /// an orphan asset — inert, merely heavy — and never a layer file naming an
    /// asset that is not there. `DocumentStore.save` enforces the same order
    /// rather than trusting this one caller.
    ///
    /// Nothing is rendered here and nothing is decoded beyond the page count
    /// and each page's box: `PDFSource` reads the source's own geometry off the
    /// main thread, the transform places each page's unit square in the
    /// document page, and rasterizing is the canvas runtime's, in its own lane.
    ///
    /// The appended pages land at the end and **the visible page does not
    /// change**. Turning to an import is navigation, and navigation on import
    /// is the import UI's decision, not the durable form's.
    ///
    /// No UI calls this yet. It is the entry point phase 3's durable half is
    /// testable through, and the one the import UI will call when it exists.
    @discardableResult
    func importPDF(_ bytes: Data) async throws -> [UUID] {
        guard phase == .ready, !isClosing else { throw LayerEditError.sessionNotReady }

        // Off the main thread by construction, before anything durable is
        // touched: a PDF this build cannot open imports nothing at all rather
        // than half a document.
        let sourcePages = try await PDFSource.pages(in: bytes)

        // Every source box is judged before the first byte is written. An
        // imported page *is* its source box (below), and geometry is durable
        // from that moment — persisted long before any canvas lays the page
        // out. A box narrower than the document's zoom cap can display would
        // therefore be written first and only refused later, by the
        // precondition in `PageCanvasController.establishZoomIfNeeded`, which
        // is a trap: the document would then crash on every subsequent open,
        // with no recovery. So it is refused here, where refusing still costs
        // nothing.
        //
        // One bad page refuses the whole import, for the same reason unreadable
        // bytes do: half a document is worse than none.
        let minimum = PageProjection.smallestDisplayablePagePoints(
            zoomCapPagePointsPerPixel: index.zoomCapPagePointsPerPixel
        )
        for source in sourcePages where source.width < minimum || source.height < minimum {
            throw LayerEditError.pageTooSmallToDisplay(
                width: source.width,
                height: source.height,
                minimum: minimum
            )
        }

        // The leaf, first and on its own: nothing yet references it, so a
        // failure here leaves the document exactly as it was.
        let assetID = UUID()
        try await store.writeAsset(bytes, assetID: assetID, format: .pdf)

        // The session may have moved on while that write ran.
        guard phase == .ready, !isClosing else { throw LayerEditError.sessionNotReady }

        var appended: [PageRecord] = []
        for source in sourcePages {
            // **The imported page is its source's size**, in page points. Until
            // phase 3b geometry was one global value, so this fitted an
            // 842 × 595 worksheet into a 612 × 792 page and letterboxed it —
            // the page had white bands the source never had, and the ink you
            // wrote in them belonged to nothing. Now the page *is* the source
            // page, so `fittingSource` below places the unit square edge to
            // edge and the bands are gone.
            let geometry = PageGeometry(width: source.width, height: source.height)
            let page = PageRecord(id: UUID(), geometry: geometry)
            let envelope = try LayerEnvelope.pdf(
                layerID: UUID(),
                ref: PDFLayerRef(assetID: assetID, sourcePageIndex: source.index),
                pageSpaceTransform: .fittingSource(
                    width: source.width,
                    height: source.height,
                    inPageOfWidth: geometry.width,
                    height: geometry.height
                )
            )
            pageStates.append(Page(appended: page.id))
            appended.append(page)
            // Ink last is not a rule this site remembers: the save path builds
            // `staticLayers + [ink]`, so it cannot write anything else.
            pageStates[pageStates.count - 1].layerListChanged(
                to: [envelope],
                refusedLayers: []
            )
        }

        index = index.withPages(
            index.pages + appended,
            currentPageIndex: index.currentPageIndex
        )
        indexDirty = true
        alignedWithIndex()
        pages.setPages(index.pageIDs, current: currentPageID)

        CanvasLog.event(
            .canvas,
            "imported asset \(assetID) as \(appended.count) pdf page(s); "
                + "pages=\(index.pageIDs.count)"
        )

        // Immediate rather than debounced, for the reason an image import is:
        // a debounce coalesces Pencil-frequency edits, and an import is one
        // discrete action whose heavy bytes are already on disk. Every
        // millisecond it stays unsaved is a millisecond the asset is an orphan.
        await saveIfNeeded()
        return appended.map(\.id)
    }

    /// The canvas runtime committed one layer transform.
    ///
    /// The whole gesture — selection, the grab, every intermediate frame —
    /// stayed inside `PageCanvasController` and reached nothing here. This is
    /// the single point at which it crosses, carrying one immutable value, and
    /// it is the same seam a retiring page's drawing crosses.
    ///
    /// Returns whether the edit was written. A refusal is answered rather than
    /// thrown because the caller is a gesture, not a program: the canvas puts
    /// the layer back where it was, so the picture never disagrees with the
    /// file.
    private func layerTransformed(
        onPage pageID: UUID,
        layerID: UUID,
        to transform: PageSpaceTransform
    ) -> Bool {
        guard phase == .ready else { return false }
        // No page-existence guard of its own: `transformLayer` refuses an
        // unknown page with a typed `pageNotFound`, which the catch below logs
        // and answers `false` to. That is the honest shape for this one report
        // — the caller is a gesture, and a refusal it can act on beats both a
        // trap and a silent `false`, because the canvas puts the layer back and
        // the picture never disagrees with the file.
        do {
            _ = try transformLayer(layerID, onPage: pageID, to: transform)
            return true
        } catch {
            CanvasLog.event(
                .canvas,
                "layer \(layerID) on page \(pageID) was not transformed: \(error)"
            )
            return false
        }
    }

    /// Moves, scales, or rotates one layer, and returns the value it replaced.
    ///
    /// The session is the layer list's one writer (`Contract.md` — Owners,
    /// golden rule 5), so this is the only place a layer's placement changes.
    /// It returns the **prior envelope** because that value is the inverse an
    /// undo restores: recording it is the caller's, so that undo lives in the
    /// one manager per page rather than in a history this object would have to
    /// own (`Contract.proposed.md` A10 — no second manager).
    ///
    /// Debounced rather than saved immediately, unlike `importImage`. An import
    /// races nothing but has an asset on disk that is an orphan until its page
    /// file names it; a transform names nothing new, and a drag is exactly the
    /// interaction-frequency edit a debounce exists to coalesce.
    ///
    /// A singular transform is a `precondition` and not a throw: the gesture
    /// declines to produce one frame by frame, so one arriving here is a defect
    /// in a caller rather than an edit to refuse (`Contract.md` — Invalid
    /// states fail loud).
    @discardableResult
    func transformLayer(
        _ layerID: UUID,
        onPage pageID: UUID,
        to transform: PageSpaceTransform
    ) throws -> LayerEnvelope {
        precondition(
            transform.isInvertible,
            "layer \(layerID) cannot be placed by a singular transform"
        )
        let existing = try replaceLayer(layerID, onPage: pageID) { layer in
            guard !layer.locked else {
                throw LayerEditError.layerIsLocked(layerID: layerID, pageID: pageID)
            }
            return layer.withPageSpaceTransform(transform)
        }
        CanvasLog.event(
            .canvas,
            "layer \(layerID) on page \(pageID) moved to "
                + "(\(transform.a), \(transform.b), \(transform.c), \(transform.d), "
                + "\(transform.tx), \(transform.ty))"
        )
        return existing
    }

    /// Locks or unlocks one layer, and returns the value it replaced.
    ///
    /// No UI calls this yet, exactly as no UI called `importImage` when phase 2
    /// landed. It is here because `locked` is only allowed to exist at all if
    /// something reads it, and something reading a bit nothing can ever write
    /// is the same dead field wearing a different hat: this is its one writer,
    /// `LayerSelectionRuntime` and `transformLayer` are its two readers.
    @discardableResult
    func setLayerLocked(
        _ layerID: UUID,
        onPage pageID: UUID,
        locked: Bool
    ) throws -> LayerEnvelope {
        let existing = try replaceLayer(layerID, onPage: pageID) { $0.withLocked(locked) }
        CanvasLog.event(.canvas, "layer \(layerID) on page \(pageID) locked=\(locked)")
        return existing
    }

    /// Replaces one layer of a page's list with a new value, and returns the
    /// old one. The one shape every non-structural layer edit takes.
    private func replaceLayer(
        _ layerID: UUID,
        onPage pageID: UUID,
        with replacement: (LayerEnvelope) throws -> LayerEnvelope
    ) throws -> LayerEnvelope {
        // Covers `transformLayer` and `setLayerLocked`. The gesture path
        // (`layerTransformed`) catches the throw and logs it, which is the
        // loud-but-uncrashed refusal an input UIKit can race deserves.
        guard phase == .ready, !isClosing else { throw LayerEditError.sessionNotReady }
        try requireLayerListIsEditable(pageID)

        let page = stateIndex(of: pageID)
        guard let existing = pageStates[page].staticLayers.first(
            where: { $0.layerID == layerID }
        ) else {
            throw LayerEditError.layerNotFound(layerID: layerID, pageID: pageID)
        }

        let updated = try replacement(existing)
        guard updated != existing else { return existing }

        pageStates[page].layerListChanged(
            to: pageStates[page].staticLayers.map { $0.layerID == layerID ? updated : $0 },
            // Untouched: this edit neither creates nor repairs a refusal, and a
            // page carrying one never reaches here — `requireLayerListIsEditable`
            // refuses it.
            refusedLayers: pageStates[page].refusedLayers
        )

        // The ink is untouched, so the canvas is told rather than rebuilt —
        // the same distinction `importImage` and `deleteLayer` make, and the
        // reason `reloadStaticLayers` exists separately from `reloadPage`.
        liveRuntime?.reloadStaticLayers(onPage: pageID)
        markDirty()
        return existing
    }

    /// Deletes one layer from a page — **the** site that deletes layers, and
    /// therefore the site delete-inline reclamation lives at, now at two
    /// levels: the layer file and then the asset.
    ///
    /// Root to leaf, the mirror of the write order: the page file drops the ref
    /// first, the layer file dies second, the asset dies third. An interruption
    /// between any two of them leaves an orphan, never a dangling ref.
    ///
    /// Reclamation's soundness is split between the store and this file. The
    /// store answers "does anything still reference this?" from the files on
    /// disk, so a page write that failed leaves the old ref there and the
    /// layer file lives. What disk cannot answer for is a layer list that has
    /// never landed at all — an import whose save failed references its asset
    /// only in memory — so reclamation runs only while no page holds an
    /// unsaved layer list; see the guard below.
    ///
    /// Crash orphans still accumulate — an import interrupted before its page
    /// write, a delete interrupted before its asset write — and that is
    /// accepted for now. Sweep-on-open is deferred behind
    /// `failure-has-a-taxonomy`, because a sweep that deletes the wrong file is
    /// a durability failure and needs the taxonomy to say what it does when it
    /// cannot tell. An orphan is inert and merely heavy.
    func deleteLayer(_ layerID: UUID, fromPage pageID: UUID) async throws {
        guard phase == .ready, !isClosing else { throw LayerEditError.sessionNotReady }
        guard index.pageIDs.contains(pageID) else {
            throw LayerEditError.pageNotFound(pageID)
        }
        let page = stateIndex(of: pageID)
        // A page whose own bytes are not here has no layer list to edit —
        // `layerListChanged` traps on it. An evicted far-away page is a state
        // any caller can reach, not a session defect, so it is refused with a
        // typed error rather than a trap; loading the page is the caller's
        // repair. Deliberately checked without `requireLayerListIsEditable`,
        // whose refusal guard would forbid the one deletion that repairs a
        // refused page.
        switch pageStates[page].ink {
        case .clean, .live, .held, .saving:
            break
        case .loading, .unreadable:
            throw LayerEditError.pageNotReady(pageID)
        }
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

        // Same as an import: the ink is untouched, so the canvas is told rather
        // than rebuilt. A page that was refusing input has no canvas to tell —
        // it becomes one below, through `reloadPage`, which asks for the layer
        // list as it builds.
        liveRuntime?.reloadStaticLayers(onPage: pageID)

        await saveIfNeeded()

        // Re-resolved rather than reused: `page` was computed before an await,
        // and an index that outlives one is the class of bug this file already
        // carries elsewhere. Pages are append-only today, which makes this
        // caution rather than a fix.
        if pageStates[stateIndex(of: pageID)].refusedLayers.count != refusalsBefore {
            // A page that was refusing input may now accept it, so the runtime
            // rebuilds the placeholder into a canvas. Only ever reached from a
            // page that had a refusal, which is a page with no live canvas.
            liveRuntime?.reloadPage(pageID)
        }

        // Reclamation asks the *disk* whether anything still references the
        // layer and its asset, and disk can only answer for layer lists that
        // have reached it. While any page holds an unsaved list — this delete's
        // own save failed, or an import's save never landed — a reference can
        // exist only in memory, where the scan is blind, and reclaiming would
        // destroy a write-once asset the surviving layers still need. Skipping
        // costs an orphan, which is inert and merely heavy; the files are
        // reclaimable by a later delete once every list is durable.
        guard !pageStates.contains(where: \.layersUnsaved) else {
            CanvasLog.event(
                .save,
                "reclamation after deleting layer \(layerID) skipped: unsaved "
                    + "layer lists exist, so the on-disk reference scan cannot "
                    + "be trusted; its files stay as inert orphans"
            )
            return
        }
        await reclaim(deleted)
    }

    /// Deletes every `pdf` layer from one page — "throw the worksheet away",
    /// which is the first half of replacing it (`Contract.proposed.md` A11).
    ///
    /// **Why a second producer of layer IDs exists at all.** A11 says a `pdf`
    /// layer is selectable; the code says image-only
    /// (`LayerEnvelope.isSelectable`), and the code is right — a worksheet is
    /// the page's backdrop, not a thing to drag around. But selection is the
    /// only other producer of a `layerID`, so with no path here a mis-imported
    /// PDF is *permanent*: fifty pages of the wrong worksheet, undeletable
    /// from the UI forever. Naming the layers needs no spatial hit test,
    /// because a page's `pdf` layers are a known set — that is exactly why a
    /// delete path can exist without making the kind selectable.
    ///
    /// This is a producer, **not a second writer**: every deletion goes
    /// through `deleteLayer`, which stays *the* site that deletes layers, with
    /// its save, its canvas notification, and its two-level reclamation
    /// unchanged (`Contract.md` — Owners, golden rule 5). The semantics are an
    /// image-layer delete's exactly, including that it is not undoable — undo
    /// is the canvas runtime's per-page `UndoManager`, and no layer deletion
    /// has ever registered with it.
    ///
    /// One page's layers and not the document's: the page is what the user is
    /// looking at, and deleting on pages they cannot see is not a thing one
    /// button may do. The pages of a mis-imported PDF stay — nothing removes a
    /// page yet — so this empties them rather than undoing the import.
    ///
    /// Returns how many were deleted.
    @discardableResult
    func deletePDFLayers(onPage pageID: UUID? = nil) async throws -> Int {
        guard phase == .ready else { throw LayerEditError.sessionNotReady }
        let targetPageID = pageID ?? currentPageID
        guard index.pageIDs.contains(targetPageID) else {
            throw LayerEditError.pageNotFound(targetPageID)
        }
        let doomed = pageStates[stateIndex(of: targetPageID)].staticLayers
            .filter { $0.recognizedKind == .pdf }
            .map(\.layerID)
        guard !doomed.isEmpty else {
            throw LayerEditError.noPDFLayerOnPage(targetPageID)
        }

        // One at a time and through the one delete site, rather than one
        // list-level edit: each pass re-reads the page's state, so a refusal
        // partway through leaves the earlier deletions durable and the rest
        // untouched — the state a hand-run sequence of single deletes would
        // leave, which is the only state the rest of this file already knows
        // how to be in. A page carries one `pdf` layer in every import this
        // build can produce, so the loop is a loop for honesty, not for speed.
        for layerID in doomed {
            try await deleteLayer(layerID, fromPage: targetPageID)
        }
        return doomed.count
    }

    /// Deletes the layer file a just-deleted layer occupied, and then the asset
    /// it referenced if that was the last reference — root to leaf, one step at
    /// a time, each answered from the level above on disk.
    ///
    /// A failure at either step costs an orphan, never data, so it is reported
    /// and not thrown: the layer is already gone from the page, which is the
    /// part that had to be durable.
    private func reclaim(_ deleted: LayerEnvelope) async {
        do {
            try await store.deleteLayerFileIfUnreferenced(layerID: deleted.layerID)
        } catch {
            CanvasLog.event(
                .save,
                "layer \(deleted.layerID) deleted, but its file was not removed: "
                    + "\(error); it is an inert orphan"
            )
            // The asset is not reclaimed either: the layer file may still name
            // it, and the store would find it and refuse anyway.
            return
        }

        // Which asset, if any, this kind referenced. A kind with no asset —
        // ink — reclaims nothing, and so does a payload that will not decode,
        // because what it referenced is then unknown.
        let asset: (id: UUID, format: AssetFormat)?
        do {
            switch deleted.recognizedKind {
            case .ink, nil:
                asset = nil
            case .image:
                let ref = try ImageLayerRef(payload: deleted.payload)
                asset = ref.recognizedFormat.map { (ref.assetID, $0) }
            case .pdf:
                asset = (try PDFLayerRef(payload: deleted.payload).assetID, .pdf)
            }
        } catch {
            CanvasLog.event(
                .save,
                "layer \(deleted.layerID) deleted, but its payload would not decode: "
                    + "\(error); its asset is left alone"
            )
            return
        }

        guard let asset else { return }
        do {
            try await store.deleteAssetIfUnreferenced(assetID: asset.id, format: asset.format)
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
    ///
    /// Legal during and after `close()` without a guard: it is a subset of the
    /// teardown — drop the timer, await the save, one pass — and on a session
    /// closed clean every step finds nothing to do.
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
    ///
    /// On a session that closed clean this is a programmer error — the caller
    /// is holding a dead session — and is refused loud. On a session closing
    /// dirty it works as ever: the retained lifecycle still receives scene
    /// events, and arming the drain is exactly what retain-if-dirty is for.
    func resumeForForeground() {
        if isClosedClean {
            CanvasLog.event(
                .lifecycle,
                "resumeForForeground on a session that closed clean; ignored — "
                    + "a clean-closed session is dead and is never restarted"
            )
            return
        }
        guard phase == .ready, dirty, currentSave == nil else { return }
        scheduleSave()
    }

    /// The real teardown behind Back: after this returns `.clean` the session
    /// is dead and the package may be released to library mutations; after
    /// `.dirty` it must not be — the session stays alive and drains
    /// (`Docs/Contract.proposed.md` L4).
    ///
    /// Idempotent: a second call awaits the one teardown and reports the
    /// session as it stands, never running a second one. New edits are refused
    /// from the first call's entry, synchronously — the flag is set before the
    /// teardown's first suspension.
    package func close() async -> CloseOutcome {
        if let closeTask {
            let outcome = await closeTask.value
            guard case .dirty = outcome else { return outcome }
            // A dirty close left the retry machinery draining; report what is
            // true *now* rather than then. Reading state and awaiting the
            // protected save is not a second teardown — no pass is started.
            await currentSave?.value
            guard !dirty else { return .dirty(lastSaveError ?? Self.stillDirtyDescription) }
            concludeCleanClose()
            return .clean
        }

        isClosing = true
        let teardown = Task { await self.performClose() }
        closeTask = teardown
        return await teardown.value
    }

    /// The sequence L4 states, in its order. Protected work is awaited and
    /// never cancelled: a Back during `.loading` must not race the start's
    /// save against library mutations (`Docs/Forks/Library/03-review.md` B1),
    /// and `currentSave` owns pages marked `.saving`. Only the debounce — a
    /// timer, never a capture — is cancellable here.
    private func performClose() async -> CloseOutcome {
        await startTask?.value
        debounceTask?.cancel()
        debounceTask = nil
        // Awaits the in-flight save, then one final pass through the ordinary
        // machinery — the same capture, the same acknowledgement, and on
        // failure the same retry rearm at `performOneSave`'s exit, which is
        // the mechanical half of retain-if-dirty (B3).
        await saveIfNeeded()

        guard !dirty else {
            return .dirty(lastSaveError ?? Self.stillDirtyDescription)
        }
        concludeCleanClose()
        return .clean
    }

    private func concludeCleanClose() {
        isClosedClean = true
        debounceTask?.cancel()
        debounceTask = nil
        CanvasLog.event(.lifecycle, "session closed clean")
    }

    /// Total-ness, not a message anyone should see: a final pass that leaves
    /// the session dirty records why in `lastSaveError` on every path known.
    private static let stillDirtyDescription = "This document has unsaved changes."
}
