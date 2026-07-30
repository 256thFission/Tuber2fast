import Foundation
import Observation

/// Coordinates the canvas runtime and the document store (`DataContract.md` §2).
///
/// It owns page order and identity, and the active save policy — which pages
/// are dirty, `saveInFlight`, the debounce. Live drawings live in PencilKit and
/// are captured only at save time. Page geometry is fixed and belongs to
/// `PageGeometry`, so there is no durable geometry state to own here.
///
/// `@Observable` is deliberate and narrow. SwiftUI observes `phase` and
/// `lastSaveError` — user-action-frequency values. It never observes the
/// drawing, pan, zoom, or Pencil samples, which is what §9 and §10 forbid.
@MainActor
@Observable
final class EditorSession {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading

    /// Surfaced so a failed autosave is visible rather than silent. It is not
    /// durable state and is not a product concept.
    private(set) var lastSaveError: String?

    /// The page the user is looking at. Page identity is the session's
    /// (`DataContract.md` §2 rule 7a); no canvas ever learns it.
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
    /// identity and order (`DataContract.md` §2); the canvas never sees it.
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
    /// This is not a second mutable drawing (§2 rule 5): a live page's authority
    /// is its `PKCanvasView`, and an entry here is either a copy of what is on
    /// disk or the final bytes of a page that no longer has a canvas. It is
    /// pruned to the window on every turn, so it cannot grow with pages visited.
    @ObservationIgnored private var pageData: [UUID: Data] = [:]

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
    /// the app (`DataContract.md` §5, retry policy).
    private var consecutiveSaveFailures = 0

    /// How long the last whole-drawing serialization took. The debounce is
    /// derived from it so that a document large enough to be expensive to
    /// serialize does not chain back-to-back serializations (`DataContract.md`
    /// §5). Zero until the first save, which is the same as no back-off.
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

    /// Failure doublings past this point are pointless — at the contract's
    /// 500 ms interval the fourth doubling already exceeds `maximumRetryDelay` —
    /// and an unbounded shift would overflow.
    private static let maximumFailureDoublings = 10

    /// `RootCanvasView.task` may be restarted as views move through the scene
    /// lifecycle. Exactly one load is allowed to cross the store boundary; later
    /// callers wait for that attempt instead of racing a second load over live ink.
    private var startInFlight = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// `debounce` is injectable only so tests need not wait 500 ms of real time.
    /// The contract's interval is the default and the only one the app uses. It
    /// is a hard floor and never a ceiling: the adaptive debounce may widen it
    /// for a document that is expensive to serialize, and can never shorten it
    /// (`DataContract.md` §5).
    /// Builds no UIKit object. See `canvas` for why that matters.
    init(store: DocumentStore, debounce: Duration = .milliseconds(500)) {
        self.store = store
        self.debounce = debounce
    }

    // MARK: - Launch

    /// Loads once, before the canvas becomes editable (`DataContract.md` §6).
    ///
    /// No document means first launch: generate the IDs and save an empty
    /// one-page document. A format version 1 file is migrated by the store, and
    /// arrives here indistinguishable from a version 2 document. Invalid data
    /// fails loudly and leaves what is on disk untouched — it is never replaced
    /// with a blank drawing.
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
                // this file, which §3 confines to the canvas runtime.
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
    /// monotonic retention `DataContract.md` §9 forbids, wearing a different hat.
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
    /// The page is durable immediately here, rather than on first ink as
    /// `PagesAndTurning.md` §8 describes. That refinement is P3's; appending
    /// eagerly is the smaller change and loses nothing, because an empty page
    /// costs one small file.
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
    /// The phase guard is the sole mechanism that keeps a load from dirtying the
    /// document: installing a loaded drawing fires this callback (synchronously,
    /// per `PageCanvasControllerTests`) while the phase is still `.loading`. It
    /// also covers `.failed`, where autosaving would overwrite a document that
    /// could not be read — which `DataContract.md` §6 forbids.
    private func drawingChanged(atPageIndex pageIndex: Int) {
        guard phase == .ready, index.pageIDs.indices.contains(pageIndex) else { return }
        dirtyPageIDs.insert(index.pageIDs[pageIndex])
        markDirty()
    }

    /// Takes custody of a page's ink as its canvas is released.
    ///
    /// Serialization is asynchronous, so the bytes land in `pageData` after the
    /// canvas is gone. That is safe because the page is out of the window and
    /// cannot be drawn on; if the user turns back before this lands, the page is
    /// simply rebuilt from whatever `pageData` then holds.
    private func pageIsRetiring(atPageIndex pageIndex: Int, snapshot: DrawingSnapshot) {
        guard phase == .ready, index.pageIDs.indices.contains(pageIndex) else { return }
        let pageID = index.pageIDs[pageIndex]
        guard dirtyPageIDs.contains(pageID) else { return }

        Task { [weak self] in
            let data = await snapshot.serialized().data
            self?.pageData[pageID] = data
        }
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

    /// The debounce actually used: the contract interval, widened when the last
    /// serialization was expensive (`DataContract.md` §5).
    ///
    /// A fixed interval was correct while the page was one screen tall. It is
    /// not once the page can grow to many times that height, because every save
    /// serializes the whole drawing: at 200 ms per serialization a 500 ms
    /// debounce spends most of its time encoding. Small documents measure near
    /// zero and stay at exactly the floor, so their behavior is unchanged.
    private var adaptiveDebounce: Duration {
        max(debounce, lastSerializeDuration * Self.serializeBackoffFactor)
    }

    /// Exponential back-off for a retry after a failed save: the first retry
    /// waits the ordinary debounce interval and each further consecutive failure
    /// doubles it, capped (`DataContract.md` §5).
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
        // failing store is not hammered (`DataContract.md` §5).
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
        // that has scrolled out was captured as it retired.
        var snapshots: [UUID: DrawingSnapshot] = [:]
        var alreadySerialized: [UUID: Data] = [:]
        for pageID in capturedPages {
            if let pageIndex = capturedIndex.pageIDs.firstIndex(of: pageID),
               let snapshot = liveRuntime?.snapshot(at: pageIndex) {
                snapshots[pageID] = snapshot
            } else if let data = pageData[pageID] {
                alreadySerialized[pageID] = data
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
        // debounce is derived from this cost (`DataContract.md` §5).
        lastSerializeDuration = totalDuration

        do {
            // Only the pages that were edited. The store rewrites the index only
            // if it changed, so an ordinary ink save touches exactly one file.
            try await store.save(index: capturedIndex, changedPages: changedPages)
            for (pageID, data) in changedPages {
                pageData[pageID] = data
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
    /// `DataContract.md` §6 promises ("no promised flush duration").
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
