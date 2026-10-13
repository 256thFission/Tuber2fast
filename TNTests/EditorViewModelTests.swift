import Foundation
import Testing
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

/// The view model's half of the tool: which one a tab opens on, and what
/// each intention does to it.
///
/// These assert `editor.tool`, never the environment the runtime saw. That
/// the runtime is told, and that every live canvas hears it, is the hosted
/// suite's job.
@Suite("Editor view model: the tool")
@MainActor
struct EditorViewModelTests {
    private func notebook(_ name: String) async throws -> (Scratch, Notebook) {
        let scratch = try Scratch(name)
        return (scratch, try await Notebook.create(at: scratch.packageURL, schedule: fast))
    }

    private func palette(lastTool: EditorTool) -> ToolPalette {
        let palette = ToolPalette(store: MemoryPaletteStore())
        palette.remember(lastTool)
        return palette
    }

    @Test("A tab opens on the tool the palette last held")
    func aTabOpensOnTheLastTool() async throws {
        let scarlet = ToolColor(rgba: RGBA8(red: 0xC4, green: 0x29, blue: 0x29, alpha: 0xFF))
        let thickRedPencil = EditorTool.ink(.pencil, InkPreset(color: scarlet, width: .thick))
        let (scratch, book) = try await notebook("vm-last-tool")
        let editor = EditorViewModel(notebook: book, palette: palette(lastTool: thickRedPencil), theme: .macaron) { _ in }

        #expect(editor.tool == thickRedPencil)
        withExtendedLifetime(scratch) {}
    }

    @Test("A tab opens on text if text was last, and the text intentions change only the text tool")
    func textToolIntentions() async throws {
        let bold = TextStyle(font: "system", size: 24, bold: true, italic: false, underline: false, color: TextStyle.body.color)
        let (scratch, book) = try await notebook("vm-text")
        let editor = EditorViewModel(notebook: book, palette: palette(lastTool: .text(bold, .center)), theme: .macaron) { _ in }
        #expect(editor.tool == .text(bold, .center))

        editor.select(kind: .pen)
        editor.selectText()
        #expect(editor.tool == .text(bold, .center), "selectText restores the last style and alignment")

        let red = TextStyle(font: "system", size: 24, bold: true, italic: false, underline: false, color: RGBA8(red: 200, green: 0, blue: 0, alpha: 255))
        editor.setTextStyle(red)
        #expect(editor.tool == .text(red, .center))
        editor.setTextAlignment(.trailing)
        #expect(editor.tool == .text(red, .trailing))
        #expect(editor.palette.text == TextPreset(style: red, alignment: .trailing))
        #expect(editor.palette.recentColors.isEmpty, "a colour typed with is never a recent")
        withExtendedLifetime(scratch) {}
    }

    @Test("The gestures the binding asks for follow the tool in hand and the palette")
    func gesturesFollowTheToolAndThePalette() async throws {
        let (scratch, book) = try await notebook("vm-gestures")
        let binding = EditorBinding(notebook: book, surface: RecordingSurface())
        let shared = ToolPalette(store: MemoryPaletteStore())
        let editor = EditorViewModel(binding: binding, palette: shared, theme: .macaron)

        // Nothing has been selected yet, and `didSet` does not run for the
        // initial value: a tab that opens on the pen still gestures like one.
        #expect(editor.tool == shared.currentTool)
        #expect(binding.bindingsForStroke() == [.scribble: .erase])

        editor.selectEraser()
        #expect(binding.bindingsForStroke().isEmpty, "an eraser pass is never a gesture")

        editor.select(kind: .highlighter)
        #expect(binding.bindingsForStroke() == [.scribble: .erase], "every ink kind gestures")

        editor.select(kind: .pen)
        editor.bind(.scribble, to: nil)
        #expect(shared.gestures.isEmpty, "the intention went to the palette")
        #expect(binding.bindingsForStroke().isEmpty, "the closure reads the palette, it does not hold a copy")
        withExtendedLifetime(scratch) {}
    }

