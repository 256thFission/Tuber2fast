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
    @ObservationIgnored private var history = InkHistory()
    /// An undo whose page was not loaded: applied when the page arrives.
    @ObservationIgnored private var pendingRestores: [PageID: PKDrawing] = [:]

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
            var faults = bytes.faults
            var ink: PKDrawing?
            if let archive = bytes.inkArchive {
                let decoded = await Task.detached(priority: .userInitiated) { () -> Result<PKDrawing, any Error> in
                    do { return .success(try PKDrawing(data: archive)) } catch { return .failure(error) }
                }.value
                switch decoded {
                case .success(let drawing): ink = drawing
                case .failure(let error): faults.append(.inkArchiveUndecodable("\(error)"))
                }
            }
            if Task.isCancelled { return }
            if faults.isEmpty {
                var content = PageContent(
                    ink: ink ?? PKDrawing(),
                    layers: bytes.layers,
                    hasInk: bytes.file.hasInk || bytes.inkRecordNeeded,
                    inkIndex: bytes.file.inkIndex
                )
                // An adopted container is recorded by the next save.
                if bytes.inkRecordNeeded { content.edited() }
                if let record, let renderer = self?.renderer {
                    content.composite = await renderer.composite(geometry: record.geometry, paper: record.paper.paper, layers: bytes.layers, scale: Notebook.baseCompositeScale)
                }
                self?.installLoaded(page, generation: generation, result: .ready(content))
            } else {
                self?.installLoaded(page, generation: generation, result: .faults(faults))
            }
        }
    }

    private enum LoadOutcome: Sendable {
        case ready(PageContent)
        case faults([PageFault])
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
            if let restore = pendingRestores.removeValue(forKey: page) {
                history.pushRedo(HistoryEntry(page: page, ink: content.ink))
                content.setInk(restore)
            }
            states[page] = .ready(content)
            if content.isDirty { markDirty() }
        case .faults(let faults):
            states[page] = .unreadable(faults)
            pendingRestores[page] = nil
        }
        emitContent(page)
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
    package func inkChanged(on page: PageID, _ ink: PKDrawing, echoOf: InkSeq?) {
        guard case .ready(var content) = states[page] else {
            TNPrecondition.fail("ink reported for page \(page) which is not ready: \(String(describing: states[page]))")
        }
        if let echoOf, echoOf == content.pendingEcho {
            content.pendingEcho = nil
            states[page] = .ready(content)
            return
        }
        content.pendingEcho = nil
        history.recordEdit(on: page, previous: content.ink)
        content.setInk(ink)
        states[page] = .ready(content)
        markDirty()
    }

    package var canUndo: Bool { history.canUndo }
    package var canRedo: Bool { history.canRedo }

    /// One notebook-wide stack, GoodNotes-shaped: an undo restores the page
    /// it happened on, whichever page is current, and the binding scrolls
    /// there. Returns that page, or nil when there is nothing to undo.
    @discardableResult
    package func undo() -> PageID? {
        guard let entry = history.undo(current: { self.states[$0]?.content?.ink }) else { return nil }
        restore(entry)
        return entry.page
    }

    @discardableResult
    package func redo() -> PageID? {
        guard let entry = history.redo(current: { self.states[$0]?.content?.ink }) else { return nil }
        restore(entry)
        return entry.page
    }

    private func restore(_ entry: HistoryEntry) {
        guard case .ready(var content) = states[entry.page] else {
            // The page left the window; bring it back and apply on arrival.
            pendingRestores[entry.page] = entry.ink
            wanted.insert(entry.page)
            if case .unloaded = states[entry.page] { startLoad(entry.page) }
            return
        }
        content.setInk(entry.ink)
        let seq = InkSeq(nextInkSeq); nextInkSeq += 1
        content.pendingEcho = seq
        states[entry.page] = .ready(content)
        changes.append(.inkRestored(entry.page, entry.ink, seq: seq))
        markDirty()
    }

    /// The runtime's final report for a retired canvas. `finalInk` nil means
    /// the canvas was a placeholder and held nothing.
    package func retired(_ page: PageID, finalInk: PKDrawing?) {
        if let finalInk, case .ready(let content) = states[page], content.ink != finalInk {
            inkChanged(on: page, finalInk, echoOf: nil)
        }
        withContent(page) { $0.retired = true }
    }

    /// Drops content for pages the runtime has retired, that are outside the
    /// window, and that are clean. History goes with the content.
    package func prune() {
        for (page, state) in states {
            guard case .ready(let content) = state, content.retired, !wanted.contains(page), !content.isDirty else { continue }
            states[page] = .unloaded
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
        return insertPage(after: after, geometry: template.geometry, paper: paper, answering: answering)
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
        return insertPage(after: after, geometry: sized, paper: resolved, answering: nil)
    }

    /// The one place a page is inserted, so anything every new page must do
    /// is written once.
    private func insertPage(after: PageID?, geometry: PageGeometry, paper: Paper, answering: ReportSeq?) -> PageID {
        let record = PageRecord(id: PageID(), geometry: geometry, paper: paper)
        var pages = index.pages
        if let after, let position = pages.firstIndex(where: { $0.id == after }) {
            pages.insert(record, at: position + 1)
        } else {
            pages.append(record)
        }
        index = index.withPages(pages)
        var content = PageContent(ink: PKDrawing(), layers: [], hasInk: false, inkIndex: 0)
        content.edited()
        states[record.id] = .ready(content)
        wanted.insert(record.id)
        indexSeq += 1
        emitStructure(answering: answering)
        emitContent(record.id)
        markDirty()
        rerenderComposite(of: record.id)
        return record.id
    }

    package func deletePage(_ page: PageID) {
        guard index.pages.count > 1, index.record(of: page) != nil else { return }
        index = index.withPages(index.pages.filter { $0.id != page })
        loads[page]?.cancel(); loads[page] = nil
        states[page] = nil
        wanted.remove(page)
        if currentPageID == page { currentPageID = index.pageIDs[0]; scheduleViewWrite() }
        indexSeq += 1
        emitStructure(answering: nil)
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

    // MARK: Composites

    /// Re-renders a page's backdrop after its layers or paper changed, or
    /// at a sharper scale on request. A result for a page no longer ready
    /// is dropped.
    package func rerenderComposite(of page: PageID, scale: CGFloat = Notebook.baseCompositeScale) {
        guard case .ready(let content) = states[page], let record = index.record(of: page) else { return }
        let layers = content.layers
        let renderer = self.renderer
        Task { [weak self] in
            guard let composite = await renderer.composite(geometry: record.geometry, paper: record.paper.paper, layers: layers, scale: scale) else { return }
            guard let self, case .ready = self.states[page] else { return }
            self.withContent(page) { $0.composite = composite }
            self.changes.append(.compositeUpdated(page, composite))
            self.onAsyncChange?()
        }
    }

    /// Called when a change lands outside an intention (a composite arrived,
    /// a load installed). The binding drains on it.
    @ObservationIgnored package var onAsyncChange: (@MainActor () -> Void)?

    package func detailNeeded(for page: PageID, scale: CGFloat) {
        guard case .ready(let content) = states[page], (content.composite?.scale ?? 0) < scale else { return }
        rerenderComposite(of: page, scale: scale)
    }

    // MARK: Layers

    /// Adds a layer beneath the ink. The asset, if any, is published first.
    package func addLayer(_ layer: Layer, assetData: Data?, on page: PageID) async throws(FormatFault) {
        guard case .ready = states[page] else { throw .invalidWrite("page \(page) is not ready") }
        do { _ = try layer.validated() } catch { throw .invalidWrite("layer invalid: \(error)") }
        if let asset = layer.payload.asset {
            guard let assetData else { throw .invalidWrite("layer names an asset with no bytes") }
            try await store.writeAsset(assetData, asset)
        }
        guard case .ready = states[page] else { throw .invalidWrite("page \(page) left ready during import") }
        withContent(page) { content in
            content.layers.insert(layer, at: content.inkIndex)
            content.inkIndex += 1
            content.pendingLayerFiles.insert(layer.id)
            content.edited()
        }
        markDirty()
        rerenderComposite(of: page)
    }

    /// An image, normalized to HEIC, placed centered at up to 60% of the
    /// page width, beneath the ink.
    package func importImage(_ data: Data, on page: PageID) async throws(FormatFault) {
        guard let normalized = await Task.detached(priority: .userInitiated, operation: { ImageImport.normalize(data) }).value else {
            throw .invalidWrite("image could not be decoded")
        }
        guard let record = index.record(of: page) else { throw .invalidWrite("no such page") }
        let fit = min(record.geometry.width * 0.6 / Double(normalized.size.width), record.geometry.height * 0.6 / Double(normalized.size.height))
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
            geometry: record.geometry, paper: record.paper.paper, layers: content.layers, ink: content.ink
        ) else { throw .invalidWrite("page \(page) could not be flattened") }
        let asset = AssetRef(id: AssetID(), format: .heic)
        try await store.writeAsset(heic, asset)
        return asset
    }

    package func addTextLayer(on page: PageID, rect: PageRect, runs: [TextRun]) async throws(FormatFault) {
        let layer = Layer(id: LayerID(), transform: .identity, payload: .text(TextLayer(rect: rect, runs: runs, alignment: .leading)))
        try await addLayer(layer, assetData: nil, on: page)
    }

    package func addLinkLayer(on page: PageID, rect: PageRect, target: LinkTarget) async throws(FormatFault) {
        let layer = Layer(id: LayerID(), transform: .identity, payload: .link(LinkLayer(rect: rect, style: .button, target: target)))
        try await addLayer(layer, assetData: nil, on: page)
    }

    package func transformLayer(on page: PageID, layer layerID: LayerID, to transform: PageSpaceTransform) -> TransformOutcome {
        guard case .ready(var content) = states[page] else { return .refused(reason: "page is not ready") }
        guard let position = content.layers.firstIndex(where: { $0.id == layerID }) else { return .refused(reason: "no such layer") }
        let moved = content.layers[position].withTransform(transform)
        do { _ = try moved.validated() } catch { return .refused(reason: "\(error)") }
        content.layers[position] = moved
        content.pendingLayerFiles.insert(layerID)
        content.edited()
        states[page] = .ready(content)
        markDirty()
        rerenderComposite(of: page)
        return .accepted
    }

    package func deleteLayer(_ layerID: LayerID, on page: PageID) {
        guard case .ready(var content) = states[page], let position = content.layers.firstIndex(where: { $0.id == layerID }) else { return }
        content.layers.remove(at: position)
        if position < content.inkIndex { content.inkIndex -= 1 }
        content.pendingLayerFiles.remove(layerID)
        content.edited()
        states[page] = .ready(content)
        markDirty()
        rerenderComposite(of: page)
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
                    content.pendingLayerFiles.subtract(item.layerFiles.map(\.id))
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
