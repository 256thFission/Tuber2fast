import Foundation
import PDFKit
import Testing
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

/// The view model's half of the tool: which one a tab opens on, and what
/// each intention does to it.
///
/// These assert `editor.tool`, and at most the environment a recording
/// surface was told. That the tool reaches a live canvas is proven hosted:
/// `EditorFlowTests` from the view model, `TNCanvasRuntimeTests` for every
/// canvas the runtime holds or builds.
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
        let bold = TextStyle(font: .system, size: 24, bold: true, italic: false, underline: false, color: TextStyle.body.color)
        let (scratch, book) = try await notebook("vm-text")
        let editor = EditorViewModel(notebook: book, palette: palette(lastTool: .text(bold, .center)), theme: .macaron) { _ in }
        #expect(editor.tool == .text(bold, .center))

        editor.select(.ink(.pen))
        editor.selectText()
        #expect(editor.tool == .text(bold, .center), "selectText restores the last style and alignment")

        let red = TextStyle(font: .system, size: 24, bold: true, italic: false, underline: false, color: RGBA8(red: 200, green: 0, blue: 0, alpha: 255))
        editor.setTextStyle(red)
        #expect(editor.tool == .text(red, .center))
        editor.setTextAlignment(.trailing)
        #expect(editor.tool == .text(red, .trailing))
        #expect(editor.palette.text == TextPreset(style: red, alignment: .trailing))
        #expect(editor.palette.recentColors.isEmpty, "a colour typed with is never a recent")
        withExtendedLifetime(scratch) {}
    }

    @Test("Every size the text tool offers is one a run may be committed at")
    func textSizesAreValid() {
        #expect(!TextPreset.sizes.isEmpty)
        for size in TextPreset.sizes {
            #expect(TextRun(string: "x", style: TextStyle.body.with(size: size)).isValid, "\(size)")
        }
    }

    @Test("A size and an alignment chosen for the text tool reach the runtime")
    func aStyleChoiceReachesTheCanvas() async throws {
        let (scratch, book) = try await notebook("vm-text-choice")
        let surface = RecordingSurface()
        let editor = EditorViewModel(
            binding: EditorBinding(notebook: book, surface: surface),
            palette: ToolPalette(store: MemoryPaletteStore()),
            theme: .macaron
        )
        editor.selectText()
        let large = TextStyle.body.with(size: 24)

        editor.setTextStyle(large)
        #expect(surface.environments.last?.tool == .text(large, .leading))
        editor.setTextAlignment(.center)
        #expect(surface.environments.last?.tool == .text(large, .center))
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

        editor.select(.ink(.highlighter))
        #expect(binding.bindingsForStroke() == [.scribble: .erase], "every ink kind gestures")

        editor.select(.ink(.pen))
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
        editor.select(.ink(.highlighter))
        editor.setColor(violet)
        editor.setWidth(.thin)
        #expect(editor.tool == .ink(.highlighter, InkPreset(color: violet, width: .thin)))

        editor.select(.ink(.pen))
        #expect(editor.tool == .ink(.pen, InkPreset(color: .black, width: .medium)))

        editor.select(.ink(.highlighter))
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

    @Test("A width on the object eraser makes the pixel eraser, in one tool write")
    func aWidthOnTheObjectEraserMakesThePixelEraser() async throws {
        let (scratch, book) = try await notebook("vm-eraser-width")
        let surface = RecordingSurface()
        let store = MemoryPaletteStore()
        let editor = EditorViewModel(
            binding: EditorBinding(notebook: book, surface: surface),
            palette: ToolPalette(store: store),
            theme: .macaron
        )
        editor.selectEraser()
        #expect(editor.tool == .eraseObject)
        let told = surface.environments.count
        let saves = store.saves

        editor.setWidth(.thin)

        #expect(editor.tool == .erasePixel(.thin))
        #expect(surface.environments.count == told + 1, "the runtime hears the pixel eraser once")
        #expect(store.saves == saves + 1, "the palette writes once")
        #expect(store.stored?.eraserMode == .pixel)
        #expect(store.stored?.pixelEraserWidth == .thin)
        withExtendedLifetime(scratch) {}
    }

    @Test("A second tap on the eraser switches its mode both ways, and a first tap restores the last mode")
    func aSecondEraserTapSwitchesMode() async throws {
        let (scratch, book) = try await notebook("vm-eraser-mode")
        let shared = ToolPalette(store: MemoryPaletteStore())
        shared.remember(.erasePixel(.thick))
        shared.remember(.ink(.pen, InkPreset(color: .black, width: .medium)))
        let editor = EditorViewModel(notebook: book, palette: shared, theme: .macaron) { _ in }

        editor.selectEraser()
        #expect(editor.tool == .erasePixel(.thick), "a first tap takes the mode the palette last held")

        editor.selectEraser()
        #expect(editor.tool == .eraseObject)
        #expect(shared.eraserMode == .object)
        #expect(shared.pixelEraserWidth == .thick, "the pixel width waits for the way back")

        editor.selectEraser()
        #expect(editor.tool == .erasePixel(.thick))

        editor.selectEraser()
        editor.select(.ink(.pencil))
        editor.select(.eraser)
        #expect(editor.tool == .eraseObject, "coming back from a pen restores the mode, it does not switch it")
        withExtendedLifetime(scratch) {}
    }

    @Test("A cap in hand shows that tab's tool, not the eraser mode another tab saved")
    func aHeldCapShowsItsOwnTabsTool() async throws {
        let shared = ToolPalette(store: MemoryPaletteStore())
        let (firstScratch, first) = try await notebook("vm-cap-a")
        let (secondScratch, second) = try await notebook("vm-cap-b")
        let one = EditorViewModel(notebook: first, palette: shared, theme: .macaron) { _ in }
        let two = EditorViewModel(notebook: second, palette: shared, theme: .macaron) { _ in }

        one.selectEraser()
        one.setWidth(.thick)
        two.selectEraser()
        two.selectEraser()
        #expect(shared.eraserMode == .object)

        #expect(one.tool(for: .eraser) == .erasePixel(.thick))
        #expect(two.tool(for: .eraser) == .eraseObject)

        one.selectEraser()
        #expect(one.tool(for: .eraser) == .eraseObject, "the second tap shows the mode it switched to")

        two.select(.ink(.pen))
        #expect(two.tool(for: .eraser) == shared.eraserTool, "a cap not in hand shows what a tap restores")
        #expect(two.tool(for: .ink(.highlighter)) == shared.tool(for: .highlighter))
        withExtendedLifetime((firstScratch, secondScratch)) {}
    }
}

