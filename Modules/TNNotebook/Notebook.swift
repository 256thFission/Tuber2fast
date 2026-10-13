import Foundation
import Observation
import PencilKit
import TNCore
import TNFormat
import TNModel
import TNRender

/// The notebook: custody of every page's newest ink, the page order, and
/// the save engine. `@MainActor`; the store is an actor behind a seam.
///
/// Observed properties are stored mirrors. Everything heavy is ignored by
/// observation, so a stroke never invalidates a view.
@MainActor @Observable
package final class Notebook {
    // MARK: Observed mirrors

    package private(set) var pageCount: Int = 0
    package internal(set) var currentPageID: PageID
    package internal(set) var dirtyPageCount: Int = 0
    package internal(set) var lastSaveError: SaveFailure?
    package internal(set) var isClosed = false

    // MARK: Custody

    @ObservationIgnored package let store: any PackageStoring
    @ObservationIgnored package let renderer: Renderer
    @ObservationIgnored package let notebookID: NotebookID
    /// The scale composites are first rendered at: a 2x display at fit width.
    package static let baseCompositeScale: CGFloat = 2
    @ObservationIgnored package internal(set) var index: NotebookIndex
    @ObservationIgnored var indexSeq: UInt64 = 0
    @ObservationIgnored var savedIndexSeq: UInt64 = 0
    @ObservationIgnored var states: [PageID: PageState] = [:]
    @ObservationIgnored var wanted: Set<PageID> = []
    /// Readable, like the save engine's two tasks, so a test can await a
    /// load and see where it landed without a member that exists only for it.
    @ObservationIgnored var loads: [PageID: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextGeneration: UInt64 = 1
    @ObservationIgnored private var nextStructureSeq: UInt64 = 1
    @ObservationIgnored private var nextInkSeq: UInt64 = 1
    @ObservationIgnored var changes: [NotebookChange] = []
    @ObservationIgnored var history = EditHistory()
    /// An undo or redo whose page was not loaded: applied when the page
    /// arrives. One slot: the last stash is the revision the page will have.
    @ObservationIgnored var pendingRestores: [PageID: PageRevision] = [:]
    /// Bumped by every change that alters what a page looks like: ink,
    /// layers, paper. Never reset by unload, because content is only dropped
    /// when clean (`prune()`), so the version on reload still describes the
    /// page. Every layer edit bumps in one place, `commitLayerEdit`. Ink, a
    /// restore, paper and an inserted page each bump for themselves, so
    /// those sites are enumerated and `NotebookCustodyTests` is the enforcement.
    @ObservationIgnored var contentVersions: [PageID: UInt64] = [:]

    // MARK: Save engine

    @ObservationIgnored package let schedule: SaveSchedule
    @ObservationIgnored var debounce: Task<Void, Never>?
    @ObservationIgnored var currentSave: Task<Void, Never>?
    @ObservationIgnored var lastSerialize: Duration
    @ObservationIgnored var firstDirtyAt: ContinuousClock.Instant?
    @ObservationIgnored var backoff: Duration?
    @ObservationIgnored var retryBuffer: [PageID: (seq: UInt64, bytes: Data)] = [:]
    @ObservationIgnored var viewWrite: Task<Void, Never>?

    private init(store: any PackageStoring, loaded: LoadedNotebook, view: ViewState?, schedule: SaveSchedule) {
        self.store = store
        self.renderer = Renderer(assets: store)
        self.schedule = schedule
        self.lastSerialize = schedule.firstSerializeEstimate
        self.index = loaded.index
        self.notebookID = loaded.index.notebookID
        let first = loaded.index.pageIDs[0]
        if let view, loaded.index.record(of: view.currentPageID) != nil {
            self.currentPageID = view.currentPageID
        } else {
            self.currentPageID = first
        }
        for page in loaded.index.pageIDs {
            if let faults = loaded.pageFaults[page] {
                states[page] = .unreadable(faults)
            } else {
                states[page] = .unloaded
            }
        }
        pageCount = loaded.index.pages.count
    }

    /// Opens a package. The index and `view.json` are read; no page is.
    package static func open(store: any PackageStoring, schedule: SaveSchedule = SaveSchedule()) async throws(FormatFault) -> Notebook {
        let loaded = try await store.load()
        let view = await store.readView()
        let notebook = Notebook(store: store, loaded: loaded, view: view, schedule: schedule)
        notebook.emitStructure(answering: nil)
        return notebook
    }

    // MARK: Reading state

    package func state(of page: PageID) -> PageState? { states[page] }

    package var pageIDs: [PageID] { index.pageIDs }

    package var descriptors: [PageDescriptor] {
        index.pages.map { PageDescriptor(id: $0.id, geometry: $0.geometry) }
    }

    package var isDirty: Bool { dirtyPageCount > 0 || indexSeq > savedIndexSeq }

    package var dirtyPages: [PageID] {
        index.pageIDs.filter { states[$0]?.isDirty == true }
    }

    /// The changes since the last drain, in order. The binding calls this
    /// after every intention it forwards.
    package func drainChanges() -> [NotebookChange] {
        defer { changes.removeAll() }
        return changes
    }

    // MARK: The window

    /// The complete decoded window. Pages entering it load, or are pushed if
    /// the notebook holds them already; loads for pages leaving it are
    /// cancelled and their results dropped on arrival.
    ///
    /// A page held ready is pushed with a composite, rendered here if it has
    /// none: an import's pages wait for this, so the only composites a long
    /// PDF holds are the window's. A refused page is pushed too, so its
    /// placeholder says why instead of "Loading…".
    package func windowChanged(to pages: [PageID]) {
        let newWanted = Set(pages)
        for page in wanted.subtracting(newWanted) {
            loads[page]?.cancel()
            loads[page] = nil
            if case .loading = states[page] { states[page] = .unloaded }
        }
        let entering = newWanted.subtracting(wanted)
        wanted = newWanted
        for page in pages {
            switch states[page] {
            case .unloaded:
                startLoad(page)
            case .ready(let content) where entering.contains(page):
                withContent(page) { $0.retired = false }
                emitContent(page)
                if content.composite == nil { rerenderComposite(of: page) }
            case .unreadable where entering.contains(page):
                emitContent(page)
            default:
                break
            }
        }
    }

    private func startLoad(_ page: PageID) {
        let generation = nextGeneration
        nextGeneration += 1
        states[page] = .loading(generation: generation)
        let store = self.store
        let record = index.record(of: page)
        loads[page] = Task { [weak self] in
            let bytes: PageBytes
            do {
                bytes = try await store.loadPage(page)
            } catch {
                self?.installLoaded(page, generation: generation, result: .faults([.pageFileUnreadable("\(error)")]))
                return
            }
            if Task.isCancelled { return }
            switch await Self.decode(bytes) {
            case .ready(var content):
                if Task.isCancelled { return }
                if let record, let renderer = self?.renderer {
                    content.composite = await renderer.composite(geometry: record.geometry, paper: record.paper, layers: bytes.layers, scale: Notebook.baseCompositeScale)
                }
                self?.installLoaded(page, generation: generation, result: .ready(content))
            case .faults(let faults):
                self?.installLoaded(page, generation: generation, result: .faults(faults))
            }
        }
    }

    package enum LoadOutcome: Sendable {
        case ready(PageContent)
        case faults([PageFault])
    }

    /// Bytes to content, or to the faults that refuse them. The one judgment
    /// for a load, a thumbnail of an unloaded page, and the library's cover of
    /// a closed notebook, so a corrupt page reaches the same verdict on every
    /// path. Runs in the caller's task, on the generic executor: a load's
    /// decode is cancelled with its window.
    package nonisolated static func decode(_ bytes: PageBytes) async -> LoadOutcome {
        var faults = bytes.faults
        var ink: PKDrawing?
        if let archive = bytes.inkArchive {
            do { ink = try PKDrawing(data: archive) } catch { faults.append(.inkArchiveUndecodable("\(error)")) }
        }
        guard faults.isEmpty else { return .faults(faults) }
        var content = PageContent(
            ink: ink ?? PKDrawing(),
            layers: bytes.layers,
            hasInk: bytes.file.hasInk || bytes.inkRecordNeeded
        )
        // An adopted container is recorded by the next save.
        if bytes.inkRecordNeeded { content.edited() }
        return .ready(content)
    }

    private func installLoaded(_ page: PageID, generation: UInt64, result: LoadOutcome) {
        guard !isClosed, case .loading(let current) = states[page], current == generation else { return }
        loads[page] = nil
        guard wanted.contains(page) else {
            TNLog.event(.notebook, "dropped a stale load for page \(page)")
            states[page] = .unloaded
            return
        }
        switch result {
        case .ready(var content):
            // Folded in here rather than through `apply`, so the snapshot
            // `emitContent` builds carries the restored ink and layers under
            // its one echo sequence. A second push would be a second
            // sequence, and the canvas would report the first as an edit.
            let restored = pendingRestores.removeValue(forKey: page).map { content.adopt($0) }
            states[page] = .ready(content)
            if content.isDirty { markDirty() }
            emitContent(page)
            // The composite the load built came from the layers on disk.
            if restored?.layers == true { rerenderComposite(of: page) }
        case .faults(let faults):
            states[page] = .unreadable(faults)
            pendingRestores[page] = nil
            history.forget(page)
            emitContent(page)
        }
        onAsyncChange?()
    }

    func emitContent(_ page: PageID) {
        guard let state = states[page] else { return }
        let snapshot: PageSnapshot
        switch state {
        case .ready(let content):
            let seq = InkSeq(nextInkSeq); nextInkSeq += 1
            withContent(page) { $0.pendingEcho = seq }
            snapshot = .editable(id: page, ink: content.ink, layers: content.layers, composite: content.composite, inkSeq: seq)
        case .unreadable(let faults):
            snapshot = .placeholder(id: page, faults: faults)
        case .unloaded, .loading:
            return
        }
        changes.append(.content(snapshot))
    }

    func emitStructure(answering: ReportSeq?) {
        let seq = StructureSeq(nextStructureSeq); nextStructureSeq += 1
        changes.append(.structure(descriptors, seq: seq, answering: answering))
        pageCount = index.pages.count
    }

    func withContent(_ page: PageID, _ mutate: (inout PageContent) -> Void) {
        guard case .ready(var content) = states[page] else { return }
        mutate(&content)
        states[page] = .ready(content)
    }

    // MARK: Ink custody

    /// A report from the runtime. The value travels; custody is now here.
    ///
    /// `bindings` are the person's gesture preferences for the stroke in
    /// hand, asked for on every report; the notebook holds no copy, because
    /// a preference is never notebook state. A gesture applies inside this
    /// call, so the one entry recorded below runs from the revision before
    /// the trigger stroke to the revision after its effect.
    package func inkChanged(on page: PageID, _ ink: PKDrawing, bindings: GestureBindings = [:]) {
        guard case .ready(var content) = states[page] else {
            TNPrecondition.fail("ink reported for page \(page) which is not ready: \(String(describing: states[page]))")
        }
        content.pendingEcho = nil
        // A report of the ink already held is no edit, an echo included: the
        // page stays clean and its ink file is not rewritten. Equality is the
        // check, not the stamp, because a stamped report can carry different
        // ink: on the device PencilKit's commit after
        // `canvasViewDidEndUsingTool` can land on top of an undo's restore,
        // and that stroke must come back into custody.
        if ink == content.ink {
            states[page] = .ready(content)
            return
        }
        let captured = content.revision
        let gesture = gesture(on: page, in: ink, after: captured, bindings: bindings)
        if let gesture {
            // The same shape undo pushes: the edited drawing rides
            // `.inkRestored`, and its echo is the ink already held.
            restore(gesture, on: page, in: &content)
        }
        content.setInk(gesture ?? ink)
        // A gesture's drawing this app built, so the entry pays per stroke;
        // every other report came from the canvas and shares.
        recordEdit(on: page, from: captured, to: content.revision, rebuilt: gesture != nil)
        states[page] = .ready(content)
        bumpContentVersion(of: page)
        markDirty()
    }

    /// The drawing a gesture leaves behind, if a gesture fired. Nil when
    /// nothing applies, which is the common case and the cheap one.
    ///
    /// "Exactly one stroke more than the captured revision" is the whole
    /// test for "a pen stroke landed". The eraser and the lasso add nothing,
    /// and the pixel eraser masks rather than splits, so it adds nothing
    /// either. Recognition itself lives in `StrokeGestures.swift`; what is
    /// here is the page, the log, and the edit.
    private func gesture(on page: PageID, in ink: PKDrawing, after captured: PageRevision, bindings: GestureBindings) -> PKDrawing? {
        guard !bindings.isEmpty else { return nil }
        // The one read of the strokes array; the getter bridges, and both
        // readings and the edit walk this copy.
        let strokes = ink.strokes
        guard strokes.count == captured.ink.strokes.count + 1 else { return nil }
        let added = strokes.count - 1
        let match = GestureTrigger.recognise(stroke: added, in: strokes, bindings: bindings) { line in
            TNLog.event(.gesture, "page=\(page) " + line)
        }
        guard let match else { return nil }
        return match.effect.apply(to: ink, strokes: strokes, subject: match.subject, added: added)
    }

    /// A drawing the notebook chose, pushed to the canvas: one sequence,
    /// latched so its echo comes back as nothing. Undo and a gesture are the
    /// two edits that take this path.
    private func restore(_ ink: PKDrawing, on page: PageID, in content: inout PageContent) {
        let seq = InkSeq(nextInkSeq); nextInkSeq += 1
        content.pendingEcho = seq
        changes.append(.inkRestored(page, ink, seq: seq))
    }

    // MARK: Content versions

    /// The version a thumbnail of `page` is keyed by. 0 for a page never
    /// changed in this session.
    package func contentVersion(of page: PageID) -> UInt64 { contentVersions[page] ?? 0 }

    func bumpContentVersion(of page: PageID) {
        contentVersions[page, default: 0] += 1
    }

    #if DEBUG
    /// The estimated bytes the undo stack holds, which is what its byte
    /// bound is measured against. The tests read it; nothing else does, so
    /// it does not exist in Release.
    package var historyByteEstimateForTesting: Int { history.byteEstimate }
    #endif

    package var canUndo: Bool { history.canUndo }
    package var canRedo: Bool { history.canRedo }

    /// Every asset this notebook can still bring back, which compact keeps
    /// (`Docs/Contract.md`, One save): what the history names, a restore
    /// parked for an unloaded page, a ready page's layers, and the held
    /// index's paper.
    package var assetsInUse: Set<AssetRef> {
        let layers = pendingRestores.values.flatMap(\.layers) + states.values.compactMap(\.content).flatMap(\.layers)
        return history.assets
            .union(layers.compactMap(\.payload.asset))
            .union(index.pages.compactMap(\.paperAsset))
    }

    /// Whether any page has a text session open. The binding routes undo by
    /// it, whichever page the session is on.
    package var hasTextSession: Bool {
        states.values.contains { $0.content?.textEditing != nil }
    }

    /// Every edit records through here, and only when the revision moved:
    /// an entry that restores nothing would still clear redo on the way in.
    /// `rebuilt` says the new revision's drawing was built here rather than
    /// handed over by the canvas, which is what its byte estimate turns on.
    /// Only the gesture path builds one; see `HistoryEntry`.
    func recordEdit(
        on page: PageID,
        from captured: PageRevision,
        to revision: PageRevision,
        rebuilt: Bool
    ) {
        guard revision != captured else { return }
        history.record(HistoryEntry(page: page, before: captured, after: revision, rebuilt: rebuilt))
    }

    /// One notebook-wide stack, GoodNotes-shaped: an undo restores the page
    /// it happened on, whichever page is current, and the binding scrolls
    /// there. Returns that page, or nil when there is nothing to undo.
    @discardableResult
    package func undo() -> PageID? {
        guard let entry = history.undo() else { return nil }
        apply(entry.before, to: entry.page)
        return entry.page
    }

    @discardableResult
    package func redo() -> PageID? {
        guard let entry = history.redo() else { return nil }
        apply(entry.after, to: entry.page)
        return entry.page
    }

    /// Moves a page to a revision, touching only what differs. Paper is not
    /// in a revision, so the index is never touched and no structure change
    /// is emitted.
    private func apply(_ revision: PageRevision, to page: PageID) {
        switch states[page] {
        case .ready(var content):
            // A restore rewrites the layer list and can remove the layer a
            // session is open on, after which `endTextEditing` traps on a
            // layer the page no longer holds.
            TNPrecondition.require(content.textEditing == nil, "a restore on page \(page) under an open text session on layer \(String(describing: content.textEditing?.layer))")
            let delta = content.adopt(revision)
            guard delta.ink || delta.layers else { return }
            if delta.ink { restore(revision.ink, on: page, in: &content) }
            states[page] = .ready(content)
            bumpContentVersion(of: page)
            markDirty()
            if delta.layers { rerenderComposite(of: page) }
        case .unloaded, .loading:
            // The page left the window; bring it back and apply on arrival.
            // The stash is a promise that the page will differ when it loads,
            // so it bumps the version now: a thumbnail taken of the unloaded
            // page reads the stash and is keyed by the revision it will have.
            pendingRestores[page] = revision
            wanted.insert(page)
            bumpContentVersion(of: page)
            if case .unloaded = states[page] { startLoad(page) }
        case .unreadable:
            // A page can become unreadable at a load the entry predates. The
            // refusal forgot what was on the stacks; the entry in hand goes
            // the same way, softly, because this is timing and not a broken
            // invariant.
            TNLog.event(.notebook, "a restore reached page \(page), which is unreadable; its history is dropped")
            history.forget(page)
        case nil:
            // `deletePage` forgets the page's entries, and nothing else
            // removes a page from `states`.
            TNPrecondition.fail("a restore reached page \(page), which the notebook does not hold")
        }
    }

    /// The runtime's final report for a retired canvas. `finalInk` nil means
    /// the canvas was a placeholder and held nothing.
    package func retired(_ page: PageID, finalInk: PKDrawing?) {
        switch states[page] {
        case nil:
            return  // a deleted page: its ink went with it (deletePage)
        case .ready(let content):
            if let finalInk, content.ink != finalInk { inkChanged(on: page, finalInk) }
            withContent(page) { $0.retired = true }
        case .unloaded, .loading, .unreadable:
            TNPrecondition.require(finalInk == nil, "page \(page) retired with ink the notebook does not hold: \(String(describing: states[page]))")
        }
    }

    /// Drops content for pages the runtime has retired, that are outside the
    /// window, and that are clean, and tells the runtime, which forgets its
    /// snapshot. History does not go with it: the stack is notebook-wide,
    /// and an undo into a pruned page loads it back and restores on arrival.
    package func prune() {
        for (page, state) in states {
            guard case .ready(let content) = state, content.retired, !wanted.contains(page), !content.isDirty else { continue }
            states[page] = .unloaded
            changes.append(.unloaded(page))
        }
    }

    // MARK: Thumbnails

    /// A page rendered small, keyed by its content version. A ready page
    /// renders from custody. An unloaded page renders from its files, decoded
    /// in the caller's task and installed nowhere: the state stays
    /// `.unloaded` and nothing is marked dirty. A pending restore is
    /// preferred over the ink on disk, because it is the ink the page will
    /// have. A loading page answers nil at once rather than waiting; the
    /// caller asks again when the load settles. An unreadable page is nil.
    package func thumbnail(of page: PageID) async -> CGImage? {
        guard let record = index.record(of: page) else { return nil }
        let key = ThumbnailKey(page: page, version: contentVersion(of: page))
        if let cached = await renderer.cachedThumbnail(key) { return cached }
        if case .loading = states[page] { return nil }
        guard let revision = await revision(of: page) else { return nil }
        return await renderer.thumbnail(key, geometry: record.geometry, paper: record.paper, layers: revision.layers, ink: revision.ink)
    }

    /// What a page holds right now, whether or not it is loaded, for a render
    /// that must not disturb it. A ready page answers from custody, unsaved
    /// ink included. An unloaded or loading page is read from its files and
    /// decoded in the caller's task, so a cancelled render stops mid-decode;
    /// nothing is installed, nothing is marked dirty, and the state does not
    /// move. A pending restore is preferred over the ink on disk, because it
    /// is the ink the page will have. A page with no record, one the notebook
    /// refused, or one whose files do not decode, is nil: a page refused for
    /// its paper asset has page files that decode, and drawn from them it
    /// would be ink on blank paper.
    ///
    /// A drawing decoded here and dropped when the render ends is not a
    /// second copy of the ink: nothing keeps it.
    package func revision(of page: PageID) async -> PageRevision? {
        guard index.record(of: page) != nil else { return nil }
        switch states[page] {
        case .ready(let content): return content.revision
        case .unloaded, .loading: return await unloadedContent(of: page)?.revision
        case .unreadable, nil: return nil
        }
    }

    /// A page decoded from its own files and installed nowhere, with any
    /// pending restore adopted: the revision the page *will* have, which is
    /// what a picture of it and a copy of it both want. Nothing is installed
    /// and nothing is marked dirty, so the state stays what it was.
    func unloadedContent(of page: PageID) async -> PageContent? {
        if Task.isCancelled { return nil }
        guard let bytes = try? await store.loadPage(page) else { return nil }
        if Task.isCancelled { return nil }
        guard case .ready(var content) = await Self.decode(bytes) else { return nil }
        if let pending = pendingRestores[page] { _ = content.adopt(pending) }
        return content
    }

    // MARK: Composites

    /// Re-renders a page's backdrop after its layers or paper changed. A
    /// layer being edited is left out. A result for a page no longer ready,
    /// or one a later render has superseded, is dropped; the current one
    /// installs the picture and then queues whatever `afterRender` holds,
    /// picture or not.
    ///
    /// One scale, always: the contract's Rendering rule is a composite
    /// rendered once and scaled to the zoom on each tick, so a zoom renders
    /// nothing.
    package func rerenderComposite(of page: PageID) {
        guard case .ready(var content) = states[page], let record = index.record(of: page) else { return }
        content.renderGeneration += 1
        states[page] = .ready(content)
        let generation = content.renderGeneration
        let layers = content.layers.filter { $0.id != content.textEditing?.layer }
        let renderer = self.renderer
        Task { [weak self] in
            let composite = await renderer.composite(geometry: record.geometry, paper: record.paper, layers: layers, scale: Notebook.baseCompositeScale)
            guard let self, case .ready(var current) = self.states[page], current.renderGeneration == generation else { return }
            if let composite {
                current.composite = composite
                self.changes.append(.compositeUpdated(page, composite, layers: current.layers))
            }
            self.changes.append(contentsOf: current.afterRender)
            current.afterRender.removeAll()
            self.states[page] = .ready(current)
            self.onAsyncChange?()
        }
    }

    /// Called when a change lands outside an intention (a composite arrived,
    /// a load installed). The binding drains on it.
    @ObservationIgnored package var onAsyncChange: (@MainActor () -> Void)?
}
