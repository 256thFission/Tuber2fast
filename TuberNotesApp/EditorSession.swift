import Foundation
import Observation

/// Coordinates the canvas runtime and the document store (`Contract.md` — Owners).
///
/// It owns page order and identity, and the active save policy.
//  Live drawings live in PencilKit and
/// are captured only at save time.
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

    private(set) var phase: Phase = .loading

    /// Surfaced so a failed autosave is visible 
    private(set) var lastSaveError: String?

    /// The page the user is looking at. Page belongs to the session's
    var currentPageID: UUID { index.pageIDs[index.currentPageIndex] }

    /// The number of saved pages.
    var pageCount: Int { index.pageIDs.count }

    /// The live canvas for the visible page, or `nil` before the runtime has
    /// laid out. The save path and the tests read it; nothing writes through it.
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

    /// Pages whose ink differs from the last successful save.
    ///
    /// A set of page IDs rather than one boolean, because a save must write the
    /// pages that changed and only those. Identity rather than index, because an
    /// index means a different page once the list changes.
    private var dirtyPageIDs: Set<UUID> = []

    /// Whether the index itself — page order or the current page — differs from
    /// what was last saved.
    private var indexDirty = false

    private var dirty: Bool { !dirtyPageIDs.isEmpty || indexDirty }

    /// Saved bytes for the pages currently in the runtime's window, plus any
    /// captured from a page that scrolled out before its save landed.
    ///
    /// This is not a second mutable drawing (`Contract.md` — Owners): a live
    /// page's authority is its `PKCanvasView`, and an entry here is either a
    /// copy of what is on disk or the final bytes of a page that no longer has
    /// a canvas. It is
    /// pruned to the window on every turn, so it cannot grow with pages visited.
    @ObservationIgnored private var pageData: [UUID: Data] = [:]

    /// Ink handed over by a page that left the live window before it was saved.
    ///
    /// Custody rather than a second copy (`Contract.md` — Owners, golden rule
    /// 5): every page in here has no live canvas, so this value is the only
    /// authority for it. Bounded by the dirty set — an entry is added only for
    /// a dirty page and dropped once that page is saved — which is the "any
    /// page whose ink is not yet saved" clause of the held-bytes bound.
    @ObservationIgnored private var retiredInk: [UUID: DrawingSnapshot] = [:]

    /// Pages whose bytes are being fetched. Prevents a scroll back and forth
    /// from starting the same load repeatedly.
    @ObservationIgnored private var pageLoadsInFlight: Set<UUID> = []
    /// One call to `DocumentStore.save` has started and has not returned or thrown.
    private var saveInFlight = false
    private var debounceTask: Task<Void, Never>?
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// `RootCanvasView.task` may be restarted as views move through the scene
    /// lifecycle. Exactly one load is allowed to cross the store boundary; later
    /// callers wait for that attempt instead of racing a second load over live ink.
    private var startInFlight = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

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
        guard phase == .loading else { return }
        if startInFlight {
            await withCheckedContinuation { startWaiters.append($0) }
            return
        }

        startInFlight = true
        defer {
            startInFlight = false
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        do {
            if let loaded = try await store.load() {
                index = loaded
                // The opening window, fetched before any canvas exists, so the
                // first pages are built with their ink rather than as blanks
                // that have to be reloaded.
                try await fetchPageData(forPagesAround: loaded.currentPageIndex)
            } else {
                index = DocumentIndex.newDocument(documentID: UUID(), pageID: UUID())
                // Empty bytes are the blank page. Serializing an empty
                // `PKDrawing` to get the same meaning would drag PencilKit into
                // this file, which `Contract.md` — Owners confines to the
                // canvas runtime.
                pageData[index.pageIDs[0]] = Data()
                try await store.save(index: index, changedPages: [index.pageIDs[0]: Data()])
            }
            phase = .ready
            pages.setPages(count: index.pageIDs.count, currentPageIndex: index.currentPageIndex)
            // Editing opens only now, after the loaded drawings are installed.
            // Each canvas enforces the ordering; the session decides when it
            // holds, and a page whose bytes have not arrived stays closed.
            pages.markEditable()
            CanvasLog.event(
                CanvasLog.lifecycle, "lifecycle",
                "session ready; pages=\(index.pageIDs.count) "
                    + "current=\(index.currentPageIndex)"
            )
        } catch {
            phase = .failed(String(describing: error))
            CanvasLog.event(CanvasLog.lifecycle, "lifecycle", "session failed to start: \(error)")
        }
    }

    // MARK: - Page content

    /// What the runtime should build a page with. `.unavailable` produces a page
    /// that is visible but not editable until `fetchPageData` supplies its bytes.
    private func content(forPageAt pageIndex: Int) -> PagedCanvasController.PageContent {
        guard index.pageIDs.indices.contains(pageIndex) else { return .blank }
        let pageID = index.pageIDs[pageIndex]
        // Ink this page handed over when it last retired outranks anything on
        // disk: it is newer by construction. Rebuilding from `pageData` instead
        // is what silently restored pre-edit ink when a page was turned away
        // from and back to before its save landed.
        if let snapshot = retiredInk[pageID] { return .retained(snapshot) }
        guard let data = pageData[pageID] else {
            let around = index.currentPageIndex
            Task { [weak self] in
                try? await self?.fetchPageData(forPagesAround: around)
            }
            return .unavailable
        }
        return data.isEmpty ? .blank : .ink(data)
    }

    /// Loads the saved bytes for the pages around `pageIndex` that are not
    /// already held, and rebuilds any page that was shown before its ink arrived.
    ///
    /// The radius is one wider than the runtime's live window, so an ordinary
    /// turn finds the next page's bytes already here.
    private func fetchPageData(forPagesAround pageIndex: Int) async throws {
        let lower = max(0, pageIndex - Self.prefetchRadius)
        let upper = min(index.pageIDs.count - 1, pageIndex + Self.prefetchRadius)
        guard lower <= upper else { return }

        for candidate in lower...upper {
            let pageID = index.pageIDs[candidate]
            guard pageData[pageID] == nil, !pageLoadsInFlight.contains(pageID) else { continue }

            pageLoadsInFlight.insert(pageID)
            defer { pageLoadsInFlight.remove(pageID) }

            let data = try await store.loadPage(pageID)
            // The page list can change while this is in flight; write the bytes
            // under the identity they were loaded for, never under an index.
            pageData[pageID] = data
            if let current = index.pageIDs.firstIndex(of: pageID) {
                liveRuntime?.reloadPage(at: current)
            }
        }
    }

    /// Drops held bytes for pages far from the visible one.
    ///
    /// Without this, `pageData` would grow with every page visited — the
    /// monotonic retention `Contract.md` — Performance forbids, wearing a
    /// different hat.
    /// A page with unsaved ink is never dropped.
    private func prunePageData() {
        let lower = max(0, index.currentPageIndex - Self.prefetchRadius)
        let upper = min(index.pageIDs.count - 1, index.currentPageIndex + Self.prefetchRadius)
        guard lower <= upper else { return }

        let keep = Set(index.pageIDs[lower...upper]).union(dirtyPageIDs)
        pageData = pageData.filter { keep.contains($0.key) }
    }

    /// One page either side of the runtime's live window.
    private static let prefetchRadius = 2

    // MARK: - Appending

    /// Adds a blank page at the end and turns to it.
    ///
    /// KNOWN DEFECT: the page is durable immediately here, rather than on first
    /// ink. Nothing drops a
    /// never-written trailing page at save time: this seeds empty `Data`,
    /// inserts it into the dirty set, and `DocumentStore.save` writes every
    /// entry in `changedPages` with no emptiness check. An accidental swipe
    /// past the end therefore grows the document permanently.
    ///
    /// This is a knowing divergence, and the contract is the side that is
    /// right. Appending eagerly was the smaller change and loses no ink.
    private func appendPage() {
        guard phase == .ready, !saveInFlight else { return }

        let appended = UUID()
        pageData[appended] = Data()
        index = index.withPages(index.pageIDs + [appended], currentPageIndex: index.pageIDs.count)
        dirtyPageIDs.insert(appended)
        indexDirty = true

        pages.setPages(count: index.pageIDs.count, currentPageIndex: index.currentPageIndex)
        CanvasLog.event(
            CanvasLog.canvas, "canvas",
            "appended page \(index.currentPageIndex); pages=\(index.pageIDs.count)"
        )
        markDirty()
    }

    // MARK: - Autosave

    /// The one place a drawing change is judged to be user editing.
    ///
    /// What keeps a load from dirtying the document is the wiring order in
    /// `PagedCanvasController.makePage`, not this guard: PencilKit reports a
    /// programmatic assignment synchronously, so the callback is attached only
    /// after the install and never sees it.
    ///
    /// The phase guard remains for `.failed`, where autosaving would overwrite a
    /// document that could not be read, and for `.loading`, where no page should
    /// be reporting anything yet.
    private func drawingChanged(atPageIndex pageIndex: Int) {
        guard phase == .ready, index.pageIDs.indices.contains(pageIndex) else { return }
        dirtyPageIDs.insert(index.pageIDs[pageIndex])
        markDirty()
    }

    /// Takes custody of a page's ink as its canvas is released.
    ///
    /// Synchronous, and that is the whole point (`Contract.md` — Saving: "a page
    /// leaving the live window hands over a value rather than starting a second
    /// capture"). Taking the value here leaves the save path as the only code
    /// that serializes, which is what makes the contract's claim that stale
    /// generations cannot exist true rather than aspirational.
    ///
    /// Handing over a promise instead — a `Task` that serialized and wrote the
    /// bytes back later — left a window in which the page had no canvas and no
    /// held ink. A save landing in that window found only the last bytes that
    /// reached disk, wrote those over the newer ink, and marked the page clean.
    private func pageIsRetiring(atPageIndex pageIndex: Int, snapshot: DrawingSnapshot) {
        guard phase == .ready, index.pageIDs.indices.contains(pageIndex) else { return }
        let pageID = index.pageIDs[pageIndex]
        guard dirtyPageIDs.contains(pageID) else { return }
        retiredInk[pageID] = snapshot
    }

    /// The visible page settled on a new index.
    private func currentPageChanged(to pageIndex: Int) {
        guard phase == .ready, index.pageIDs.indices.contains(pageIndex) else { return }
        guard pageIndex != index.currentPageIndex else { return }

        index = index.withPages(index.pageIDs, currentPageIndex: pageIndex)
        indexDirty = true
        prunePageData()
        Task { [weak self] in
            try? await self?.fetchPageData(forPagesAround: pageIndex)
        }
        markDirty()
    }

    private func markDirty() {
        // The debounce is not reset while a save is in flight; the post-save
        // re-check picks up anything that changed during it.
        guard !saveInFlight else { return }
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

    /// Flushes all currently dirty work. If another caller already owns a save,
    /// this caller waits for it rather than returning while durability is still
    /// unresolved.
    ///
    /// KNOWN DEFECT: on success this loops straight back into `performOneSave`
    /// with nothing in between, so a user-initiated Retry can serialize back to
    /// back. `Contract.md` — Saving requires a fresh debounce instead. Only the
    /// failure path arms a timer. `performAutosavePass` does the right thing —
    /// one pass, then re-arm — so the two paths in this file disagree.
    func saveIfNeeded() async {
        debounceTask?.cancel()
        debounceTask = nil

        while true {
            if saveInFlight {
                await waitForSavePass()
                continue
            }
            guard dirty else { return }
            await performOneSave()
            guard lastSaveError == nil else {
                // Deliberately not a loop: looping here would spin against a
                // failing disk, and the background-flush path used to come
                // through here. But returning with nothing armed would undo the
                // automatic retry — this method cancelled the debounce on the way
                // in, so a failed Retry tap would otherwise leave durability
                // waiting on the user again. Arming one timer is not spinning.
                scheduleSave(after: retryDelay)
                return
            }
        }
    }

    /// One debounced pass only. Edits made while that pass is running receive a
    /// fresh debounce instead of causing back-to-back whole-drawing
    /// serializations during continuous Pencil input.
    private func performAutosavePass() async {
        guard phase == .ready, dirty, !saveInFlight else { return }
        await performOneSave()
        guard dirty else { return }

        // A failed save must re-arm itself. Previously this re-armed only on
        // success, so a transient failure parked the editor dirty with no timer
        // running and recovery waited on the user drawing again, tapping Retry,
        // or a scene transition. The retry backs off so that a persistently
        // failing store is not hammered (`Contract.md` — Saving).
        scheduleSave(after: lastSaveError == nil ? nil : retryDelay)
    }

    private func performOneSave() async {
        guard dirty, !saveInFlight else { return }

        let capturedIndex = index
        let capturedPages = dirtyPageIDs
        dirtyPageIDs.removeAll()
        indexDirty = false
        saveInFlight = true

        // Capture every dirty page as one generation before either actor can
        // suspend, so a save never pairs one generation's identity with another's
        // ink. A page that is live and loaded is captured from its canvas; one
        // that has scrolled out yields the value it handed over as it retired.
        //
        // Capture is total (`Contract.md` — Saving). The dirty set was cleared
        // above, so a page this loop cannot account for would be reported clean
        // while its ink existed nowhere — the one failure that turns a save into
        // silent data loss. It traps instead.
        var snapshots: [UUID: DrawingSnapshot] = [:]
        var alreadySerialized: [UUID: Data] = [:]
        for pageID in capturedPages {
            if let pageIndex = capturedIndex.pageIDs.firstIndex(of: pageID),
               let snapshot = liveRuntime?.snapshot(at: pageIndex) {
                snapshots[pageID] = snapshot
            } else if let snapshot = retiredInk[pageID] {
                snapshots[pageID] = snapshot
            } else if let data = pageData[pageID] {
                alreadySerialized[pageID] = data
            } else {
                // KNOWN DEFECT: reachable today by drawing on a page that
                // entered the live window before its bytes arrived. Such a page
                // accepts Pencil input, is excluded from retirement, and holds
                // no bytes, so it arrives here dirty and empty-handed. The queue
                // item `unloaded-page-is-not-a-canvas` closes it by refusing the
                // input rather than accepting and then failing to account for
                // it. Trapping is the contract-correct behaviour meanwhile:
                // the alternative is dropping the page silently, which is what
                // this code did before.
                preconditionFailure(
                    "dirty page \(pageID) yielded no ink to capture: "
                        + "no live canvas, no retired ink, no held bytes"
                )
            }
        }

        var changedPages = alreadySerialized
        var totalDuration: Duration = .zero
        for (pageID, snapshot) in snapshots {
            let serialized = await snapshot.serialized()
            changedPages[pageID] = serialized.data
            totalDuration += serialized.duration
        }
        // Measured where the work happens rather than timed again here: the next
        // debounce is derived from this cost (`Contract.md` — Saving).
        lastSerializeDuration = totalDuration

        do {
            // Only the pages that were edited. The store rewrites the index only
            // if it changed, so an ordinary ink save touches exactly one file.
            try await store.save(index: capturedIndex, changedPages: changedPages)
            for (pageID, data) in changedPages {
                pageData[pageID] = data
                // Custody ends when the ink is durable — but only if the page
                // has not been dirtied again since this save captured it. A
                // page redrawn and retired during an in-flight save holds its
                // newer ink here and nowhere else.
                if !dirtyPageIDs.contains(pageID) { retiredInk[pageID] = nil }
            }
            lastSaveError = nil
            consecutiveSaveFailures = 0
        } catch {
            dirtyPageIDs.formUnion(capturedPages)
            indexDirty = true
            lastSaveError = String(describing: error)
            consecutiveSaveFailures += 1
        }

        saveInFlight = false
        let waiters = saveWaiters
        saveWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForSavePass() async {
        guard saveInFlight else { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }

    // MARK: - Lifecycle

    /// Cancels the debounce and makes a best-effort save with whatever execution
    /// time iPadOS provides. Only a returned save is acknowledged; if time
    /// expires the editor stays dirty and retries after foregrounding.
    ///
    /// One pass, deliberately, not `saveIfNeeded`'s loop. The lease is bounded,
    /// so unbounded work cannot finish on it anyway, and every extra iteration is
    /// another chance to be killed mid-write for ink that was already captured by
    /// the pass before it. If the session is still dirty when this returns it
    /// stays dirty — `resumeForForeground` retries, which is exactly what
    /// `Contract.md` — Lifecycle promises ("no promised flush duration").
    func flushForBackground() async {
        debounceTask?.cancel()
        debounceTask = nil

        // An in-flight save already owns a captured generation; waiting for it
        // is what makes the following pass the *second* and last one.
        await waitForSavePass()
        await performOneSave()
    }

    /// Retries a save left unacknowledged by backgrounding. It never overlays a
    /// loaded drawing onto newer live ink — nothing is loaded here.
    func resumeForForeground() {
        guard phase == .ready, dirty, !saveInFlight else { return }
        scheduleSave()
    }
}
