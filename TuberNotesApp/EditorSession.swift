import Foundation
import Observation

/// Coordinates the canvas runtime and the document store (`DataContract.md` §2).
///
/// It owns the active save policy — `dirty`, `saveInFlight`, the debounce. It
/// does not keep a second mutable drawing: the live drawing lives in PencilKit
/// and is captured only at save time. Page geometry is fixed and belongs to
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

    /// The page the canvas is currently showing. Page identity is the session's
    /// (`DataContract.md` §2); the canvas never learns it.
    var currentPageID: UUID { index.pageIDs[index.currentPageIndex] }

    /// The number of saved pages. One until P2 introduces navigation.
    var pageCount: Int { index.pageIDs.count }

    /// The one canvas runtime, created once and owned here so that SwiftUI
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
    var canvas: PageCanvasController {
        if let liveCanvas { return liveCanvas }
        let created = PageCanvasController()
        created.onDrawingChanged = { [weak self] in
            self?.drawingChanged()
        }
        liveCanvas = created
        return created
    }

    @ObservationIgnored private var liveCanvas: PageCanvasController?

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

    /// The live drawing differs from the last successful save.
    private var dirty = false
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
                let pageID = loaded.pageIDs[loaded.currentPageIndex]
                try canvas.installDrawing(from: await store.loadPage(pageID))
            } else {
                index = DocumentIndex.newDocument(documentID: UUID(), pageID: UUID())
                let snapshot = canvas.drawingSnapshot()
                let drawingData = await snapshot.serialized().data
                try await store.save(
                    index: index,
                    changedPages: [index.pageIDs[0]: drawingData]
                )
            }
            phase = .ready
            // Editing opens only now, after the loaded drawing is installed. The
            // canvas enforces the ordering; the session decides when it holds.
            canvas.markEditable()
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

    // MARK: - Autosave

    /// The one place a drawing change is judged to be user editing.
    ///
    /// The phase guard is the sole mechanism that keeps a load from dirtying the
    /// document: installing a loaded drawing fires this callback (synchronously,
    /// per `PageCanvasControllerTests`) while the phase is still `.loading`. It
    /// also covers `.failed`, where autosaving would overwrite a document that
    /// could not be read — which `DataContract.md` §6 forbids.
    private func drawingChanged() {
        guard phase == .ready else { return }
        markDirty()
    }

    private func markDirty() {
        dirty = true
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

        dirty = false
        saveInFlight = true

        // Capture drawing and metadata as one generation before either actor can
        // suspend, so a save never pairs one generation's identity with another's
        // ink.
        let snapshot = canvas.drawingSnapshot()
        let capturedIndex = index
        let capturedPageID = capturedIndex.pageIDs[capturedIndex.currentPageIndex]
        let serialized = await snapshot.serialized()
        // Measured where the work happens rather than timed again here: the next
        // debounce is derived from this cost (`DataContract.md` §5).
        lastSerializeDuration = serialized.duration

        do {
            // Only the page that was edited. The store rewrites the index only
            // if it changed, so an ordinary ink save touches exactly one file.
            try await store.save(
                index: capturedIndex,
                changedPages: [capturedPageID: serialized.data]
            )
            lastSaveError = nil
            consecutiveSaveFailures = 0
        } catch {
            dirty = true
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
