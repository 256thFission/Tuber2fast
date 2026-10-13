import Foundation
import Observation
import PencilKit
import TNCore
import TNFormat
import TNModel
import TNRender

/// The timing constants of the save engine, carried as values so a test
/// can run the engine at speed. The defaults carry the spec's numbers.
package struct SaveSchedule: Sendable {
    /// The idle debounce is `factor × lastSerialize`, clamped.
    package var idleFloor: Duration = .milliseconds(500)
    package var idleCeiling: Duration = .seconds(2)
    package var serializeFactor: Double = 4
    /// No page stays dirty longer than this without a pass starting.
    package var dirtyCeiling: Duration = .seconds(5)
    package var backoffCap: Duration = .seconds(5)
    package var retryBufferBytes: Int = 64 * 1024 * 1024

    package init() {}
}

/// The notebook: custody of every page's newest ink, the page order, and
/// the save engine. `@MainActor`; the store is an actor behind a seam.
///
/// Observed properties are stored mirrors. Everything heavy is ignored by
/// observation, so a stroke never invalidates a view.
@MainActor @Observable
package final class Notebook {
    // MARK: Observed mirrors

    package private(set) var pageCount: Int = 0
    package private(set) var currentPageID: PageID
    package private(set) var dirtyPageCount: Int = 0
    package private(set) var lastSaveError: SaveFailure?
    package private(set) var isClosed = false

    // MARK: Custody

    @ObservationIgnored package let store: any PackageStoring
    @ObservationIgnored package let renderer: Renderer
    @ObservationIgnored package let notebookID: NotebookID
    /// The scale composites are first rendered at: a 2x display at fit width.
    package static let baseCompositeScale: CGFloat = 2
    @ObservationIgnored package private(set) var index: NotebookIndex
    @ObservationIgnored private var indexSeq: UInt64 = 0
    @ObservationIgnored private var savedIndexSeq: UInt64 = 0
    @ObservationIgnored private var states: [PageID: PageState] = [:]
    @ObservationIgnored private var wanted: Set<PageID> = []
    @ObservationIgnored private var loads: [PageID: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextGeneration: UInt64 = 1
    @ObservationIgnored private var nextStructureSeq: UInt64 = 1
    @ObservationIgnored private var nextInkSeq: UInt64 = 1
    @ObservationIgnored private var changes: [NotebookChange] = []
    @ObservationIgnored private var history = EditHistory()
    /// An undo or redo whose page was not loaded: applied when the page
    /// arrives. One slot: the last stash is the revision the page will have.
    @ObservationIgnored private var pendingRestores: [PageID: PageRevision] = [:]
    /// Bumped by every change that alters what a page looks like: ink,
    /// layers, paper. Never reset by unload, because content is only dropped
    /// when clean (`prune()`), so the version on reload still describes the
    /// page. There is no choke point that sees every such change, so the
    /// bump sites are enumerated and `NotebookTests` is the enforcement.
    @ObservationIgnored private var contentVersions: [PageID: UInt64] = [:]

    // MARK: Save engine

    @ObservationIgnored package let schedule: SaveSchedule
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var currentSave: Task<Void, Never>?
    @ObservationIgnored private var lastSerialize: Duration = .milliseconds(100)
    @ObservationIgnored private var firstDirtyAt: ContinuousClock.Instant?
    @ObservationIgnored private var backoff: Duration?
    @ObservationIgnored private var retryBuffer: [PageID: (seq: UInt64, bytes: Data)] = [:]
    @ObservationIgnored private var viewWrite: Task<Void, Never>?

    private init(store: any PackageStoring, loaded: LoadedNotebook, view: ViewState?, schedule: SaveSchedule) {
        self.store = store
        self.renderer = Renderer(assets: store)
        self.schedule = schedule
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

    /// A new notebook: one page, US Letter and blank paper unless told
    /// otherwise, committed.
    package static func create(at root: URL, geometry: PageGeometry = .letter, paper: DrawnPaper = .blank, fileSystem: any PackageFileSystem = PosixFileSystem(), schedule: SaveSchedule = SaveSchedule()) async throws(FormatFault) -> Notebook {
        let index = NotebookIndex.new(notebookID: NotebookID(), firstPage: PageID(), createdAt: Date(), geometry: geometry, paper: paper)
        let store = try await PackageStore.create(root: root, index: index, fileSystem: fileSystem)
        return try await open(store: store, schedule: schedule)
    }

    // MARK: Reading state

    package func state(of page: PageID) -> PageState? { states[page] }

    package var pageIDs: [PageID] { index.pageIDs }

    package var descriptors: [PageDescriptor] {
        index.pages.map { PageDescriptor(id: $0.id, geometry: $0.geometry, paper: $0.paper) }
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

    /// The complete decoded window. Pages entering it load; loads for pages
    /// leaving it are cancelled and their results dropped on arrival.
    package func windowChanged(to pages: [PageID]) {
        let newWanted = Set(pages)
        for page in wanted.subtracting(newWanted) {
            loads[page]?.cancel()
            loads[page] = nil
            if case .loading = states[page] { states[page] = .unloaded }
        }
        wanted = newWanted
        for page in pages {
            if case .unloaded = states[page] { startLoad(page) }
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
                    content.composite = await renderer.composite(geometry: record.geometry, paper: record.paper.paper, layers: bytes.layers, scale: Notebook.baseCompositeScale)
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
            hasInk: bytes.file.hasInk || bytes.inkRecordNeeded,
            inkIndex: bytes.file.inkIndex
        )
        // An adopted container is recorded by the next save.
        if bytes.inkRecordNeeded { content.edited() }
        return .ready(content)
    }

    private func installLoaded(_ page: PageID, generation: UInt64, result: LoadOutcome) {
        guard case .loading(let current) = states[page], current == generation else { return }
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

    private func emitContent(_ page: PageID) {
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

    private func emitStructure(answering: ReportSeq?) {
        let seq = StructureSeq(nextStructureSeq); nextStructureSeq += 1
        changes.append(.structure(descriptors, seq: seq, answering: answering))
        pageCount = index.pages.count
    }

    private func withContent(_ page: PageID, _ mutate: (inout PageContent) -> Void) {
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
    package func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?, bindings: GestureBindings = [:]) {
        guard case .ready(var content) = states[page] else {
            TNPrecondition.fail("ink reported for page \(page) which is not ready: \(String(describing: states[page]))")
        }
        // An echo restates the value that was pushed. A report stamped with
        // the sequence but carrying different ink is PencilKit committing a
        // stroke on top of the install: on the device the commit that
        // follows `canvasViewDidEndUsingTool` can land after an undo's
        // restore and rides in under its latch. Swallowing it left the
        // undone stroke on the canvas and out of custody, and the next
        // stroke reported it back as new ink. Equality is the check, so the
        // value on screen is the value held either way.
        if let echoOf, echoOf == content.pendingEcho, ink == content.ink {
            content.pendingEcho = nil
            states[page] = .ready(content)
            return
        }
        content.pendingEcho = nil
        let captured = content.revision
        let gesture = gesture(on: page, in: ink, after: captured, bindings: bindings)
        if let gesture {
            // The same shape undo pushes: the edited drawing rides
            // `.inkRestored`, and its echo is swallowed by the latch above.
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

    private func bumpContentVersion(of page: PageID) {
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

    /// Whether any page has a text session open. The binding routes undo by
    /// it, whichever page the session is on.
    package var hasTextSession: Bool {
        states.values.contains { $0.content?.textEditing != nil }
    }

    /// An insert on a page with a session open is refused until it ends.
    package func hasTextSession(on page: PageID) -> Bool {
        states[page]?.content?.textEditing != nil
    }

    /// Every edit records through here, and only when the revision moved:
    /// an entry that restores nothing would still clear redo on the way in.
    /// `rebuilt` says the new revision's drawing was built here rather than
    /// handed over by the canvas, which is what its byte estimate turns on.
    /// Only the gesture path builds one; see `HistoryEntry`.
    private func recordEdit(
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
            if let finalInk, content.ink != finalInk { inkChanged(on: page, finalInk, echoOf: nil) }
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

    // MARK: Structure

    package func pageBecameCurrent(_ page: PageID) {
        guard index.record(of: page) != nil, page != currentPageID else { return }
        currentPageID = page
        scheduleViewWrite()
    }

    private func scheduleViewWrite() {
        viewWrite?.cancel()
        let store = self.store
        let page = currentPageID
        viewWrite = Task {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            try? await store.writeView(ViewState(currentPageID: page))
        }
    }

    /// A new page after `after` (or at the end), copying the current page's
    /// geometry and paper (`none` becomes `blank`). Returns its identity.
    ///
    /// Synchronous, and it must stay so: `EditorBinding.endBoundaryReached`
    /// answers a report in the same turn and cannot await.
    @discardableResult
    package func appendPage(after: PageID? = nil, answering: ReportSeq? = nil) -> PageID {
        let template = index.record(of: currentPageID) ?? index.pages[0]
        // Asset paper is not copied: it belongs to the page it was applied
        // to, whose geometry it set.
        let inherited = template.paper.paper?.drawn ?? .blank
        let paper = Paper.drawn(inherited == .none ? .blank : inherited)
        return insertPage(after: after, geometry: template.geometry, paper: paper, content: .empty, answering: answering)
    }

    /// A new page after `after` (or at the end), at a stated size and with a
    /// stated paper. Asset paper is measured before anything is inserted, so
    /// a refused append creates nothing.
    @discardableResult
    package func appendPage(after: PageID?, geometry: PageGeometry, paper: NewPagePaper) async throws(NewPageRefusal) -> PageID {
        guard geometry.isWithinBounds else {
            throw .geometryOutOfBounds(width: geometry.width, height: geometry.height)
        }
        let sized: PageGeometry
        let resolved: Paper
        switch paper {
        case .inheritTemplate:
            let template = index.record(of: currentPageID) ?? index.pages[0]
            let inherited = template.paper.paper?.drawn ?? .blank
            sized = geometry
            resolved = .drawn(inherited == .none ? .blank : inherited)
        case .drawn(let drawn):
            // Taken as typed, `.none` included: the `none` to `blank` rule
            // belongs to inheritance, not to a paper the user picked.
            sized = geometry
            resolved = .drawn(drawn)
        case .asset(let asset):
            guard let ref = asset.asset else {
                TNPrecondition.fail("appendPage: .asset carries drawn paper \(asset)")
            }
            guard let aspect = await renderer.aspect(of: asset) else { throw .assetUnreadable(ref) }
            // The asset fills the page rectangle, so the rectangle is the
            // asset's shape at the chosen width, as `setPaper` sizes it.
            let measured = PageGeometry(width: geometry.width, height: geometry.width * aspect)
            guard measured.isWithinBounds else {
                throw .geometryOutOfBounds(width: measured.width, height: measured.height)
            }
            sized = measured
            resolved = asset
        }
        return insertPage(after: after, geometry: sized, paper: resolved, content: .empty, answering: nil)
    }

    /// The one place a page is inserted, so anything every new page must do
    /// is written once. `content` is what the page starts with: empty for
    /// every caller but a duplicate, which starts with the source's.
    private func insertPage(after: PageID?, geometry: PageGeometry, paper: Paper, content: PageContent, answering: ReportSeq?) -> PageID {
        let record = PageRecord(id: PageID(), geometry: geometry, paper: paper)
        var pages = index.pages
        if let after, let position = pages.firstIndex(where: { $0.id == after }) {
            pages.insert(record, at: position + 1)
        } else {
            pages.append(record)
        }
        index = index.withPages(pages)
        var content = content
        // A page that has just been inserted owes the disk its page file
        // whatever is on it.
        content.edited()
        states[record.id] = .ready(content)
        wanted.insert(record.id)
        bumpContentVersion(of: record.id)
        indexSeq += 1
        emitStructure(answering: answering)
        emitContent(record.id)
        markDirty()
        rerenderComposite(of: record.id)
        return record.id
    }

    /// Deleting a page is navigation, not an edit, and is not itself
    /// undoable: the entries and any pending restore that name the page go
    /// with it, so no entry on either stack names a page the notebook does
    /// not hold.
    package func deletePage(_ page: PageID) {
        guard index.pages.count > 1, let position = index.pageIDs.firstIndex(of: page) else { return }
        index = index.withPages(index.pages.filter { $0.id != page })
        loads[page]?.cancel(); loads[page] = nil
        states[page] = nil
        contentVersions[page] = nil
        wanted.remove(page)
        pendingRestores[page] = nil
        history.forget(page)
        // The successor at the same position, clamped when the last page goes:
        // the page the runtime shows after the delete (`PagedCanvasController.setPages`),
        // so the notebook's current page and the viewport agree.
        if currentPageID == page {
            currentPageID = index.pageIDs[min(position, index.pageIDs.count - 1)]
            scheduleViewWrite()
        }
        indexSeq += 1
        emitStructure(answering: nil)
        markDirty()
    }

    /// A new page straight after `source`: the same geometry and paper, the
    /// same ink, and the same layers under new identities, naming the same
    /// assets.
    ///
    /// Navigation, like every other insert: it records nothing, so the undo
    /// stack is where it was. The layers are given new `LayerID`s because a
    /// layer file is one file per id — sharing them would make a transform on
    /// either page rewrite the file for both — while the assets are shared by
    /// name, which is safe because an asset is immutable and `compact()`
    /// keeps any a reachable layer names.
    ///
    /// A source that is not loaded is read from its files, so every cell in
    /// the navigator can be duplicated and not only the two or three the
    /// window happens to hold. A source with a text box open is refused: the
    /// typing is not in the revision yet.
    @discardableResult
    package func duplicatePage(_ source: PageID) async throws(FormatFault) -> PageID {
        guard let record = index.record(of: source) else { throw .invalidWrite("no such page \(source)") }
        // Paper this build does not know is refused rather than copied as
        // blank: a duplicate that quietly loses the paper is worse than one
        // that did not happen.
        guard let paper = record.paper.paper else {
            throw .invalidWrite("page \(source) has paper this build does not know")
        }
        let copied: PageContent
        switch states[source] {
        case .ready(let content):
            guard content.textEditing == nil else { throw .invalidWrite("page \(source) has a text box open") }
            copied = content
        case .unloaded, .loading:
            guard let read = await unloadedContent(of: source) else {
                throw .invalidWrite("page \(source) could not be read")
            }
            copied = read
        case .unreadable(let faults):
            throw .invalidWrite("page \(source) is unreadable: \(faults)")
        case nil:
            throw .invalidWrite("no such page \(source)")
        }

        let layers = copied.layers.map { Layer(id: LayerID(), transform: $0.transform, payload: $0.payload, locked: $0.locked) }
        var content = PageContent(ink: copied.ink, layers: layers, hasInk: false, inkIndex: copied.inkIndex)
        content.pendingLayerFiles = Set(layers.map(\.id))
        // `setInk` rather than the initializer's flag, so the durable flag and
        // the ink sequence agree and the first save writes the container.
        if copied.hasInk { content.setInk(copied.ink) }
        return insertPage(after: source, geometry: record.geometry, paper: paper, content: content, answering: nil)
    }

    // MARK: Bookmarks

    /// Marks `page`, or renames a mark it already has. An empty title is a
    /// mark nobody named, which is a mark all the same: presence is the flag.
    ///
    /// Not undoable, and it queues no change. Undo belongs to ink
    /// (`Docs/Contract.md` — Undo) and `PageRevision` is ink, layers and
    /// `inkIndex`, so there is no shape for a mark to be recorded in; and
    /// `EditorBinding.intention` refreshes the mirrors whether or not the
    /// mutation queued anything, so the navigator sees this without a
    /// structure change. Deleting, duplicating and moving pages are equally
    /// not undoable.
    ///
    /// A page the notebook does not hold is the programmer's error: the
    /// index is what the outline is read from, and a mark on nothing would
    /// be an index this build's own `validated()` refuses.
    package func bookmark(_ page: PageID, titled title: String) {
        guard index.record(of: page) != nil else {
            TNPrecondition.fail("a bookmark was set on page \(page), which the notebook does not hold")
        }
        // An unchanged mark writes nothing: an index rewritten for no change
        // is a bug (`Docs/Contract.md` — One save).
        guard index.bookmarks.first(where: { $0.page == page })?.title != title else { return }
        var bookmarks = index.bookmarks.filter { $0.page != page }
        bookmarks.append(PageBookmark(page: page, title: title))
        index = index.withBookmarks(bookmarks)
        indexSeq += 1
        markDirty()
    }

    /// Unmarks `page`. A page that carries no mark is not an error and
    /// writes nothing.
    package func removeBookmark(_ page: PageID) {
        guard index.bookmarks.contains(where: { $0.page == page }) else { return }
        index = index.withBookmarks(index.bookmarks.filter { $0.page != page })
        indexSeq += 1
        markDirty()
    }

    package func movePage(_ page: PageID, before target: PageID?) {
        var pages = index.pages
        guard let from = pages.firstIndex(where: { $0.id == page }) else { return }
        let record = pages.remove(at: from)
        if let target, let to = pages.firstIndex(where: { $0.id == target }) {
            pages.insert(record, at: to)
        } else {
            pages.append(record)
        }
        index = index.withPages(pages)
        indexSeq += 1
        emitStructure(answering: nil)
        markDirty()
    }

    /// Drawn paper applies to any page. Asset paper applies only to a page
    /// that is loaded and empty, and takes the page's geometry with it: the
    /// asset fills the page rectangle, so the rectangle is the asset's shape.
    package func setPaper(_ paper: Paper, on page: PageID) async throws(PaperRefusal) {
        guard let record = index.record(of: page) else { throw .pageNotLoaded }
        var geometry = record.geometry
        if paper.isAsset {
            try checkAssetPaperTarget(page)
            guard let aspect = await renderer.aspect(of: paper) else { throw .assetUnreadable }
            // The page may have changed while the asset was being measured.
            try checkAssetPaperTarget(page)
            let sized = PageGeometry(width: record.geometry.width, height: record.geometry.width * aspect)
            guard sized.isWithinBounds else { throw .geometryOutOfBounds }
            geometry = sized
        }
        index = index.withPages(index.pages.map { $0.id == page ? $0.with(paper: paper, geometry: geometry) : $0 })
        bumpContentVersion(of: page)
        indexSeq += 1
        emitStructure(answering: nil)
        markDirty()
        rerenderComposite(of: page)
    }

    /// Asset paper covers the whole page, so a page with anything on it
    /// would lose it behind the paper.
    private func checkAssetPaperTarget(_ page: PageID) throws(PaperRefusal) {
        guard case .ready(let content) = states[page] else { throw .pageNotLoaded }
        guard content.ink.strokes.isEmpty, content.layers.isEmpty else { throw .pageNotEmpty }
    }

    package func paper(of page: PageID) -> Paper? { index.record(of: page)?.paper.paper }

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
        return await renderer.thumbnail(key, geometry: record.geometry, paper: record.paper.paper, layers: revision.layers, ink: revision.ink)
    }

    /// What a page holds right now, whether or not it is loaded, for a render
    /// that must not disturb it. A ready page answers from custody, unsaved
    /// ink included. Any other page is read from its files and decoded in the
    /// caller's task, so a cancelled render stops mid-decode; nothing is
    /// installed, nothing is marked dirty, and the state does not move. A
    /// pending restore is preferred over the ink on disk, because it is the
    /// ink the page will have. A page with no record, or one whose files do
    /// not decode, is nil.
    ///
    /// A drawing decoded here and dropped when the render ends is not a
    /// second copy of the ink: nothing keeps it.
    package func revision(of page: PageID) async -> PageRevision? {
        guard index.record(of: page) != nil else { return nil }
        if case .ready(let content) = states[page] { return content.revision }
        return await unloadedContent(of: page)?.revision
    }

    /// A page decoded from its own files and installed nowhere, with any
    /// pending restore adopted: the revision the page *will* have, which is
    /// what a picture of it and a copy of it both want. Nothing is installed
    /// and nothing is marked dirty, so the state stays what it was.
    private func unloadedContent(of page: PageID) async -> PageContent? {
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
    /// rendered once and scaled by the scroll view, and says nothing about a
    /// sharper render at zoom.
    package func rerenderComposite(of page: PageID) {
        guard case .ready(var content) = states[page], let record = index.record(of: page) else { return }
        content.renderGeneration += 1
        states[page] = .ready(content)
        let generation = content.renderGeneration
        let layers = content.layers.filter { $0.id != content.textEditing?.layer }
        let renderer = self.renderer
        Task { [weak self] in
            let composite = await renderer.composite(geometry: record.geometry, paper: record.paper.paper, layers: layers, scale: Notebook.baseCompositeScale)
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

    // MARK: Layers

    /// Validates and inserts a layer beneath the ink, synchronously: the tap
    /// that makes a text box gets its layer in the same pass. `recording`
    /// is false for a text box, whose session records the insert as part
    /// of one step at its end.
    package func insertLayer(_ layer: Layer, on page: PageID, recording: Bool = true) throws(FormatFault) {
        guard case .ready(var content) = states[page] else { throw .invalidWrite("page \(page) is not ready") }
        do { _ = try layer.validated() } catch { throw .invalidWrite("layer invalid: \(error)") }
        let captured = content.revision
        content.layers.insert(layer, at: content.inkIndex)
        content.inkIndex += 1
        content.pendingLayerFiles.insert(layer.id)
        content.edited()
        if recording { recordEdit(on: page, from: captured, to: content.revision, rebuilt: false) }
        states[page] = .ready(content)
        bumpContentVersion(of: page)
        markDirty()
        rerenderComposite(of: page)
    }

    /// Adds a layer beneath the ink. The asset, if any, is published first.
    package func addLayer(_ layer: Layer, assetData: Data?, on page: PageID) async throws(FormatFault) {
        guard case .ready = states[page] else { throw .invalidWrite("page \(page) is not ready") }
        do { _ = try layer.validated() } catch { throw .invalidWrite("layer invalid: \(error)") }
        if let asset = layer.payload.asset {
            guard let assetData else { throw .invalidWrite("layer names an asset with no bytes") }
            try await store.writeAsset(assetData, asset)
        }
        try insertLayer(layer, on: page)
    }

    /// An image, normalized to HEIC, placed centered at up to 60% of each
    /// page edge, beneath the ink.
    package func importImage(_ data: Data, on page: PageID) async throws(FormatFault) {
        let fraction = 0.6
        guard let normalized = await Task.detached(priority: .userInitiated, operation: { ImageImport.normalize(data) }).value else {
            throw .invalidWrite("image could not be decoded")
        }
        guard let record = index.record(of: page) else { throw .invalidWrite("no such page") }
        let fit = min(record.geometry.width * fraction / Double(normalized.size.width), record.geometry.height * fraction / Double(normalized.size.height))
        let width = Double(normalized.size.width) * fit, height = Double(normalized.size.height) * fit
        let transform = PageSpaceTransform.placing(
            sourceWidth: Double(normalized.size.width), sourceHeight: Double(normalized.size.height),
            at: ((record.geometry.width - width) / 2, (record.geometry.height - height) / 2), scale: fit)
        let layer = Layer(id: LayerID(), transform: transform, payload: .image(ImageLayer(asset: AssetRef(id: AssetID(), format: .heic), naturalSize: normalized.size)))
        try await addLayer(layer, assetData: normalized.heic, on: page)
    }

    /// One new page per PDF page, inserted after the current page, each
    /// sized to its source extent with that PDF page as its paper. The asset
    /// is written once. No layer: the `pdf` layer kind is for a clipping
    /// placed on a page, not for a page that *is* the PDF.
    ///
    /// KNOWN DEFECT: a throw here abandons the pages it already made. The
    /// `throw` for a page outside the bounds goes straight past the
    /// `emitStructure`, the `emitContent`s and the `markDirty` below, so those
    /// pages sit in the index with no one having told the canvas about them
    /// and no save scheduled — the canvas shows the old page list until
    /// something else restates it, and the notebook believes it is clean.
    /// `importScan` below does the same job and does not have this defect: it
    /// publishes what it made on the way out of every exit including a throw.
    /// Not fixed here because this change touches no existing method, and the
    /// fix wants a test of its own.
    package func importPDF(_ data: Data) async throws(FormatFault) {
        guard let source = PDFSource(data: data), source.pageCount > 0 else { throw .invalidWrite("PDF could not be opened") }
        let asset = AssetRef(id: AssetID(), format: .pdf)
        try await store.writeAsset(data, asset)
        var after = currentPageID
        var created: [PageID] = []
        for pageIndex in 0..<source.pageCount {
            guard let page = source.page(at: pageIndex), let extent = PDFSource.displayExtent(of: page) else { continue }
            let geometry = PageGeometry(width: extent.width, height: extent.height)
            guard geometry.isWithinBounds else { throw .invalidWrite("PDF page \(pageIndex + 1) is outside the page bounds") }
            let record = PageRecord(id: PageID(), geometry: geometry, paper: .pdf(asset, sourcePageIndex: pageIndex))
            var pages = index.pages
            let position = pages.firstIndex { $0.id == after }.map { $0 + 1 } ?? pages.count
            pages.insert(record, at: position)
            index = index.withPages(pages)
            var content = PageContent(ink: PKDrawing(), layers: [], hasInk: false, inkIndex: 0)
            content.edited()
            states[record.id] = .ready(content)
            wanted.insert(record.id)
            bumpContentVersion(of: record.id)
            created.append(record.id)
            after = record.id
        }
        indexSeq += 1
        emitStructure(answering: nil)
        for page in created {
            emitContent(page)
            rerenderComposite(of: page)
        }
        markDirty()
    }

    /// One new page per scanned page, after the current page and in scan
    /// order, each keeping the current page's width and taking the scan's
    /// aspect the way `appendPage` measures asset paper. Returns what it made.
    ///
    /// Here rather than in `TNEditor` because page order is the notebook's
    /// (`Docs/Contract.md`, Custody), and in `importPDF`'s shape: one
    /// `emitStructure` and one `markDirty` for the run, not the per-page storm
    /// N calls to `appendPage` would kick, each of which ends in `insertPage`
    /// and restates the whole page list to the canvas.
    ///
    /// `after` is threaded locally and re-checked against `index.pageIDs`
    /// after every await, which `importPDF` need not do: its loop body has no
    /// await and this one suspends twice per page, at `storeImageAsset` and at
    /// `renderer.aspect`. If the page `after` names is deleted across a
    /// suspension, the end of the notebook is the only answer left, and a
    /// default is what the contract forbids, so the run stops instead.
    ///
    /// A page that cannot be stored or measured, or an `after` that is gone,
    /// stops the run, and what was made is emitted and marked dirty before the
    /// error is thrown. `importPDF` above does not do that; the block on it
    /// says so.
    package func importScan(_ images: [Data]) async throws(FormatFault) -> [PageID] {
        guard !images.isEmpty else { return [] }
        // The width is the current page's, read once: every page of one scan
        // is the same width, whatever the reader does while it runs.
        guard let template = index.record(of: currentPageID) else {
            throw .invalidWrite("no current page to scan after")
        }
        let width = template.geometry.width
        var after = currentPageID
        var created: [PageID] = []

        /// What the run owes the canvas and the store for the pages it made,
        /// on the way out of every exit including a throw.
        func publish() {
            guard !created.isEmpty else { return }
            indexSeq += 1
            emitStructure(answering: nil)
            for page in created {
                emitContent(page)
                rerenderComposite(of: page)
            }
            markDirty()
        }

        for (offset, data) in images.enumerated() {
            let number = offset + 1
            let asset: AssetRef
            do {
                asset = try await storeImageAsset(data)
            } catch {
                publish()
                throw .invalidWrite("scanned page \(number) could not be stored: \(error.description)")
            }
            // The first re-check, after the store's suspension.
            guard index.pageIDs.contains(after) else {
                publish()
                throw .invalidWrite("the page scanned page \(number) would follow is gone")
            }
            guard let aspect = await renderer.aspect(of: .image(asset)) else {
                publish()
                throw .invalidWrite("scanned page \(number) could not be measured")
            }
            // The second re-check, and the one that answers where the page
            // goes. `importPDF` falls back to the end of the notebook here;
            // this asks for the position and stops if there is not one, so no
            // scanned page can silently land somewhere it was not asked to.
            guard let position = index.pages.firstIndex(where: { $0.id == after }) else {
                publish()
                throw .invalidWrite("the page scanned page \(number) would follow is gone")
            }
            let geometry = PageGeometry(width: width, height: width * aspect)
            guard geometry.isWithinBounds else {
                publish()
                throw .invalidWrite("scanned page \(number) is outside the page bounds")
            }
            let record = PageRecord(id: PageID(), geometry: geometry, paper: .image(asset))
            var pages = index.pages
            pages.insert(record, at: position + 1)
            index = index.withPages(pages)
            var content = PageContent(ink: PKDrawing(), layers: [], hasInk: false, inkIndex: 0)
            content.edited()
            states[record.id] = .ready(content)
            wanted.insert(record.id)
            bumpContentVersion(of: record.id)
            created.append(record.id)
            after = record.id
        }
        publish()
        return created
    }

    /// A photo normalized to HEIC and published as an asset, ready to be a
    /// page's paper.
    package func storeImageAsset(_ data: Data) async throws(FormatFault) -> AssetRef {
        guard let normalized = await Task.detached(priority: .userInitiated, operation: { ImageImport.normalize(data) }).value else {
            throw .invalidWrite("image could not be decoded")
        }
        guard normalized.size.isValid else { throw .invalidWrite("image is outside the asset bounds") }
        let asset = AssetRef(id: AssetID(), format: .heic)
        try await store.writeAsset(normalized.heic, asset)
        return asset
    }

    /// A photo as a page's paper: normalized to HEIC, published, applied.
    package func importImageAsPaper(_ data: Data, on page: PageID) async throws(FormatFault) {
        do { try checkAssetPaperTarget(page) } catch { throw .invalidWrite("paper refused: \(error)") }
        let asset = try await storeImageAsset(data)
        do { try await setPaper(.image(asset), on: page) } catch { throw .invalidWrite("paper refused: \(error)") }
    }

    /// A page's composite and ink rendered to one asset at asset resolution.
    /// The source page is untouched; the caller decides which empty page the
    /// result becomes the paper of.
    package func flatten(_ page: PageID) async throws(FormatFault) -> AssetRef {
        guard let record = index.record(of: page) else { throw .invalidWrite("no such page") }
        guard case .ready(let content) = states[page] else { throw .invalidWrite("page \(page) is not ready") }
        guard let heic = await renderer.flattened(
            geometry: record.geometry, paper: record.paper.paper, layers: content.layers, ink: content.ink, as: "public.heic" as CFString
        ) else { throw .invalidWrite("page \(page) could not be flattened") }
        let asset = AssetRef(id: AssetID(), format: .heic)
        try await store.writeAsset(heic, asset)
        return asset
    }

    package func addLinkLayer(on page: PageID, rect: PageRect, target: LinkTarget) throws(FormatFault) {
        let layer = Layer(id: LayerID(), transform: .identity, payload: .link(LinkLayer(rect: rect, style: .button, target: target)))
        try insertLayer(layer, on: page)
    }

    // MARK: Text editing

    /// An empty text box at `point`, and a session opened on it. The style
    /// rides with the request for the runtime's sake; an empty layer stores
    /// none, and the runtime types with its tool's. The session's `before`
    /// is captured ahead of the insert, so the box and what is typed in it
    /// undo as one step.
    package func createTextBox(on page: PageID, at point: PagePoint, style: TextStyle, alignment: TextAlignment) {
        guard case .ready(let content) = states[page] else {
            TNPrecondition.fail("a text box was requested on page \(page) which is not ready: \(String(describing: states[page]))")
        }
        let before = content.revision
        let layer = Layer(
            id: LayerID(), transform: .identity,
            payload: .text(TextLayer(rect: PageRect(x: point.x, y: point.y, width: 240, height: 96), runs: [], alignment: alignment))
        )
        do {
            try insertLayer(layer, on: page, recording: false)
        } catch {
            TNPrecondition.fail("a text box was requested on page \(page), which refused it: \(error)")
        }
        openTextSession(on: page, layer: layer.id, before: before)
    }

    /// A session on a box the page already holds; the revision it records
    /// against is the one it opens on.
    package func beginTextEditing(on page: PageID, layer: LayerID) {
        guard case .ready(let content) = states[page] else {
            TNPrecondition.fail("text editing began on page \(page) which is not ready: \(String(describing: states[page]))")
        }
        openTextSession(on: page, layer: layer, before: content.revision)
    }

    /// The composite leaves the layer out from the next render on, and the
    /// runtime is told to raise its view once that picture has landed.
    private func openTextSession(on page: PageID, layer: LayerID, before: PageRevision) {
        guard case .ready(var content) = states[page] else {
            TNPrecondition.fail("text editing began on page \(page) which is not ready: \(String(describing: states[page]))")
        }
        TNPrecondition.require(content.textEditing == nil, "text editing began on page \(page) while layer \(String(describing: content.textEditing?.layer)) was open")
        guard let found = content.layers.first(where: { $0.id == layer }), case .text(let text) = found.payload else {
            // Hit rects are one render stale between a restore and the
            // composite it queued, so a tap there can ask for a box the
            // restore removed. The runtime is waiting in `.opening`; the end
            // is what releases it, as it is for a begin the runtime cannot
            // honour.
            TNLog.event(.notebook, "text editing was requested on page \(page) for layer \(layer), which is not a text layer it holds")
            changes.append(.textEditingEnded(page, layer))
            return
        }
        content.textEditing = TextSession(layer: layer, before: before)
        content.afterRender.append(.textEditingBegan(page, TextEditStart(layer: layer, text: text)))
        states[page] = .ready(content)
        rerenderComposite(of: page)
    }

    /// The session is the edit: one entry from the revision the session
    /// opened on to the one its commit leaves, and none when they are equal.
    /// An abandoned empty box is equal by construction, since its insert
    /// was not recorded and its removal returns the page to `before`.
    package func endTextEditing(on page: PageID, layer: LayerID, _ text: TextLayer) {
        guard case .ready(var content) = states[page] else {
            TNPrecondition.fail("text editing ended on page \(page) which is not ready: \(String(describing: states[page]))")
        }
        guard let session = content.textEditing, session.layer == layer else {
            TNPrecondition.fail("text editing ended on page \(page) for layer \(layer), which is not the open one (\(String(describing: content.textEditing?.layer)))")
        }
        guard let position = content.layers.firstIndex(where: { $0.id == layer }) else {
            TNPrecondition.fail("text editing ended on page \(page) for layer \(layer), which it no longer holds")
        }
        content.textEditing = nil
        let merged = TextLayer(rect: text.rect, runs: TextRun.merging(text.runs), alignment: text.alignment)
        let committed = Layer(id: layer, transform: .identity, payload: .text(merged), locked: content.layers[position].locked)
        // The overlay's gesture math cannot produce an invalid rect, and a
        // clamp is forbidden.
        do { _ = try committed.validated() } catch { TNPrecondition.fail("a committed text layer is invalid: \(error)") }
        if merged.runs.allSatisfy(\.string.isEmpty) {
            content.layers.remove(at: position)
            if position < content.inkIndex { content.inkIndex -= 1 }
            content.pendingLayerFiles.remove(layer)
            content.edited()
        } else if content.layers[position].payload != .text(merged) {
            content.layers[position] = committed
            content.pendingLayerFiles.insert(layer)
            content.edited()
        }
        // An unchanged commit rewrites nothing: a save writes only what changed.
        // Two questions, not one: whether this commit moved the page is what
        // the save and the thumbnail need, and an abandoned empty box moved it
        // twice, once to insert and once to remove. Whether the session moved
        // the revision is what the stack needs, and that box did not.
        let changed = content.editSeq != (states[page]?.content?.editSeq ?? content.editSeq)
        recordEdit(on: page, from: session.before, to: content.revision, rebuilt: false)
        content.afterRender.append(.textEditingEnded(page, layer))
        states[page] = .ready(content)
        if changed {
            bumpContentVersion(of: page)
            markDirty()
        }
        rerenderComposite(of: page)
    }

    /// A locked layer refuses a transform and a delete, and says so. Not a
    /// trap: the runtime is told the lock through the composite's layer
    /// list, but an undo can relock a layer while a drag on it is in
    /// flight, and the drag's end reports anyway. The refusal is answered
    /// like any other, by restating the placement the notebook holds.
    package func transformLayer(on page: PageID, layer layerID: LayerID, to transform: PageSpaceTransform) -> TransformOutcome {
        guard case .ready(var content) = states[page] else { return .refused(reason: "page is not ready") }
        guard let position = content.layers.firstIndex(where: { $0.id == layerID }) else { return .refused(reason: "no such layer") }
        guard !content.layers[position].locked else { return .refused(reason: "layer \(layerID) is locked") }
        let moved = content.layers[position].withTransform(transform)
        do { _ = try moved.validated() } catch { return .refused(reason: "\(error)") }
        let captured = content.revision
        content.layers[position] = moved
        content.pendingLayerFiles.insert(layerID)
        content.edited()
        recordEdit(on: page, from: captured, to: content.revision, rebuilt: false)
        states[page] = .ready(content)
        bumpContentVersion(of: page)
        markDirty()
        rerenderComposite(of: page)
        return .accepted
    }

    /// Moves a link. A link's placement is its rect and its transform is the
    /// identity — `validated()` refuses any other — so a move is a rect edit
    /// and `transformLayer` refuses every one of them. This is that method's
    /// body with a new rect in place of a new transform, recorded through
    /// the revision like any other layer edit, and rerendered so the hit
    /// rects follow the picture.
    ///
    /// It answers a `TransformOutcome` so an overlay's report can be answered
    /// the way `layerTransformed` is.
    package func moveLinkLayer(on page: PageID, layer layerID: LayerID, to rect: PageRect) -> TransformOutcome {
        guard case .ready(var content) = states[page] else { return .refused(reason: "page is not ready") }
        guard let position = content.layers.firstIndex(where: { $0.id == layerID }) else { return .refused(reason: "no such layer") }
        guard case .link(let link) = content.layers[position].payload else { return .refused(reason: "layer \(layerID) is not a link") }
        guard !content.layers[position].locked else { return .refused(reason: "layer \(layerID) is locked") }
        let moved = Layer(
            id: layerID,
            transform: content.layers[position].transform,
            payload: .link(LinkLayer(rect: rect, style: link.style, target: link.target)),
            locked: content.layers[position].locked
        )
        do { _ = try moved.validated() } catch { return .refused(reason: "\(error)") }
        let captured = content.revision
        content.layers[position] = moved
        content.pendingLayerFiles.insert(layerID)
        content.edited()
        recordEdit(on: page, from: captured, to: content.revision, rebuilt: false)
        states[page] = .ready(content)
        bumpContentVersion(of: page)
        markDirty()
        rerenderComposite(of: page)
        return .accepted
    }

    /// Locks or unlocks a layer. One entry on the stack, like a transform,
    /// and answered the same way: the composite that follows carries the
    /// layer list with the flag, which is how the runtime learns it.
    package func setLayerLock(_ layerID: LayerID, on page: PageID, locked: Bool) -> TransformOutcome {
        guard case .ready(var content) = states[page] else { return .refused(reason: "page is not ready") }
        guard let position = content.layers.firstIndex(where: { $0.id == layerID }) else { return .refused(reason: "no such layer") }
        let captured = content.revision
        content.layers[position] = content.layers[position].withLock(locked)
        content.pendingLayerFiles.insert(layerID)
        content.edited()
        recordEdit(on: page, from: captured, to: content.revision, rebuilt: false)
        states[page] = .ready(content)
        bumpContentVersion(of: page)
        markDirty()
        rerenderComposite(of: page)
        return .accepted
    }

    /// A delete is answered by the composite that omits the layer, so it
    /// had nothing to say back until a lock could refuse it. It says so the
    /// way a transform does; the binding has nothing to do with the answer
    /// but a test does.
    @discardableResult
    package func deleteLayer(_ layerID: LayerID, on page: PageID) -> TransformOutcome {
        guard case .ready(var content) = states[page] else { return .refused(reason: "page is not ready") }
        guard let position = content.layers.firstIndex(where: { $0.id == layerID }) else { return .refused(reason: "no such layer") }
        guard !content.layers[position].locked else { return .refused(reason: "layer \(layerID) is locked") }
        let captured = content.revision
        content.layers.remove(at: position)
        if position < content.inkIndex { content.inkIndex -= 1 }
        content.pendingLayerFiles.remove(layerID)
        content.edited()
        recordEdit(on: page, from: captured, to: content.revision, rebuilt: false)
        states[page] = .ready(content)
        bumpContentVersion(of: page)
        markDirty()
        rerenderComposite(of: page)
        return .accepted
    }

    // MARK: The save engine

    /// Recounts the mirror and arms the debounce unless a pass is running;
    /// the running pass re-arms at its exit, the single owner of re-arming.
    private func markDirty() {
        dirtyPageCount = states.values.count(where: \.isDirty)
        if firstDirtyAt == nil { firstDirtyAt = .now }
        guard currentSave == nil, debounce == nil else { return }
        let interval = nextInterval()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.debounce = nil
            self.beginSave()
        }
    }

    private func nextInterval() -> Duration {
        if let backoff { return backoff }
        if let firstDirtyAt, firstDirtyAt.duration(to: .now) >= schedule.dirtyCeiling { return .zero }
        let scaled = lastSerialize * schedule.serializeFactor
        return min(max(scaled, schedule.idleFloor), schedule.idleCeiling)
    }

    private struct Captured: Sendable {
        let page: PageID
        let file: PageFile
        /// The ink to write, or nil when the container is unchanged.
        let ink: PKDrawing?
        let editSeq: UInt64
        let inkSeq: UInt64
        let layerFiles: [Layer]
    }

    /// Capture is synchronous and total; the write is a task.
    private func beginSave() {
        guard currentSave == nil else { return }
        var captured: [Captured] = []
        for page in index.pageIDs {
            guard case .ready(let content) = states[page], content.isDirty else { continue }
            let file = PageFile(pageID: page, hasInk: content.hasInk, inkIndex: content.inkIndex, layers: content.layers.map(\.id))
            captured.append(Captured(
                page: page, file: file,
                ink: content.hasInk && content.inkIsDirty ? content.ink : nil,
                editSeq: content.editSeq, inkSeq: content.inkSeq,
                layerFiles: content.layers.filter { content.pendingLayerFiles.contains($0.id) }
            ))
        }
        let intended = index
        let indexChanged = indexSeq > savedIndexSeq
        let capturedIndexSeq = indexSeq
        guard !captured.isEmpty || indexChanged else { firstDirtyAt = nil; return }

        let retry = retryBuffer
        currentSave = Task { [weak self] in
            await self?.performSave(captured: captured, intended: intended, indexChanged: indexChanged, capturedIndexSeq: capturedIndexSeq, retry: retry)
        }
    }

    private func performSave(captured: [Captured], intended: NotebookIndex, indexChanged: Bool, capturedIndexSeq: UInt64, retry: [PageID: (seq: UInt64, bytes: Data)]) async {
        // One hop off the main actor serializes every drawing this pass
        // writes; a buffered archive from a failed pass is reused as long
        // as the ink has not changed since.
        var serialized: [PageID: (seq: UInt64, bytes: Data)] = [:]
        var toSerialize: [(PageID, UInt64, PKDrawing)] = []
        for item in captured {
            guard let ink = item.ink else { continue }
            if let buffered = retry[item.page], buffered.seq == item.inkSeq {
                serialized[item.page] = buffered
            } else {
                toSerialize.append((item.page, item.inkSeq, ink))
            }
        }
        if !toSerialize.isEmpty {
            let clock = ContinuousClock()
            let started = clock.now
            let encoded = await Task.detached(priority: .utility) {
                toSerialize.map { ($0.0, $0.1, $0.2.dataRepresentation()) }
            }.value
            lastSerialize = started.duration(to: clock.now)
            for (page, seq, bytes) in encoded { serialized[page] = (seq, bytes) }
        }
        let writes = captured.map { item in
            PageWrite(file: item.file, ink: serialized[item.page].map { .archive($0.bytes) } ?? .unchanged, layerFiles: item.layerFiles)
        }

        let batch = SaveBatch(index: intended, indexChanged: indexChanged, pages: writes)
        do {
            let report = try await store.save(batch)
            for item in captured where report.committed.contains(item.page) && report.refusals[item.page] == nil {
                withContent(item.page) { content in
                    content.savedSeq = max(content.savedSeq, item.editSeq)
                    content.savedInkSeq = max(content.savedInkSeq, item.inkSeq)
                    // A restore that landed while this pass was writing
                    // re-pends a layer it wrote; un-pending by id alone would
                    // drop that value from the next page file and close clean
                    // with the undone one on disk. Layers have no sequence,
                    // so the value is the check.
                    for written in item.layerFiles {
                        let held = content.layers.first { $0.id == written.id }
                        if held == nil || held == written { content.pendingLayerFiles.remove(written.id) }
                    }
                }
                retryBuffer[item.page] = nil
            }
            for (page, refusal) in report.refusals {
                TNLog.event(.notebook, "page \(page) refused: \(refusal)")
            }
            if report.indexWritten { savedIndexSeq = max(savedIndexSeq, capturedIndexSeq) }
            if report.indexWithheld {
                lastSaveError = .indexWithheld
            } else if !report.refusals.isEmpty {
                lastSaveError = .pagesRefused(report.refusals)
            } else {
                lastSaveError = nil
            }
            backoff = nil
        } catch {
            if case .insufficientSpace(let needed, let available) = error {
                lastSaveError = .insufficientSpace(needed: needed, available: available)
            } else {
                lastSaveError = .io(error)
            }
            var total = 0
            for (page, entry) in serialized {
                total += entry.bytes.count
                if total <= schedule.retryBufferBytes { retryBuffer[page] = entry }
            }
            backoff = min((backoff ?? schedule.idleFloor) * 2, schedule.backoffCap)
            TNLog.event(.notebook, "save failed: \(error); backoff \(String(describing: backoff))")
        }
        currentSave = nil
        firstDirtyAt = nil
        dirtyPageCount = states.values.count(where: \.isDirty)
        if isDirty { markDirty() }
    }

    /// Runs a pass now and waits for it, and for any pass already running.
    package func flush() async {
        debounce?.cancel()
        debounce = nil
        if let running = currentSave { await running.value }
        if isDirty {
            beginSave()
            if let running = currentSave { await running.value }
        }
    }

    /// The final pass. After this, no write is outstanding.
    package func close() async -> CloseOutcome {
        await flush()
        viewWrite?.cancel()
        try? await store.writeView(ViewState(currentPageID: currentPageID))
        // A dirty close leaves the notebook open: the checkout stays, the
        // banner shows, and the next flush retries. Only a clean close ends it.
        if isDirty { return .dirty(pages: dirtyPages, indexUnsaved: indexSeq > savedIndexSeq) }
        isClosed = true
        return .clean
    }
}

/// A new page's paper.
package enum NewPagePaper: Sendable, Equatable {
    /// The existing rule: the current page's drawn paper, `none` becomes
    /// `blank`, asset becomes `blank`. Named for what it does, not for which
    /// page: `after:` may not be the current page.
    case inheritTemplate
    case drawn(DrawnPaper)
    /// An asset already in the package. The page keeps the chosen width and
    /// takes the asset's aspect, the rule `setPaper` applies to an empty page.
    case asset(Paper)
}

/// Why a new page was refused. Both are decided before anything is
/// inserted, so a refusal leaves nothing behind.
package enum NewPageRefusal: Error, Sendable, Equatable {
    case geometryOutOfBounds(width: Double, height: Double)
    case assetUnreadable(AssetRef)
}

/// Why a paper change was refused. Drawn paper is never refused on a page
/// that exists; every case here is about asset paper.
package enum PaperRefusal: Error, Sendable, Equatable {
    case pageNotLoaded
    case pageNotEmpty
    case geometryOutOfBounds
    case assetUnreadable
}