/// Export: what the sheet's intentions do to the properties it draws from,
/// and that the pages handed to the renderer are the ones asked for, with
/// their ink and their paper. How a page is drawn is the renderer's own
/// suite.
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
        editor.export(.pdf(pages: 1...1))
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

    @Test("Pages 2-3 export the worksheet and the ink on each, an unloaded page read from its files, and the export changes nothing")
    func exportCarriesInkAndWorksheet() async throws {
        let (scratch, book, editor) = try await editor("vm-export-content")
        try await ready(book)
        // Ink on the first page, so the PDF follows it rather than taking its
        // place, and the range has a page before it to leave out.
        book.inkChanged(on: book.pageIDs[0], Ink.drawing(strokes: 1), echoOf: nil)
        await editor.importPDF(try Fixture.pdfData(pages: 2))
        try #require(book.pageCount == 3)
        let (worksheet, unloaded) = (book.pageIDs[1], book.pageIDs[2])
        for page in [worksheet, unloaded] { book.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil) }
        await book.flush()
        book.windowChanged(to: [worksheet])
        book.retired(unloaded, finalInk: nil)
        book.prune()
        guard case .unloaded = book.state(of: unloaded) else { Issue.record("the last page should be unloaded"); return }
        let couldUndo = book.canUndo

        editor.export(.pdf(pages: 2...3))
        try await waitUntil { editor.exportedFile != nil }

        #expect(editor.lastContentError == nil)
        let data = try #require(editor.exportedFile?.data)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 2)
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index)?.pageRef)
            #expect(page.getBoxRect(.mediaBox).size == CGSize(width: 400, height: 600), "page \(index + 2) is the worksheet's size, not the first page's")
            let scale = 2.0
            let image = try rasterized(page, scale: scale)
            // The stroke runs from x 10 to 70 at y 10, inside the worksheet's
            // white 20-point margin; the worksheet fills the rest.
            #expect(luminance(of: image, x: Int(40 * scale), y: Int(10 * scale)) < 128, "the ink on page \(index + 2)")
            #expect(luminance(of: image, x: image.width / 2, y: image.height / 2) < 200, "the worksheet on page \(index + 2)")
        }
        #expect(!book.isDirty, "exporting marks nothing dirty")
        #expect(book.canUndo == couldUndo, "and records nothing")
        if case .unloaded = book.state(of: unloaded) {} else { Issue.record("the export loaded the page it read") }
        _ = await editor.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("The current page exports as a PNG that carries its ink")
    func exportImageCarriesInk() async throws {
        let (scratch, book, editor) = try await editor("vm-export-image")
        try await ready(book)
        let page = book.currentPageID
        book.inkChanged(on: page, Ink.drawing(strokes: 1), echoOf: nil)
        editor.export(.currentPageImage)
        try await waitUntil { editor.exportedFile != nil }
        #expect(editor.exportedFile?.kind == .png)
        let data = try #require(editor.exportedFile?.data)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "the PNG signature")
        let image = try redrawn(png: data)
        let geometry = try #require(book.index.record(of: page)).geometry
        let scale = Double(image.width) / geometry.width
        // The fixture stroke runs from x 10 to 70 at y 10, in page points.
        #expect(luminance(of: image, x: Int(40 * scale), y: Int(10 * scale)) < 128)
        #expect(luminance(of: image, x: image.width / 2, y: image.height / 2) == 255)
        _ = await editor.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("A range outside the notebook is refused and nothing is rendered")
    func aRangeOutsideTheNotebookIsRefused() async throws {
        let (scratch, book, editor) = try await editor("vm-export-range")
        try await ready(book)
        // A one-page notebook: page 0 does not exist, and neither do 3 and 4.
        for range in [0...1, 3...4] {
            editor.export(.pdf(pages: range))
            #expect(editor.lastContentError != nil, "\(range) is outside 1...\(editor.pageCount)")
            #expect(editor.exportProgress == nil, "nothing was asked of the renderer")
            #expect(editor.exportedFile == nil)
        }
        editor.clearContentError()
        #expect(editor.lastContentError == nil, "the sheet that showed the refusal clears it as it closes")
        _ = await editor.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("A cancel while a page's files are read leaves no progress, no file, and no refusal")
    func cancellingAnExportRefusesNothing() async throws {
        let scratch = try Scratch("vm-export-cancel")
        let store = GatedLoadStore(try await PackageStore.create(root: scratch.packageURL, index: Fixture.index(pages: 1)))
        let book = try await Notebook.open(store: store, schedule: fast)
        let editor = EditorViewModel(binding: EditorBinding(notebook: book, surface: RecordingSurface()), palette: ToolPalette(store: MemoryPaletteStore()), theme: .macaron)
        guard case .unloaded = book.state(of: book.pageIDs[0]) else { Issue.record("the page should be unloaded, so the walk reads its files"); return }
        editor.export(.pdf(pages: 1...1))
        #expect(editor.exportProgress != nil, "the walk started")
        try await book.waitForArrivals(store.gate, 1)
        editor.cancelExport()
        await store.gate.release(0)
        // The read the cancel cut short comes back empty; the walk it belonged
        // to cannot come back with a file, a walk, or a refusal.
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.exportProgress == nil)
        #expect(editor.exportedFile == nil)
        #expect(editor.lastContentError == nil, "the page is readable; the person asked the walk to stop")
        _ = await editor.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("A page refused for its missing worksheet refuses the export, rather than going out as ink on blank paper")
    func anUnreadablePageIsNotExported() async throws {
        let scratch = try Scratch("vm-export-unreadable")
        let made = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        try await made.importPDF(try Fixture.pdfData(pages: 1))
        let worksheet = made.pageIDs[1]
        guard case .pdf(let asset, _) = try #require(made.paper(of: worksheet)) else { Issue.record("not PDF paper"); return }
        made.inkChanged(on: worksheet, Ink.drawing(strokes: 1), echoOf: nil)
        await made.flush()
        _ = await made.close()
        let store = PackageStore(root: scratch.packageURL)
        try FileManager.default.removeItem(at: store.layout.assetURL(asset))

        let book = try await Notebook.open(store: store, schedule: fast)
        guard case .unreadable = book.state(of: worksheet) else { Issue.record("the page with no worksheet should be refused"); return }
        #expect(await book.revision(of: worksheet) == nil, "its page files decode, and the page is still refused")
        let editor = EditorViewModel(binding: EditorBinding(notebook: book, surface: RecordingSurface()), palette: ToolPalette(store: MemoryPaletteStore()), theme: .macaron)
        editor.export(.pdf(pages: 1...2))
        try await waitUntil { editor.exportProgress == nil || editor.exportedFile != nil }
        #expect(editor.exportedFile == nil)
        #expect(editor.lastContentError == .invalidWrite("page 2 couldn't be read"))
        _ = await editor.close()
        withExtendedLifetime(scratch) {}
    }

    @Test("An export with a text box open commits the box first, and the PDF has what was typed")
    func exportCommitsAnOpenTextBoxFirst() async throws {
        let scratch = try Scratch("vm-export-text")
        let book = try await Notebook.create(at: scratch.packageURL, schedule: fast)
        let surface = RecordingSurface()
        let binding = EditorBinding(notebook: book, surface: surface)
        surface.reporter = binding
        let editor = EditorViewModel(binding: binding, palette: ToolPalette(store: MemoryPaletteStore()), theme: .macaron)
        try await ready(book)
        let page = book.currentPageID
        let box = try await openBox(on: page, typing: "answer", in: book, surface)

        editor.export(.pdf(pages: 1...1))
        #expect(!book.hasTextSession, "the box was committed before anything was read")
        #expect(typedText(in: box, on: page, of: book) == "answer")
        try await waitUntil { editor.exportedFile != nil }
        #expect(editor.lastContentError == nil)
        let pdf = try #require(editor.exportedFile?.data)
        let text = try #require(PDFDocument(data: pdf)?.page(at: 0)).string ?? ""
        #expect(text.contains("answer"), "the typed words, extracted from the PDF: \(text)")
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
        let binding = EditorBinding(notebook: notebook, surface: surface)
        surface.reporter = binding
        let editor = EditorViewModel(binding: binding, palette: ToolPalette(store: MemoryPaletteStore()), theme: .macaron)
        return (scratch, notebook, surface, editor)
    }

    @Test("An insert with a text box open commits the box first, and its entry lands under the insert's")
    func insertCommitsAnOpenTextBoxFirst() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-insert-commits")
        let page = notebook.pageIDs[0]
        let box = try await openBox(on: page, typing: "answer", in: notebook, surface)
        #expect(editor.canUndo && editor.canRedo, "the buttons drive the typing while the box is open")

        await editor.importImage(try Fixture.imageData(width: 40, height: 30))
        #expect(editor.lastContentError == nil)
        #expect(!notebook.hasTextSession)
        #expect(typedText(in: box, on: page, of: notebook) == "answer")
        #expect(notebook.state(of: page)?.content?.layers.count == 2)

        editor.undo()
        #expect(notebook.state(of: page)?.content?.layers.map(\.id) == [box], "one undo takes the image and leaves the words")
        #expect(typedText(in: box, on: page, of: notebook) == "answer")
        editor.undo()
        #expect(notebook.state(of: page)?.content?.layers.isEmpty == true, "the box and its words are the next step")
        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("An image or a link asked for while the canvas is still opening a box is refused, so nothing lands before the session's entry")
    func insertWhileABoxIsOpeningIsRefused() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-insert-opening")
        let page = notebook.pageIDs[0]
        notebook.createTextBox(on: page, at: PagePoint(x: 40, y: 40), style: .body, alignment: .leading)
        #expect(surface.openBox == nil, "the picture that leaves the box out has not landed")

        // The link goes first: the box can come up during the image's
        // awaits, and a commit after that ends the session and lets a link land.
        await editor.addLink(to: .internalPage(page))
        #expect(editor.lastContentError != nil)
        await editor.importImage(try Fixture.imageData(width: 40, height: 30))
        #expect(editor.lastContentError != nil)
        #expect(notebook.state(of: page)?.content?.layers.count == 1, "only the box")
        #expect(!notebook.canUndo, "nothing was recorded ahead of the session")

        try await waitUntil { surface.openBox != nil }
        editor.commitTextEditing()
        #expect(!notebook.hasTextSession)
        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A page added or deleted with a text box open commits the box first")
    func addOrDeletePageCommitsAnOpenTextBoxFirst() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-page-commits")
        let page = notebook.pageIDs[0]
        let first = try await openBox(on: page, typing: "first", in: notebook, surface)

        await editor.addPage(size: .letter, orientation: .portrait)
        #expect(editor.lastContentError == nil)
        #expect(!notebook.hasTextSession)
        #expect(typedText(in: first, on: page, of: notebook) == "first")
        #expect(notebook.pageCount == 2)
        let committed = try #require(surface.calls.lastIndex(of: .commitTextEditing))
        let scrolled = try #require(surface.calls.lastIndex { if case .scroll = $0 { true } else { false } })
        #expect(committed < scrolled, "the box closed before the reader was taken away from it")

        _ = try await openBox(on: page, typing: "second", in: notebook, surface)
        editor.deleteCurrentPage()
        #expect(!notebook.hasTextSession)
        #expect(surface.openBox == nil, "the box reported its words before its page went")
        #expect(notebook.pageCount == 1 && !notebook.pageIDs.contains(page), "the page with the box was the current one")
        let recommitted = try #require(surface.calls.lastIndex(of: .commitTextEditing))
        let dropped = try #require(surface.calls.lastIndex { if case .setPages(let ids, _, _) = $0 { !ids.contains(page) } else { false } })
        #expect(recommitted < dropped)
        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
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

    @Test("A PDF lands after a page with ink on it, and the reader is taken to its first page")
    func importingAPDFLandsOnItsFirstPage() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-pdf-lands")
        let first = notebook.pageIDs[0]
        notebook.inkChanged(on: first, Ink.drawing(strokes: 1), echoOf: nil)

        await editor.importPDF(try Fixture.pdfData(pages: 2))

        #expect(editor.lastContentError == nil)
        #expect(notebook.pageCount == 3)
        #expect(notebook.pageIDs.first == first, "a page with ink on it is kept")
        let made = Array(notebook.pageIDs.dropFirst())
        #expect(surface.pagesSet.last == [first] + made)
        #expect(surface.calls.last { if case .scroll = $0 { true } else { false } } == .scroll(made[0]))

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A PDF imported into an untouched one-page notebook takes the blank page's place")
    func importingIntoAnUntouchedNotebookReplacesTheBlankPage() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-pdf-replaces")
        let blank = notebook.pageIDs[0]

        await editor.importPDF(try Fixture.pdfData(pages: 3))

        #expect(editor.lastContentError == nil)
        let made = notebook.pageIDs
        #expect(made.count == 3)
        #expect(!made.contains(blank))
        for (offset, page) in made.enumerated() {
            guard case .pdf(_, let sourcePageIndex) = try #require(notebook.paper(of: page)) else {
                Issue.record("page \(page) is not PDF paper"); continue
            }
            #expect(sourcePageIndex == offset)
        }
        #expect(notebook.currentPageID == made[0])
        #expect(surface.pagesSet.last == made)
        #expect(surface.calls.last { if case .scroll = $0 { true } else { false } } == .scroll(made[0]))

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A PDF with a page outside the bounds is refused whole: no page, no push, no asset, nothing owed")
    func aPDFWithAPageOutsideTheBoundsMakesNothing() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-pdf-bounds")
        let pages = notebook.pageIDs
        await notebook.flush()
        #expect(!notebook.isDirty)
        let ordersBefore = surface.pagesSet
        let assets = scratch.packageURL.appendingPathComponent("assets").path
        let assetsBefore = (try? FileManager.default.contentsOfDirectory(atPath: assets)) ?? []

        await editor.importPDF(try Fixture.shapedPDF(sizes: [CGSize(width: 400, height: 600), CGSize(width: 5000, height: 600)]))

        #expect(editor.lastContentError == .invalidWrite("PDF page 2 is outside the page bounds"))
        #expect(notebook.pageIDs == pages)
        #expect(notebook.pageCount == pages.count)
        #expect(surface.pagesSet == ordersBefore)
        #expect(!notebook.isDirty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: assets)) ?? []) == assetsBefore)

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

        // Appending pages is navigation: `insertPages` records nothing.
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
        // The canvas is told about the pages the stopped run made, and they
        // are owed to the disk.
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

    @Test("Drawn paper on a PDF page is refused, and the index is as it was")
    func drawnPaperOnAPDFPageIsRefused() async throws {
        let (scratch, notebook, _, editor) = try await loaded("vm-paper-pdf-drawn")
        await editor.importPDF(try Fixture.pdfData(pages: 1))
        let page = notebook.currentPageID
        guard case .pdf = try #require(notebook.paper(of: page)) else {
            Issue.record("the current page is not PDF paper"); return
        }
        await notebook.flush()
        let before = notebook.index

        await editor.setPaper(.lined)

        #expect(editor.lastContentError == .invalidWrite("paper refused: pageHasAssetPaper"))
        #expect(notebook.index == before)
        #expect(!notebook.isDirty)

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("A photo on an empty PDF page is refused, and nothing is written")
    func photoPaperOnAPDFPageIsRefused() async throws {
        let (scratch, notebook, _, editor) = try await loaded("vm-paper-pdf-photo")
        await editor.importPDF(try Fixture.pdfData(pages: 1))
        let page = notebook.currentPageID
        // Loaded and empty, so its paper is the one reason left to refuse.
        notebook.windowChanged(to: [page])
        try await waitUntil { notebook.state(of: page)?.content != nil }
        let paper = try #require(notebook.paper(of: page))
        let assets = scratch.packageURL.appendingPathComponent("assets").path
        let assetsBefore = Set(try FileManager.default.contentsOfDirectory(atPath: assets))

        await editor.setPaper(photo: try Fixture.imageData(width: 200, height: 100))

        #expect(editor.lastContentError == .invalidWrite("paper refused: pageHasAssetPaper"))
        #expect(notebook.paper(of: page) == paper)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: assets)) == assetsBefore)

        withExtendedLifetime(scratch) {}
        _ = await notebook.close()
    }

    @Test("Deleting the only page is refused with a reason and changes nothing; the next delete clears it")
    func deletingTheOnlyPageSaysWhy() async throws {
        let (scratch, notebook, surface, editor) = try await loaded("vm-delete-only")
        let page = notebook.pageIDs[0]
        #expect(!editor.canDeleteCurrentPage)
        let callsBefore = surface.calls.count

        editor.deleteCurrentPage()

        #expect(editor.lastContentError == .invalidWrite("the only page can't be deleted"))
        #expect(notebook.pageIDs == [page])
        #expect(surface.calls.count == callsBefore, "nothing was committed or pushed")

        editor.addPage(after: page)
        #expect(editor.canDeleteCurrentPage)
        #expect(editor.lastContentError == .invalidWrite("the only page can't be deleted"))
        editor.deleteCurrentPage()
        #expect(editor.lastContentError == nil)
        #expect(notebook.pageCount == 1)

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

/// A box opened on `page` as a text-tool tap opens one, with `typed` in it
/// and nothing committed: the begin has landed on the surface, which holds
/// the draft the way the runtime's overlay does.
@MainActor
private func openBox(on page: PageID, typing typed: String, in notebook: Notebook, _ surface: RecordingSurface) async throws -> LayerID {
    notebook.createTextBox(on: page, at: PagePoint(x: 40, y: 40), style: .body, alignment: .leading)
    try await waitUntil { surface.openBox != nil }
    surface.type(typed)
    return try #require(surface.openBox?.layer)
}

/// The words the notebook holds in `layer`, or nil when it holds no such
/// text layer.
@MainActor
private func typedText(in layer: LayerID, on page: PageID, of notebook: Notebook) -> String? {
    let found = notebook.state(of: page)?.content?.layers.first { $0.id == layer }
    guard case .text(let text) = found?.payload else { return nil }
    return text.runs.map(\.string).joined()
}
