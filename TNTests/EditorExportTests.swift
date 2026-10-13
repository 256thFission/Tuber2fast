import Foundation
import PDFKit
import Testing
@testable import TNEditor
@testable import TNFormat
@testable import TNModel
@testable import TNNotebook

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