    @Test("A theme the workspace sets reaches the runtime with the tool in hand, and a tool change keeps it")
    func theThemeReachesTheRuntimeWithTheTool() async throws {
        let (scratch, book) = try await notebook("vm-theme")
        let surface = RecordingSurface()
        let editor = EditorViewModel(
            binding: EditorBinding(notebook: book, surface: surface),
            palette: ToolPalette(store: MemoryPaletteStore()),
            theme: .macaron
        )
        #expect(surface.environments.last?.theme == .macaron)

        editor.apply(theme: .macaronDark)
        #expect(surface.environments.last?.theme == .macaronDark)
        #expect(surface.environments.last?.tool == editor.tool.canvasTool)

        editor.selectEraser()
        #expect(surface.environments.last?.theme == .macaronDark)

        let told = surface.environments.count
        editor.apply(theme: .macaronDark)
        #expect(surface.environments.count == told, "a theme restated sends nothing")
        withExtendedLifetime(scratch) {}
    }

    @Test("Two tabs over one palette open on the same tool")
    func twoTabsOpenOnTheSameTool() async throws {
        let eraser = EditorTool.erasePixel(.thin)
        let shared = palette(lastTool: eraser)
        let (firstScratch, first) = try await notebook("vm-two-tabs-a")
        let (secondScratch, second) = try await notebook("vm-two-tabs-b")

        let one = EditorViewModel(notebook: first, palette: shared, theme: .macaron) { _ in }
        let two = EditorViewModel(notebook: second, palette: shared, theme: .macaron) { _ in }

        #expect(one.tool == eraser)
        #expect(two.tool == eraser)
        withExtendedLifetime((firstScratch, secondScratch)) {}
    }

    @Test("Selecting a kind restores the colour and width that kind was last used at")
    func selectingAKindRestoresItsSlot() async throws {
        let (scratch, book) = try await notebook("vm-select-kind")
        let shared = ToolPalette(store: MemoryPaletteStore())
        let editor = EditorViewModel(notebook: book, palette: shared, theme: .macaron) { _ in }

        let violet = ToolColor(rgba: RGBA8(red: 0x7A, green: 0x3F, blue: 0xC4, alpha: 0xFF))
        editor.select(kind: .highlighter)
        editor.setColor(violet)
        editor.setWidth(.thin)
        #expect(editor.tool == .ink(.highlighter, InkPreset(color: violet, width: .thin)))

        editor.select(kind: .pen)
        #expect(editor.tool == .ink(.pen, InkPreset(color: .black, width: .medium)))

        editor.select(kind: .highlighter)
        #expect(editor.tool == .ink(.highlighter, InkPreset(color: violet, width: .thin)))
        withExtendedLifetime(scratch) {}
    }

    @Test("The eraser restores its mode, and the lasso is not remembered")
    func theEraserRestoresItsModeAndTheLassoIsNot() async throws {
        let (scratch, book) = try await notebook("vm-eraser")
        let shared = ToolPalette(store: MemoryPaletteStore())
        let editor = EditorViewModel(notebook: book, palette: shared, theme: .macaron) { _ in }

        editor.selectEraser()
        #expect(editor.tool == .eraseObject)
        editor.setEraserMode(.pixel)
        editor.setWidth(.thick)
        #expect(editor.tool == .erasePixel(.thick))

        editor.selectLasso()
        #expect(editor.tool == .lasso)
        // The lasso left no trace, so the eraser is still what the palette
        // opens on and still the eraser the person was using.
        #expect(shared.lastKind == .eraser)
        editor.selectEraser()
        #expect(editor.tool == .erasePixel(.thick))
        withExtendedLifetime(scratch) {}
    }
}

/// Export: what the sheet's four intentions do to the two properties it
/// draws from. That the PDF is a PDF is the renderer's own suite; this one
/// is about refusals, progress, and cancellation.
@Suite("Editor view model: export")
@MainActor
struct EditorViewModelExportTests {
    /// Over a `RecordingSurface`, not the runtime: these tests put pages in
    /// the window so custody has something to export, and a real
    /// `PagedCanvasController` builds a live canvas per page for a window
    /// it is told about. Such a canvas traps when it is released without
    /// its final ink report, which is the contract doing its job — a test
    /// bundle with no host app and no Pencil cannot deliver one. The
    /// export path itself names neither the binding nor the canvas host.
    private func editor(_ name: String) async throws -> (Scratch, Notebook, EditorViewModel) {
        let scratch = try Scratch(name)
        let book = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let binding = EditorBinding(notebook: book, surface: RecordingSurface())
        return (scratch, book, EditorViewModel(binding: binding, palette: ToolPalette(store: MemoryPaletteStore()), theme: .macaron))
    }

