import Foundation
import Testing
@testable import TNEditor
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
            palette: ToolPalette(store: MemoryPaletteStore())
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
