import SwiftUI
import TNLibrary
import TNModel
import UIKit

/// What a colour and a symbol are called. The durable names are English
/// already, but a raw value is not a label: `FolderSymbol.school` is stored
/// as `graduationcap.fill`, which is not a word anyone wants read out. This
/// is the one home for both lists, as `PageNames` is for sizes and paper.
enum FolderStyleNames {
    static func color(_ color: FolderColor) -> String {
        switch color {
        case .neutral: "Default"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        }
    }

    static func symbol(_ symbol: FolderSymbol) -> String {
        switch symbol {
        case .folder: "Folder"
        case .star: "Star"
        case .heart: "Heart"
        case .book: "Book"
        case .briefcase: "Briefcase"
        case .school: "School"
        }
    }
}

/// A folder's colour and symbol: a row of swatches over a grid of glyphs,
/// with the folder as it will look above them. The sheet chooses; the store
/// writes.
struct FolderStyleSheet: View {
    @Environment(\.dismiss) private var dismiss

    let name: String
    let apply: (FolderDecoration) -> Void

    @State private var color: FolderColor
    @State private var symbol: FolderSymbol

    /// Opens on what the folder already carries, which for a folder whose
    /// sidecar could not be read is the plain pair it is drawn as.
    init(name: String, decoration: FolderDecoration?, apply: @escaping (FolderDecoration) -> Void) {
        self.name = name
        self.apply = apply
        let opened = decoration ?? .plain
        _color = State(initialValue: opened.color)
        _symbol = State(initialValue: opened.symbol)
    }

    @Environment(\.macaron) private var theme

    var body: some View {
        MacaronPanel(title: name, onClose: { dismiss() }) {
            HStack {
                Spacer()
                LibraryFolderGlyph(decoration: chosen)
                    .frame(width: 92, height: 92)
                Spacer()
            }

            MacaronHeading(text: "Colour")
            swatches

            MacaronHeading(text: "Symbol")
            symbols

            MacaronButton(title: "Done", fill: theme.accent) {
                apply(chosen)
                dismiss()
            }
        }
    }

    private var chosen: FolderDecoration { FolderDecoration(color: color, symbol: symbol) }

    /// The folder's colours are the folder's own, not the theme's, so a
    /// swatch is a cap filled with the colour it stands for. The chosen one
    /// is sunk, and that is the whole of the mark on it.
    private var swatches: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: Macaron.columnGap)], spacing: Macaron.rowGap) {
            ForEach(FolderColor.allCases, id: \.self) { candidate in
                Keycap(
                    fill: Self.fill(of: candidate),
                    isHeld: candidate == color,
                    action: { color = candidate }
                )
                .accessibilityLabel(FolderStyleNames.color(candidate))
            }
        }
    }

    private var symbols: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: Macaron.columnGap)], spacing: Macaron.rowGap) {
            ForEach(FolderSymbol.allCases, id: \.self) { candidate in
                Keycap(
                    fill: theme.chrome,
                    size: CGSize(width: 52, height: Macaron.chip + 6),
                    isHeld: candidate == symbol,
                    action: { symbol = candidate }
                ) {
                    Image(systemName: candidate.rawValue)
                        .font(Macaron.body(17))
                        .foregroundStyle(LibraryStyle.color(of: color))
                }
                .accessibilityLabel(FolderStyleNames.symbol(candidate))
            }
        }
    }

    /// The same colour `LibraryStyle` draws the folder in, as the four bytes
    /// a keycap derives its outline and its wall from.
    @MainActor private static func fill(of color: FolderColor) -> RGBA8 {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(LibraryStyle.color(of: color)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt8 { UInt8(min(255, max(0, value * 255)).rounded()) }
        return RGBA8(red: byte(red), green: byte(green), blue: byte(blue), alpha: byte(alpha))
    }
}