    /// Every page in the window and loaded, so an export reads custody.
    private func ready(_ book: Notebook) async throws {
        book.windowChanged(to: book.pageIDs)
        try await waitUntil { book.pageIDs.allSatisfy { book.state(of: $0)?.content != nil } }
    }

    @Test("One page exports to a PDF and the walk ends where it started counting")
    func onePageExports() async throws {
        let (scratch, book, editor) = try await editor("vm-export-one")
        try await ready(book)
        editor.exportPDF(pages: 1...1)
        try await waitUntil { editor.exportedFile != nil }
        #expect(editor.exportedFile?.kind == .pdf)
        #expect(editor.exportProgress == EditorViewModel.ExportProgress(done: 1, total: 1))
        #expect(editor.lastContentError == nil)
        #expect(editor.exportedFile?.data.starts(with: Array("%PDF".utf8)) == true)
        editor.clearExport()
        #expect(editor.exportedFile == nil && editor.exportProgress == nil)
        _ = await editor.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("The current page exports as a PNG")
    func currentPageExportsAsImage() async throws {
        let (scratch, book, editor) = try await editor("vm-export-image")
        try await ready(book)
        editor.exportCurrentPageImage()
        try await waitUntil { editor.exportedFile != nil }
        #expect(editor.exportedFile?.kind == .png)
        #expect(editor.exportedFile?.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true, "the PNG signature")
        _ = await editor.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("A range outside the notebook is refused and nothing is rendered")
    func aRangeOutsideTheNotebookIsRefused() async throws {
        let (scratch, book, editor) = try await editor("vm-export-range")
        try await ready(book)
        // A one-page notebook: page 0 does not exist, and neither do 3 and 4.
        for range in [0...1, 3...4] {
            editor.exportPDF(pages: range)
            #expect(editor.lastContentError != nil, "\(range) is outside 1...\(editor.pageCount)")
            #expect(editor.exportProgress == nil, "nothing was asked of the renderer")
            #expect(editor.exportedFile == nil)
        }
        _ = await editor.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("A cancel during a page's load leaves no progress and no file")
    func cancelDuringALoadLeavesNothing() async throws {
        let scratch = try Scratch("vm-export-cancel")
        let store = HeldLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let book = try await Notebook.open(store: store, schedule: fast)
        let editor = EditorViewModel(binding: EditorBinding(notebook: book, surface: RecordingSurface()), palette: ToolPalette(store: MemoryPaletteStore()), theme: .macaron)
        await store.hold()
        editor.exportPDF(pages: 1...1)
        #expect(editor.exportProgress != nil, "the walk started")
        editor.cancelExport()
        #expect(editor.exportProgress == nil)
        #expect(editor.exportedFile == nil)
        await store.release()
        // The walk it cancelled cannot come back and install a file.
        try await Task.sleep(for: .milliseconds(50))
        #expect(editor.exportedFile == nil)
        _ = await editor.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("An export while a text box is open is refused, and the history is untouched")
    func anOpenTextBoxRefusesAnExport() async throws {
        let (scratch, book, editor) = try await editor("vm-export-text")
        try await ready(book)
        let page = book.currentPageID
        book.createTextBox(on: page, at: PagePoint(x: 40, y: 40), style: .body, alignment: .leading)
        #expect(book.hasTextSession(on: page))
        let canUndo = editor.canUndo
        editor.exportPDF(pages: 1...1)
        #expect(editor.lastContentError != nil)
        #expect(editor.exportProgress == nil && editor.exportedFile == nil)
        #expect(editor.canUndo == canUndo)
        _ = await editor.close()
        withExtendedLifetime(scratch) {}
    }
}

/// The view model's content intentions, over a surface that records instead
/// of drawing. What a test asserts here is the notebook's state and the
/// vocabulary the runtime was pushed: pixels are the renderer's suite.
@Suite("Editor view model: content")
@MainActor
struct EditorViewModelContentTests {
    /// A one-page notebook with that page loaded, and an editor over a
    /// recording surface.
    private func loaded(_ name: String) async throws -> (Scratch, Notebook, RecordingSurface, EditorViewModel) {
        let scratch = try Scratch(name)
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let page = notebook.pageIDs[0]
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let surface = RecordingSurface()
        let editor = EditorViewModel(
            binding: EditorBinding(notebook: notebook, surface: surface),
            palette: ToolPalette(store: MemoryPaletteStore()),
            theme: .macaron
        )
        return (scratch, notebook, surface, editor)
    }

    @Test("A photo becomes the current page's paper, and the page takes the photo's aspect")
    func photoBecomesThePaper() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-paper-photo")
        let page = notebook.pageIDs[0]
        let ordersBefore = surface.pagesSet.count

        await editor.setPaper(photo: try Fixture.imageData(width: 200, height: 100))

        #expect(editor.lastContentError == nil)
        guard case .image = try #require(notebook.paper(of: page)) else {
            Issue.record("the paper is not an image"); return
        }
        // The asset fills the page rectangle, so the rectangle is the asset's
        // shape at the page's width.
        #expect(notebook.index.record(of: page)?.geometry == PageGeometry(width: 612, height: 306))
        #expect(surface.pagesSet.count > ordersBefore, "the geometry changed, so the order is restated")
        try await waitUntil { surface.calls.contains(.updateComposite(page)) }

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("This page flattened becomes the new page's paper, and the source is untouched")
    func flattenedPageBecomesTheNextPagesPaper() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-flatten")
        let source = notebook.pageIDs[0]
        let layer = Fixture.imageLayer()
        try await notebook.addLayer(layer, assetData: try Fixture.imageData(width: 40, height: 30), on: source)
        notebook.inkChanged(on: source, Ink.drawing(strokes: 2), echoOf: nil)
        let ink = try #require(notebook.state(of: source)?.content?.ink)
        let couldUndo = notebook.canUndo

        await editor.addPageFlatteningCurrentPage(size: .letter, orientation: .portrait)

        #expect(editor.lastContentError == nil)
        #expect(notebook.pageCount == 2)
        let created = try #require(notebook.pageIDs.last)
        guard case .image(let asset) = try #require(notebook.paper(of: created)) else {
            Issue.record("the new page's paper is not an image"); return
        }
        #expect(try await notebook.store.readAsset(asset).count > 0)

        // The source keeps its ink and its layer, and flattening records
        // nothing, so the stack is where it was.
        #expect(notebook.state(of: source)?.content?.ink == ink)
        #expect(notebook.state(of: source)?.content?.layers.map(\.id) == [layer.id])
        #expect(notebook.paper(of: source) == .drawn(.blank))
        #expect(notebook.canUndo == couldUndo)

        let order = try #require(surface.calls.lastIndex { if case .setPages(let ids, _, _) = $0 { ids.contains(created) } else { false } })
        let scroll = try #require(surface.calls.lastIndex(of: .scroll(created)))
        #expect(scroll > order)

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A link is one layer, one history entry, and it reaches the runtime")
    func addingALink() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-link")
        let page = notebook.pageIDs[0]
        let target = LinkTarget.externalPage(notebook: NotebookID(), page: PageID())

        await editor.addLink(to: target)

        #expect(editor.lastContentError == nil)
        let layers = try #require(notebook.state(of: page)?.content?.layers)
        #expect(layers.count == 1)
        guard case .link(let link) = try #require(layers.first).payload else {
            Issue.record("the layer is not a link"); return
        }
        #expect(link.target == target)
        #expect(notebook.canUndo, "minting a link is an edit, and it is on the stack")
        try await waitUntil { surface.layersSeen[page]?.map(\.id) == [layers[0].id] }

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("Duplicating a page pushes the new order, its content, and takes the reader to it")
    func duplicatingAPagePushesAndScrolls() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-duplicate")
        let source = notebook.pageIDs[0]
        notebook.inkChanged(on: source, Ink.drawing(strokes: 1), echoOf: nil)

        await editor.duplicatePage(source)

        #expect(editor.lastContentError == nil)
        let copy = try #require(notebook.pageIDs.last)
        #expect(notebook.pageIDs == [source, copy])

        let order = try #require(surface.calls.lastIndex { if case .setPages(let ids, _, _) = $0 { ids == [source, copy] } else { false } })
        let installed = try #require(surface.calls.lastIndex(of: .installContent(copy, editable: true)))
        let scroll = try #require(surface.calls.lastIndex(of: .scroll(copy)))
        #expect(order < installed)
        #expect(installed < scroll)

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A bookmark reaches `navigatorPages` through the drain with no structure change")
    func aBookmarkReachesTheMirrors() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-bookmark")
        let page = notebook.pageIDs[0]
        let callsBefore = surface.calls.count
        #expect(editor.navigatorPages.first?.bookmark == nil)

        editor.bookmark(page, titled: "Chapter one")

        // This is the whole mechanism: `intention` drains whether or not the
        // mutation queued anything, and the drain refreshes the mirrors, so a
        // mark needs no `NotebookChange` case and no `emitStructure`.
        #expect(editor.navigatorPages.first?.bookmark == "Chapter one")
        #expect(surface.calls.count == callsBefore, "a mark sends the runtime nothing")

        editor.bookmark(page, titled: "")
        #expect(editor.navigatorPages.first?.bookmark == "", "a mark nobody named is still a mark")

        editor.removeBookmark(page)
        #expect(editor.navigatorPages.first?.bookmark == nil)
        #expect(surface.calls.count == callsBefore)

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A scan becomes one page per scanned page, in order, each taking the scan's aspect")
    func scanBecomesPages() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-scan")
        let first = notebook.pageIDs[0]
        let couldUndo = notebook.canUndo

        await editor.importScan([
            try Fixture.imageData(width: 200, height: 100),
            try Fixture.imageData(width: 100, height: 200),
            try Fixture.imageData(width: 300, height: 300),
        ])

        #expect(editor.lastContentError == nil)
        #expect(notebook.pageCount == 4)
        #expect(notebook.pageIDs.first == first, "the scan lands after the page it was started from")
        let made = Array(notebook.pageIDs.dropFirst())

        // The page keeps the width it was scanned into and takes the scan's
        // shape, the way asset paper is measured everywhere else.
        let geometries = made.map { notebook.index.record(of: $0)?.geometry }
        #expect(geometries == [
            PageGeometry(width: 612, height: 306),
            PageGeometry(width: 612, height: 1224),
            PageGeometry(width: 612, height: 612),
        ])

        for page in made {
            guard case .image(let asset) = try #require(notebook.paper(of: page)) else {
                Issue.record("a scanned page's paper is not an image"); return
            }
            #expect(try await notebook.store.readAsset(asset).count > 0)
        }

        // The reader lands on the first page made, so a scan reads from its
        // beginning, and the order reaches the runtime before the scroll does.
        let order = try #require(surface.calls.lastIndex { if case .setPages(let ids, _, _) = $0 { ids.contains(made[0]) } else { false } })
        let scroll = try #require(surface.calls.lastIndex(of: .scroll(made[0])))
        #expect(scroll > order)
        #expect(!surface.calls.contains(.scroll(made[2])), "the first page made, not the last")

        // Appending pages is navigation: `insertPage` records nothing.
        #expect(notebook.canUndo == couldUndo)

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A scan lands after the current page, not before it and not at the end")
    func scanLandsAfterTheCurrentPage() async throws {
        let (scratch, notebook, _, editor) = try await loaded("vm-scan-after")
        let first = notebook.pageIDs[0]
        let last = notebook.appendPage()
        #expect(notebook.currentPageID == first, "the reader is still on page 1")

        await editor.importScan([
            try Fixture.imageData(width: 200, height: 100),
            try Fixture.imageData(width: 100, height: 200),
            try Fixture.imageData(width: 300, height: 300),
        ])

        #expect(editor.lastContentError == nil)
        #expect(notebook.pageCount == 5)
        #expect(notebook.pageIDs.first == first)
        #expect(notebook.pageIDs.last == last)

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A scanned page that will not decode stops the run, and what was made is kept and owed to the disk")
    func scanStopsOnAPageThatWillNotDecode() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-scan-refused")
        let first = notebook.pageIDs[0]
        await notebook.flush()
        #expect(!notebook.isDirty, "the notebook starts clean, so the dirt below is the scan's")

        await editor.importScan([
            try Fixture.imageData(width: 200, height: 100),
            Data("not an image".utf8),
            try Fixture.imageData(width: 300, height: 300),
        ])

        #expect(editor.lastContentError != nil)
        // The page before the bad one is kept; nothing after it is made.
        #expect(notebook.pageCount == 2)
        let made = try #require(notebook.pageIDs.last)
        #expect(notebook.pageIDs == [first, made])
        // The half `importPDF` drops: the canvas is told about the pages the
        // stopped run made, and they are owed to the disk.
        #expect(surface.pagesSet.last == [first, made])
        #expect(notebook.isDirty)

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A cancelled scan makes no page, reports nothing, and takes the reader nowhere")
    func aCancelledScanDoesNothing() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-scan-cancel")
        let ordersBefore = surface.pagesSet.count
        let scrollsBefore = surface.calls.count { if case .scroll = $0 { true } else { false } }

        await editor.importScan([])

        #expect(editor.lastContentError == nil)
        #expect(notebook.pageCount == 1)
        #expect(surface.pagesSet.count == ordersBefore)
        #expect(surface.calls.count { if case .scroll = $0 { true } else { false } } == scrollsBefore)

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A page with ink refuses a photo as its paper, and nothing is written")
    func photoIsRefusedOnAPageWithInk() async throws {
        let (scratch, notebook, _, editor) = try await loaded("vm-paper-photo-refused")
        let page = notebook.pageIDs[0]
        notebook.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)

        await editor.setPaper(photo: try Fixture.imageData(width: 200, height: 100))

        #expect(editor.lastContentError != nil)
        #expect(notebook.paper(of: page) == .drawn(.blank))
        // The refusal is decided before the photo is stored, so the asset
        // directory is as empty as it was.
        let assets = try FileManager.default.contentsOfDirectory(
            atPath: scratch.packageURL.appendingPathComponent("assets").path
        )
        #expect(assets.isEmpty)

        _ = await notebook.close()
    }
}

