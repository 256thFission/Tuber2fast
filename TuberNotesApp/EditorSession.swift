import Foundation
import Observation

/// Coordinates the canvas runtime and the document store (`DataContract.md` §2).
///
/// It owns the active save policy — `dirty`, `saveInFlight`, the debounce — and
/// the current page height. It does not keep a second mutable drawing: the live
/// drawing lives in PencilKit and is captured only at save time.
///
/// `@Observable` is deliberate and narrow. SwiftUI observes `phase`, `pageHeight`,
/// and `canExtend` — user-action-frequency values. It never observes the drawing,
/// pan, zoom, or Pencil samples, which is what §9 and §10 forbid.
@MainActor
@Observable
final class EditorSession {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var pageHeight: Double = PageGeometry.initialHeight

    /// Surfaced so a failed autosave is visible rather than silent. It is not
    /// durable state and is not a product concept.
    private(set) var lastSaveError: String?

    var canExtend: Bool { PageGeometry.extended(from: pageHeight) != nil }

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

    private var documentID = UUID()
    private var pageID = UUID()

    /// The live drawing differs from the last successful save.
    private var dirty = false
    /// One call to `DocumentStore.save` has started and has not returned or thrown.
    private var saveInFlight = false
    private var debounceTask: Task<Void, Never>?
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []

    /// `RootCanvasView.task` may be restarted as views move through the scene
    /// lifecycle. Exactly one load is allowed to cross the store boundary; later
    /// callers wait for that attempt instead of racing a second load over live ink.
    private var startInFlight = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// `debounce` is injectable only so tests need not wait 500 ms of real time.
    /// The contract's interval is the default and the only one the app uses.
    /// Builds no UIKit object. See `canvas` for why that matters.
    init(store: DocumentStore, debounce: Duration = .milliseconds(500)) {
        self.store = store
        self.debounce = debounce
    }

    // MARK: - Launch

    /// Loads once, before the canvas becomes editable (`DataContract.md` §6).
    ///
    /// No file means first launch: generate the IDs, take the initial geometry,
    /// and save an empty document. Invalid data fails loudly and leaves the
    /// source file untouched — it is never replaced with a blank drawing.
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
            if let file = try await store.load() {
                documentID = file.documentID
                pageID = file.pageID
                pageHeight = file.pageHeight
                canvas.setPageHeight(file.pageHeight)
                try canvas.installDrawing(from: file.drawingData)
            } else {
                documentID = UUID()
                pageID = UUID()
                pageHeight = PageGeometry.initialHeight
                canvas.setPageHeight(pageHeight)
                let snapshot = canvas.drawingSnapshot()
                let drawingData = await snapshot.serialized()
                try await store.save(
                    currentFile(
                        drawingData: drawingData,
                        documentID: documentID,
                        pageID: pageID,
                        pageHeight: pageHeight
                    )
                )
            }
            phase = .ready
            CanvasLog.event(
                CanvasLog.lifecycle, "lifecycle",
                "session ready; pageHeight=\(pageHeight)"
            )
        } catch {
            phase = .failed(String(describing: error))
            CanvasLog.event(CanvasLog.lifecycle, "lifecycle", "session failed to start: \(error)")
        }
    }

    // MARK: - Page extension

    /// Raises the page by one increment and enters the ordinary autosave path.
    ///
    /// An extension at the maximum height is refused and changes nothing. This
    /// is a user intention, never a consequence of where ink landed — a bounds
    /// test on the Pencil path is forbidden (`DataContract.md` §5a).
    ///
    /// It is not undoable, and PencilKit's undo manager never learns about it.
    /// Because the page only grows, an extension loses no ink, so the absence of
    /// undo cannot lose work.
    func extendPage() {
        guard phase == .ready, let next = PageGeometry.extended(from: pageHeight) else { return }
        pageHeight = next
        canvas.setPageHeight(next)
        markDirty()
    }

    // MARK: - Autosave

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

    private func scheduleSave() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.performAutosavePass()
        }
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
            guard lastSaveError == nil else { return }
        }
    }

    /// One debounced pass only. Edits made while that pass is running receive a
    /// fresh debounce instead of causing back-to-back whole-drawing
    /// serializations during continuous Pencil input.
    private func performAutosavePass() async {
        guard phase == .ready, dirty, !saveInFlight else { return }
        await performOneSave()
        if dirty, lastSaveError == nil {
            scheduleSave()
        }
    }

    private func performOneSave() async {
        guard dirty, !saveInFlight else { return }

        dirty = false
        saveInFlight = true

        // Capture drawing and metadata as one generation before either actor can
        // suspend. A page extension during serialization marks the next
        // generation dirty instead of pairing new geometry with old ink.
        let snapshot = canvas.drawingSnapshot()
        let capturedDocumentID = documentID
        let capturedPageID = pageID
        let capturedPageHeight = pageHeight
        let drawingData = await snapshot.serialized()
        let file = currentFile(
            drawingData: drawingData,
            documentID: capturedDocumentID,
            pageID: capturedPageID,
            pageHeight: capturedPageHeight
        )

        do {
            try await store.save(file)
            lastSaveError = nil
        } catch {
            dirty = true
            lastSaveError = String(describing: error)
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
    func flushForBackground() async {
        debounceTask?.cancel()
        debounceTask = nil
        await saveIfNeeded()
    }

    /// Retries a save left unacknowledged by backgrounding. It never overlays a
    /// loaded drawing onto newer live ink — nothing is loaded here.
    func resumeForForeground() {
        guard phase == .ready, dirty, !saveInFlight else { return }
        scheduleSave()
    }

    private func currentFile(
        drawingData: Data,
        documentID: UUID,
        pageID: UUID,
        pageHeight: Double
    ) -> CanvasFile {
        CanvasFile(
            formatVersion: CanvasFile.currentFormatVersion,
            documentID: documentID,
            pageID: pageID,
            pageWidth: PageGeometry.width,
            pageHeight: pageHeight,
            drawingData: drawingData
        )
    }
}
