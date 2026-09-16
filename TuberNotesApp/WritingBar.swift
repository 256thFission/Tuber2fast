import SwiftUI
import TNEditor
import TNModel

/// The four instruments, in the order the design fixes them: pen, pencil,
/// highlighter, eraser. No fifth, ever.
enum Instrument: CaseIterable {
    case pen, pencil, highlighter, eraser

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        }
    }

    var label: String {
        switch self {
        case .pen: "Pen"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        }
    }

    init?(_ tool: EditorTool) {
        switch tool {
        case .ink(.pen, _): self = .pen
        case .ink(.pencil, _): self = .pencil
        case .ink(.highlighter, _): self = .highlighter
        case .eraseObject, .erasePixel: self = .eraser
        case .lasso, .text: return nil
        }
    }

    @MainActor func take(_ editor: EditorViewModel) {
        switch self {
        case .pen: editor.select(kind: .pen)
        case .pencil: editor.select(kind: .pencil)
        case .highlighter: editor.select(kind: .highlighter)
        case .eraser: editor.selectEraser()
        }
    }
}

/// The instruments as keycaps. The one in hand is sunk into its own wall,
/// which is the entire selected state.
struct InstrumentRun: View {
    let editor: EditorViewModel
    @Environment(\.macaron) private var theme

    var body: some View {
        ForEach(Instrument.allCases, id: \.self) { instrument in
            let isHeld = Instrument(editor.tool) == instrument
            Keycap(fill: isHeld ? theme.accent : theme.chrome, isHeld: isHeld) {
                instrument.take(editor)
            } label: {
                Image(systemName: instrument.symbol).font(Macaron.body(16))
            }
            .accessibilityLabel(instrument.label)
            .accessibilityAddTraits(isHeld ? .isSelected : [])
        }
    }
}