/// Leaving the foreground and closing, over a recording surface that can
/// defer a retire the way a stroke on screen does.
@Suite("Editor view model: lifecycle")
@MainActor
struct EditorViewModelLifecycleTests {
    /// A one-page notebook with its page in the window and loaded. The
    /// binding is the test's, so the test can report a deferred retire.
    private func opened(_ name: String) async throws -> (Scratch, Notebook, RecordingSurface, EditorBinding, EditorViewModel) {
        let scratch = try Scratch(name)
        let notebook = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: notebook, surface: surface)
        let editor = EditorViewModel(binding: binding, palette: ToolPalette(store: MemoryPaletteStore()), theme: .macaron)
        let page = notebook.pageIDs[0]
        binding.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        return (scratch, notebook, surface, binding, editor)
    }

    /// The page's stroke count as a fresh open reads it from disk.
    private func strokesOnDisk(_ scratch: Scratch, _ page: PageID) async throws -> Int? {
        let reopened = try await Notebook.open(store: PackageStore(root: scratch.packageURL), schedule: fast)
        reopened.windowChanged(to: [page])
        try await waitUntil { reopened.state(of: page)?.content != nil }
        let count = reopened.state(of: page)?.content?.ink.strokes.count
        _ = await reopened.close()
        return count
    }

    @Test("Close waits for a deferred retire, however long, and saves the ink it carries")
    func closeWaitsForTheStroke() async throws {
        let (scratch, notebook, surface, binding, editor) = try await opened("vm-close-stroke")
        let page = notebook.pageIDs[0]
        surface.deferring = [page]

        let closing = Task { await editor.close() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!notebook.isClosed, "the stroke is not in custody yet")

        binding.retired(page, finalInk: Ink.drawing(strokes: 2))
        #expect(await closing.value == .clean)
        #expect(try await strokesOnDisk(scratch, page) == 2)
    }

    @Test("A page retired earlier in the session and deferred at close is waited for again")
    func closeWaitsForAPageRetiredEarlier() async throws {
        let (scratch, notebook, surface, binding, editor) = try await opened("vm-close-earlier")
        let page = notebook.pageIDs[0]
        // A turn away retires the page and drops it; the turn back loads it
        // again, and its canvas is new.
        binding.retired(page, finalInk: nil)
        binding.windowChanged(to: [])
        binding.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        surface.deferring = [page]

        let closing = Task { await editor.close() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!notebook.isClosed, "the earlier retire is not this close's")

        binding.retired(page, finalInk: Ink.drawing(strokes: 2))
        #expect(await closing.value == .clean)
        #expect(try await strokesOnDisk(scratch, page) == 2)
    }

    @Test("Leaving the foreground tells the runtime to end the tool uses nothing can touch")
    func leavingTheForegroundEndsToolUses() async throws {
        let (scratch, notebook, surface, _, editor) = try await opened("vm-foreground")
        editor.endToolUses()
        #expect(surface.calls.last == .endToolUses)
        _ = await notebook.close()
        withExtendedLifetime(scratch) {}
    }
}
