import Foundation
import Observation
import TNCore
import TNFormat
import TNModel
import TNNotebook
import UIKit

/// One cell of the page navigator: what the grid draws before it has a
/// thumbnail, and what its fetch is keyed by.
package struct NavigatorPage: Identifiable, Sendable, Equatable {
    package let id: PageID
    package let geometry: PageGeometry
    /// The notebook's content version, the cell's `.task(id:)`.
    package let version: UInt64
    package let isCurrent: Bool
    /// False when it is the only page.
    package let isDeletable: Bool
    /// True while the notebook is loading the page. Part of the cell's task
    /// id, so the cell asks again when the load settles instead of the
    /// notebook polling its own state.
    package let isLoading: Bool
    /// The mark's title, or nil when the page is not marked. A read model,
    /// not a tri-state: nil is absence from the index's list, which is the
    /// presence-is-the-flag shape the durable side has, and `""` is a mark
    /// nobody named.
    package let bookmark: String?
}

/// What one open notebook looks like to the app: a canvas to put on
/// screen, a few observed facts to draw a toolbar from, and intentions.
///
/// Snapshots down, intentions up. Nothing here holds durable authority:
/// every method turns a tap into a notebook mutation and lets the drain
/// push the result to the runtime.
@MainActor @Observable
package final class EditorViewModel {
    @ObservationIgnored let notebook: Notebook
    @ObservationIgnored private let binding: EditorBinding

    /// The canvas, as a plain view controller. The app never names
    /// `TNCanvas`; the build would allow it, and ContractStructureTests
    /// refuses it.
    @ObservationIgnored package let canvasHost: UIViewController

    /// The active tool. Setting it applies to the runtime at once and tells
    /// the palette what to remember; the tool is the runtime's own state,
    /// held here only so the strip has something to render from.
    ///
    /// `private(set)`, so the intentions below are the only way to change
    /// it and the `didSet` is a boundary rather than a courtesy.
    package private(set) var tool: EditorTool {
        didSet {
            guard tool != oldValue else { return }
            binding.apply(environment)
            palette.remember(tool)
        }
    }

    /// The theme the workspace last told this tab. It travels with the
    /// tool, so a tool change never sends the runtime a stale one.
    @ObservationIgnored private var theme: Theme

    private var environment: CanvasEnvironment {
        CanvasEnvironment(tool: tool.canvasTool, theme: theme)
    }

    /// The presets, the recents, and the last kind, shared by every tab.
    @ObservationIgnored package let palette: ToolPalette

    // Mirrors, refreshed at the end of every drain. Undo availability is
    // not observable on the notebook — the history is ignored storage, as
    // it must be, or a stroke would invalidate every view.
    package private(set) var canUndo = false
    package private(set) var canRedo = false
    package private(set) var pageCount = 0
    package private(set) var currentPageIndex = 0
    /// Rebuilt on every drain like the others: a map over five-field structs
    /// per drain is cheaper than a flag that can be stale.
    package private(set) var navigatorPages: [NavigatorPage] = []

    /// The last refusal from a content change or an export. Cleared when
    /// the next one is attempted, and by `clearContentError()`.
    package internal(set) var lastContentError: FormatFault?

    /// Whether the notebook still owes the disk something. The save engine
    /// does not publish a write-in-flight flag, and a spinner keyed to one
    /// would flicker at every pass; this is "work outstanding".
    package var isSaving: Bool { notebook.dirtyPageCount > 0 }
    package var lastSaveError: SaveFailure? { notebook.lastSaveError }
    package var notebookID: NotebookID { notebook.notebookID }

    /// Drops what the renderer can rebuild, on memory pressure.
    package func purgeCaches() {
        let renderer = notebook.renderer
        Task { await renderer.purge() }
    }

    package convenience init(
        notebook: Notebook,
        palette: ToolPalette,
        theme: Theme,
        onLinkActivated: @escaping @MainActor (LinkTarget) -> Void
    ) {
        self.init(
            binding: EditorBinding(
                notebook: notebook,
                environment: CanvasEnvironment(tool: palette.currentTool.canvasTool, theme: theme),
                onLinkActivated: onLinkActivated
            ),
            palette: palette,
            theme: theme
        )
    }

    /// The designated initializer. Production passes the binding that made
    /// the runtime; a test passes one over a recording surface.
    package init(binding: EditorBinding, palette: ToolPalette, theme: Theme) {
        self.notebook = binding.notebook
        self.palette = palette
        self.tool = palette.currentTool
        self.theme = theme
        self.binding = binding
        self.canvasHost = binding.host
        binding.onDrained = { [weak self] in self?.refreshMirrors() }
        // The ink report, not the drain: a drain also runs for a page turn
        // and an undo, and neither is a colour anybody drew with.
        binding.onInkReported = { [weak self] in self?.inkReported() }
        // Asked, never copied: `didSet` does not run for the initial value,
        // and a second tab over the same palette would go stale anyway.
        binding.bindingsForStroke = { [weak self] in self?.strokeBindings ?? [:] }
        refreshMirrors()
        // `didSet` does not run for the initial value. The production runtime
        // was built with this environment and changes nothing; a recording
        // surface learns it here.
        binding.apply(environment)
    }

    /// The workspace resolved a theme. It goes down with the tool in hand,
    /// and the runtime sends the canvases no tool for it.
    package func apply(theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        binding.apply(environment)
    }

    private func refreshMirrors() {
        // While a box is open the buttons drive the text view's own manager,
        // whose depth is not reported up: a report per keystroke is what the
        // Structure rule forbids. So they stay enabled for the session.
        canUndo = notebook.canUndo || notebook.hasTextSession
        canRedo = notebook.canRedo || notebook.hasTextSession
        pageCount = notebook.pageCount
        guard let position = notebook.pageIDs.firstIndex(of: notebook.currentPageID) else {
            TNPrecondition.fail("the current page \(notebook.currentPageID) is not in the page list")
        }
        currentPageIndex = position
        let records = notebook.index.pages
        // `uniqueKeysWithValues` rather than a merge: two marks for one page
        // is an index `validated()` refuses, so it cannot be reached here,
        // and a silent merge would hide it if it ever were.
        let marks = Dictionary(uniqueKeysWithValues: notebook.index.bookmarks.map { ($0.page, $0.title) })
        navigatorPages = records.map { record in
            let isLoading: Bool
            if case .loading = notebook.state(of: record.id) { isLoading = true } else { isLoading = false }
            return NavigatorPage(
                id: record.id,
                geometry: record.geometry,
                version: notebook.contentVersion(of: record.id),
                isCurrent: record.id == notebook.currentPageID,
                isDeletable: records.count > 1,
                isLoading: isLoading,
                bookmark: marks[record.id]
            )
        }
    }

    // MARK: The tool

    // One call per tap, so the strip computes nothing. Each restores what
    // the palette holds rather than asking the view to carry it.

    package func select(_ kind: ToolPalette.Kind) {
        switch kind {
        case .ink(let ink): tool = palette.tool(for: ink)
        case .eraser: selectEraser()
        case .text: selectText()
        }
    }

    /// The eraser the palette last held, or, while an eraser is already in
    /// hand, the other one: a second tap is how the mode changes.
    package func selectEraser() {
        switch tool {
        case .eraseObject: tool = .erasePixel(palette.pixelEraserWidth)
        case .erasePixel: tool = .eraseObject
        case .ink, .text, .lasso: tool = palette.eraserTool
        }
    }

    /// The tool a kind's cap stands for: the one in hand when it is that
    /// kind, otherwise the one a tap restores. Each tab's editor holds its
    /// own tool over the one palette, so the palette can name an eraser
    /// mode this tab's eraser is not in.
    package func tool(for kind: ToolPalette.Kind) -> EditorTool {
        tool.kind == kind ? tool : palette.tool(for: kind)
    }

    package func selectLasso() { tool = .lasso }

    /// The text tool, typing with what the palette last typed with.
    package func selectText() { tool = palette.textTool }

    package func setTextStyle(_ style: TextStyle) {
        guard case .text(_, let alignment) = tool else {
            TNPrecondition.fail("a text style was set on \(tool), which has none")
        }
        tool = .text(style, alignment)
    }

    package func setTextAlignment(_ alignment: TextAlignment) {
        guard case .text(let style, _) = tool else {
            TNPrecondition.fail("a text alignment was set on \(tool), which has none")
        }
        tool = .text(style, alignment)
    }

    package func setWidth(_ width: ToolWidth) {
        switch tool {
        case .ink(let kind, let preset):
            tool = .ink(kind, InkPreset(color: preset.color, width: width))
        case .erasePixel, .eraseObject:
            // A width on the object eraser is how it becomes the eraser that
            // has one: one tool write, so the runtime and the palette hear
            // the pixel eraser once.
            tool = .erasePixel(width)
        case .lasso, .text:
            // `takesWidth` says no for these, so reaching here is a view
            // that offered a width the tool cannot take.
            TNPrecondition.fail("a width was set on \(tool), which takes none")
        }
    }

    package func setColor(_ color: ToolColor) {
        guard case .ink(let kind, let preset) = tool else {
            TNPrecondition.fail("a colour was set on \(tool), which has none")
        }
        tool = .ink(kind, InkPreset(color: color, width: preset.width))
    }

    /// A colour from the colour tray: into the hand, and over the swatch
    /// that opened the tray. No recent yet; the tray records the one colour
    /// it closes on.
    package func pick(_ color: ToolColor, over index: Int, of key: SwatchKey, in theme: Theme) {
        setColor(color)
        palette.replaceSwatch(at: index, with: color, for: key, in: theme)
    }

    /// The colour tray closed, and `color` is the last it picked.
    package func trayClosed(on color: ToolColor) {
        palette.picked(color)
    }

    /// The gestures that apply to a stroke drawn with the tool in hand. A
    /// gesture is a property of an ink stroke, so an eraser or a lasso pass
    /// is never examined; which ink kind it is makes no difference.
    private var strokeBindings: GestureBindings {
        guard case .ink = tool else { return [:] }
        return palette.gestures
    }

    /// Binds a Pencil gesture to an effect, or unbinds it when `effect` is
    /// nil. One set of bindings, shared by every ink kind and every tab.
    package func bind(_ trigger: GestureTrigger, to effect: GestureEffect?) {
        palette.bind(trigger, to: effect)
    }

    /// A stroke landed, so the colour it landed in is one the person drew
    /// with. An eraser or a lasso report carries no colour.
    private func inkReported() {
        guard let color = tool.color else { return }
        palette.used(color)
    }

    // MARK: History

    package func undo() { binding.undoRequested() }
    package func redo() { binding.redoRequested() }

    // MARK: Pages

    // A new page at a chosen size. The four say which paper; `append` below
    // is the one that talks to the notebook.

    /// The paper the boundary pull would have given it: the current page's
    /// drawn paper, which the notebook decides and nothing here restates.
    package func addPage(size: PageSize, orientation: PageOrientation) async {
        await append(size, orientation, .inheritTemplate)
    }

    package func addPage(size: PageSize, orientation: PageOrientation, paper: DrawnPaper) async {
        await append(size, orientation, .drawn(paper))
    }

    /// The new page takes another page's asset paper: the chosen width, the
    /// asset's aspect.
    package func addPage(size: PageSize, orientation: PageOrientation, paperFrom page: PageID) async {
        guard let paper = notebook.paper(of: page), paper.isAsset else {
            lastContentError = .invalidWrite("page \(page) has no asset paper to take")
            return
        }
        await append(size, orientation, .asset(paper))
    }

    /// A photo becomes the new page's paper. The asset is published first,
    /// so the append that follows only has to measure it.
    package func addPage(size: PageSize, orientation: PageOrientation, photo data: Data) async {
        guard let stored = await contentChange({ () async throws(FormatFault) in try await notebook.storeImageAsset(data) }) else { return }
        await append(size, orientation, .asset(.image(stored)))
    }

    /// This page, flattened, becomes the new page's paper: the composite and
    /// the ink rendered to one asset at asset resolution. The source is
    /// untouched — flattening in place would lose it, and the contract says
    /// flatten does not change the source — and it records nothing, so the
    /// undo stack is as it was and the append is navigation like any other.
    ///
    /// Its own name rather than a fifth `addPage` overload: the others take
    /// the thing the paper comes from, and this one takes nothing, since the
    /// source is always the page the reader is on.
    package func addPageFlatteningCurrentPage(size: PageSize, orientation: PageOrientation) async {
        guard let flattened = await contentChange({ () async throws(FormatFault) in try await notebook.flatten(notebook.currentPageID) }) else { return }
        await append(size, orientation, .asset(.image(flattened)))
    }

    /// A refused append creates nothing, so there is nothing to take the
    /// reader to.
    private func append(_ size: PageSize, _ orientation: PageOrientation, _ paper: NewPagePaper) async {
        let created = await contentChange { () async throws(FormatFault) -> PageID in
            guard let geometry = size.geometry(orientation) else { throw Self.sizeOutOfBounds }
            do throws(NewPageRefusal) {
                return try await notebook.appendPage(after: notebook.currentPageID, geometry: geometry, paper: paper)
            } catch {
                throw Self.fault(error)
            }
        }
        if let created { binding.surface.scroll(to: created) }
    }

    /// The sheet refuses a size `geometry(_:)` returns nil for before it
    /// offers to create anything; this is the same refusal, stated for a
    /// caller that got here anyway.
    private static let sizeOutOfBounds = FormatFault.invalidWrite(
        "page size is outside \(EditorViewModel.bounds) points")

    /// `%g` rather than interpolation: `minEdge` is derived and prints its
    /// binary tail as `137.60000000000002`.
    private static let bounds = String(format: "%g to %g", PageBounds.minEdge, PageBounds.maxEdge)

    /// `lastContentError` is a `FormatFault`, the one channel a refused
    /// content change speaks through, so an append's refusal joins it.
    private static func fault(_ refusal: NewPageRefusal) -> FormatFault {
        switch refusal {
        case .geometryOutOfBounds(let width, let height):
            .invalidWrite("page \(width) x \(height) is outside \(Self.bounds) points")
        case .assetUnreadable(let asset):
            .invalidWrite("paper asset \(asset.fileName) could not be read")
        case .pageGone(let page):
            .invalidWrite("page \(page), which the new page was to follow, is gone")
        }
    }


    /// A new page after `page`, and the reader is taken to it. It inherits
    /// the current page's paper and geometry, not `page`'s: that is what
    /// `appendPage` copies today, and the navigator's label says so.
    package func addPage(after page: PageID) {
        commitTextEditing()
        var created: PageID?
        binding.intention { created = notebook.appendPage(after: page) }
        if let created { binding.surface.scroll(to: created) }
    }

    /// A copy of `page`, straight after it, and the reader is taken to it.
    /// The notebook reads an unloaded source from its files, so a cell in the
    /// navigator can be duplicated without being visited first.
    package func duplicatePage(_ page: PageID) async {
        guard let created = await contentChange({ () async throws(FormatFault) in try await notebook.duplicatePage(page) }) else { return }
        binding.surface.scroll(to: created)
    }

    /// The only page cannot be deleted, because a notebook with no pages has
    /// no state to return to. The notebook ignores the request; the refusal
    /// is said here, in `lastContentError`, and changes nothing, an open
    /// text box included.
    package func deletePage(_ page: PageID) {
        lastContentError = nil
        guard notebook.pageCount > 1 else {
            lastContentError = .invalidWrite("the only page can't be deleted")
            return
        }
        commitTextEditing()
        binding.intention { notebook.deletePage(page) }
    }

    /// False when the notebook has one page, the one `deletePage` refuses.
    package var canDeleteCurrentPage: Bool { pageCount > 1 }

    package func deleteCurrentPage() { deletePage(notebook.currentPageID) }

    // MARK: Bookmarks

    /// Marks the page, or renames a mark it already has. An empty title is a
    /// mark nobody named; the outline shows that page's number instead.
    ///
    /// Two calls rather than one taking `String?`: an optional there would be
    /// a command argument shaped like a durable value, and removing a mark is
    /// not naming it nothing.
    package func bookmark(_ page: PageID, titled title: String) {
        binding.intention { notebook.bookmark(page, titled: title) }
    }

    package func removeBookmark(_ page: PageID) {
        binding.intention { notebook.removeBookmark(page) }
    }

    /// Pixels for a navigator cell, keyed by the page's content version.
    /// Cancelled with the cell's task; nil while the page is loading or when
    /// it is unreadable.
    package func thumbnail(of page: PageID) async -> CGImage? {
        await notebook.thumbnail(of: page)
    }

    /// `page` goes before `target`, or to the end when `target` is nil.
    ///
    /// Three drops leave the order as it is and stop here, because the
    /// notebook would otherwise rewrite and save an unchanged index, and a
    /// self-drop would send the page to the end (`Notebook.movePage` removes
    /// the page first, then fails to find it as the target). A drop on the
    /// page's own next neighbour, and the last page dropped past the end,
    /// are the other two; `next == nil` when the page is last, so the one
    /// comparison covers both.
    package func movePage(_ page: PageID, before target: PageID?) {
        let pages = notebook.pageIDs
        guard let from = pages.firstIndex(of: page) else { return }
        let next = pages.indices.contains(from + 1) ? pages[from + 1] : nil
        if target == page || target == next { return }
        binding.intention { notebook.movePage(page, before: target) }
    }

    package var currentPaper: Paper? { notebook.paper(of: notebook.currentPageID) }

    /// The pages a new page could take its asset paper from, each with its
    /// place in the notebook, which is what a row is labelled by. A page
    /// whose state is `.unreadable` is omitted: `paper(of:)` reads the index,
    /// so such a row would offer an asset that can only fail.
    package var pagesWithAssetPaper: [(page: PageID, number: Int)] {
        notebook.pageIDs.enumerated().compactMap { position, page -> (page: PageID, number: Int)? in
            guard notebook.paper(of: page)?.isAsset == true else { return nil }
            if let state = notebook.state(of: page), case .unreadable = state { return nil }
            return (page, position + 1)
        }
    }

    /// The current page's size as the catalogue names it, which is what a
    /// creation sheet opens on: a page added without asking is the size of
    /// the one it follows.
    package var currentPageSize: (size: PageSize, orientation: PageOrientation) {
        PageSize.matching(notebook.currentRecord.geometry)
    }

    /// Drawn paper on the current page; a photo is `setPaper(photo:)`. A
    /// page whose paper is a PDF page or a photo keeps it, and the refusal
    /// is in `lastContentError`. The notebook refuses drawn paper for no
    /// other reason than a page it does not hold, which the current page
    /// cannot be.
    package func setPaper(_ paper: DrawnPaper) async {
        await contentChange { () async throws(FormatFault) in
            do throws(PaperRefusal) {
                try await notebook.setPaper(.drawn(paper), on: notebook.currentPageID)
            } catch {
                guard error == .pageHasAssetPaper else {
                    TNPrecondition.fail("drawn paper on the current page was refused: \(error)")
                }
                throw .invalidWrite("paper refused: \(error)")
            }
        }
    }

    /// False for a page this notebook does not hold, which the runtime
    /// would trap on; a link names pages from anywhere.
    @discardableResult
    package func scroll(to page: PageID) -> Bool {
        guard notebook.pageIDs.contains(page) else { return false }
        binding.surface.scroll(to: page)
        return true
    }

    // MARK: Content

    /// Every content change's shape: the last refusal clears, an open text
    /// box commits, the notebook acts, and the drain pushes what it did.
    /// Returns what the act made, or nil when it was refused, and the
    /// refusal is in `lastContentError`. A closure handed here spells out
    /// `throws(FormatFault)`, because a literal that does not loses it and
    /// the catch binds `any Error`.
    @discardableResult
    private func contentChange<Made>(_ act: () async throws(FormatFault) -> Made) async -> Made? {
        lastContentError = nil
        commitTextEditing()
        var made: Made?
        do { made = try await act() } catch { lastContentError = error }
        binding.drain()
        return made
    }

    /// The person has seen the refusal. The export sheet calls this as it
    /// closes, because it showed the refusal itself.
    package func clearContentError() { lastContentError = nil }

    package func importImage(_ data: Data) async {
        await contentChange { () async throws(FormatFault) in try await notebook.importImage(data, on: notebook.currentPageID) }
    }

    /// A photo as the current page's paper. The notebook refuses a page that
    /// has ink or layers on it before it stores anything, because asset paper
    /// covers the whole page; the refusal reaches the bar through
    /// `lastContentError` like any other.
    package func setPaper(photo data: Data) async {
        await contentChange { () async throws(FormatFault) in try await notebook.importImageAsPaper(data, on: notebook.currentPageID) }
    }

    /// One new page per PDF page, after the current one, and the reader is
    /// taken to the first of them.
    package func importPDF(_ data: Data) async {
        await importPages { () async throws(FormatFault) in try await notebook.importPDF(data) }
    }

    package func addLink(to target: LinkTarget) async {
        await contentChange { () throws(FormatFault) in
            let rect = Self.defaultRect(width: Self.linkSize.width, height: Self.linkSize.height, on: notebook.currentRecord.geometry)
            try notebook.addLinkLayer(on: notebook.currentPageID, rect: rect, target: target)
        }
    }

    /// An open text box commits before anything is inserted, a page added,
    /// duplicated or deleted, or an export read, so the session's entry
    /// lands before the insert's and an export has what was typed. Called
    /// inside each method rather than by the row that asks, because the
    /// navigator reaches the same methods as the band.
    package func commitTextEditing() { binding.commitTextEditing() }

    /// The inset is a page point count, not a fraction: a new box sits the
    /// same distance from the corner whatever the page's size.
    private static let defaultInset: Double = 48

    /// A new link's button, in page points.
    private static let linkSize = (width: 160.0, height: 44.0)

    private static func defaultRect(width: Double, height: Double, on available: PageGeometry) -> PageRect {
        let inset = min(Self.defaultInset, available.width / 4, available.height / 4)
        return PageRect(
            x: inset, y: inset,
            width: min(width, available.width - 2 * inset),
            height: min(height, available.height - 2 * inset)
        )
    }

    // MARK: Capture

    /// A scan: one new page per scanned page, after the current one, and the
    /// reader is taken to the first of them. An empty array is a cancel and
    /// makes nothing.
    package func importScan(_ images: [Data]) async {
        await importPages { () async throws(FormatFault) in try await notebook.importScan(images) }
    }

    /// An import lands the reader on the first page it made, so it reads
    /// from its beginning rather than from its end the way Add Page leaves
    /// it. A refused import makes nothing, and a scan that stops partway
    /// hands back nothing, so the reader stays where they were while the bar
    /// says what happened; the pages a stopped scan did make are already
    /// in the notebook and pushed by the drain.
    private func importPages(_ make: () async throws(FormatFault) -> [PageID]) async {
        guard let first = await contentChange(make)?.first else { return }
        binding.surface.scroll(to: first)
    }

    // MARK: Export

    // The walk is `EditorExport.swift`. Its state is stored here, because an
    // extension holds none, so the setters are the module's.

    /// Owner: this view model, like the other mirrors. Non-nil from the
    /// start of a walk until the sheet clears it. Not on the notebook,
    /// whose observed surface is five properties.
    package internal(set) var exportProgress: ExportProgress?
    /// Owner: this view model, until the sheet closes. Pixels and PDF, not
    /// ink: nothing here is a second copy of a drawing.
    package internal(set) var exportedFile: ExportedFile?
    @ObservationIgnored var exportTask: Task<Void, Never>?

    // MARK: Durability

    package func flush() async { await notebook.flush() }

    /// The app left the foreground.
    package func endToolUses() { binding.endToolUses() }

    /// Close: the runtime is torn down and lets go of every page first,
    /// then the notebook runs its final pass. A refused close leaves the
    /// runtime torn down until the close is retried or the notebook
    /// discarded.
    package func close() async -> CloseOutcome {
        let deferred = binding.retireAll()
        // However long the Pencil stays down: that stroke is not in custody
        // until its report arrives, and the torn-down runtime builds nothing
        // while this waits. A use nothing can touch was already ended by the
        // teardown, and a pen's commit is bounded, so only a stroke on screen
        // is waited for. A 10 ms poll, only during a close.
        while !binding.hasRetired(deferred) { try? await Task.sleep(for: .milliseconds(10)) }
        binding.drain()
        return await notebook.close()
    }
}
