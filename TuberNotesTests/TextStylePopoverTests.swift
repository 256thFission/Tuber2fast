import Foundation
import Testing
@testable import TNEditor
@testable import TNModel
@testable import TNNotebook
@testable import TuberNotes

/// A palette that keeps nothing between launches.
private struct Unsaved: ToolPaletteStore {
    func load() -> ToolPaletteRecord? { nil }
    func save(_ record: ToolPaletteRecord) {}
}

/// The Aa bubble's choices, which read the tool at the tap.
@Suite("The text style bubble")
@MainActor
struct TextStylePopoverTests {
    @Test("A choice that lands after the tool has left text does nothing; with text in hand it restyles")
    func aChoiceOffTheTextToolDoesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notebook = try await Notebook.create(at: directory.appending(path: "Scratch.tubernotes"), schedule: fast)
        let editor = EditorViewModel(notebook: notebook, palette: ToolPalette(store: Unsaved()), theme: .macaron) { _ in }
        let bubble = TextStylePopover(editor: editor)

        // The editor traps on both of these for any tool but text.
        editor.selectLasso()
        bubble.restyle { $0.with(size: 24) }
        bubble.align(.center)
        #expect(editor.tool == .lasso)

        editor.selectText()
        bubble.restyle { $0.with(size: 24, bold: true) }
        bubble.align(.center)
        #expect(editor.tool == .text(TextStyle.body.with(size: 24, bold: true), .center))
        #expect(await editor.close() == .clean)
    }
}
