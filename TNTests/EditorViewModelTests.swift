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
        let thickRedPencil = EditorTool.ink(.pencil, InkPreset(color: .red, width: .thick))
        let (scratch, book) = try await notebook("vm-last-tool")
        let editor = EditorViewModel(notebook: book, palette: palette(lastTool: thickRedPencil)) { _ in }

        #expect(editor.tool == thickRedPencil)
        withExtendedLifetime(scratch) {}
    }

    @Test("A tab opens on text if text was last, and the text intentions change only the text tool")
    func textToolIntentions() async throws {
        let bold = TextStyle(font: "system", size: 24, bold: true, italic: false, underline: false, color: TextStyle.body.color)
        let (scratch, book) = try await notebook("vm-text")
        let editor = EditorViewModel(notebook: book, palette: palette(lastTool: .text(bold, .center))) { _ in }
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

    @Test("Two tabs over one palette open on the same tool")
    func twoTabsOpenOnTheSameTool() async throws {
        let eraser = EditorTool.erasePixel(.thin)
        let shared = palette(lastTool: eraser)
        let (firstScratch, first) = try await notebook("vm-two-tabs-a")
        let (secondScratch, second) = try await notebook("vm-two-tabs-b")

        let one = EditorViewModel(notebook: first, palette: shared) { _ in }
        let two = EditorViewModel(notebook: second, palette: shared) { _ in }

        #expect(one.tool == eraser)
        #expect(two.tool == eraser)
        withExtendedLifetime((firstScratch, secondScratch)) {}
    }

    @Test("Selecting a kind restores the colour and width that kind was last used at")
    func selectingAKindRestoresItsSlot() async throws {
        let (scratch, book) = try await notebook("vm-select-kind")
        let shared = ToolPalette(store: MemoryPaletteStore())
        let editor = EditorViewModel(notebook: book, palette: shared) { _ in }

        editor.select(kind: .highlighter)
        editor.setColor(.purple)
        editor.setWidth(.thin)
        #expect(editor.tool == .ink(.highlighter, InkPreset(color: .purple, width: .thin)))

        editor.select(kind: .pen)
        #expect(editor.tool == .ink(.pen, InkPreset(color: .black, width: .medium)))

        editor.select(kind: .highlighter)
        #expect(editor.tool == .ink(.highlighter, InkPreset(color: .purple, width: .thin)))
        withExtendedLifetime(scratch) {}
    }

    @Test("The eraser restores its mode, and the lasso is not remembered")
    func theEraserRestoresItsModeAndTheLassoIsNot() async throws {
        let (scratch, book) = try await notebook("vm-eraser")
        let shared = ToolPalette(store: MemoryPaletteStore())
        let editor = EditorViewModel(notebook: book, palette: shared) { _ in }

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
        return (scratch, book, EditorViewModel(binding: binding, palette: ToolPalette(store: MemoryPaletteStore())))
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
        let editor = EditorViewModel(binding: EditorBinding(notebook: book, surface: RecordingSurface()), palette: ToolPalette(store: MemoryPaletteStore()))
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
