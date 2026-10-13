import SwiftUI
import TNEditor
import TNModel

/// What the text tool types with: size, weight, alignment and colour, in
/// a bubble off the band's text chip. A choice restyles the selection in
/// an open box, or what the caret types next.
///
/// Flat, as every bubble is. A held choice is filled with the accent; a
/// held colour, which is its own fill, carries a check.
struct TextStylePopover: View {
    let editor: EditorViewModel

    @Environment(Workspace.self) private var workspace
    @Environment(\.macaron) private var theme

    var body: some View {
        if case .text(let style, let alignment) = editor.tool {
            VStack(alignment: .leading, spacing: Macaron.columnGap) {
                HStack(spacing: Macaron.rowGap) {
                    ForEach(TextPreset.sizes, id: \.self) { size in
                        selector("\(Int(size)) point", isHeld: size == style.size) {
                            restyle { $0.with(size: size) }
                        } label: {
                            Text(verbatim: "\(Int(size))").font(Macaron.title(.text))
                        }
                    }
                }
                HStack(spacing: Macaron.rowGap) {
                    selector("Bold", isHeld: style.bold) {
                        restyle { $0.with(bold: !$0.bold) }
                    } label: {
                        Image(systemName: "bold").font(Macaron.body(.label))
                    }
                    MacaronDivider()
                    ForEach(TNModel.TextAlignment.allCases, id: \.self) { choice in
                        selector(choice.name, isHeld: choice == alignment) {
                            align(choice)
                        } label: {
                            Image(systemName: choice.symbol).font(Macaron.body(.label))
                        }
                    }
                }
                HStack(spacing: Macaron.rowGap) {
                    // The pen's run, which the text tool shares.
                    let colours = editor.palette.swatches(for: SwatchKey(workspace.choice, .pen), in: theme)
                    ForEach(Array(colours.enumerated()), id: \.offset) { index, colour in
                        let isHeld = colour.rgba == style.color
                        Button {
                            restyle { $0.with(color: colour.rgba) }
                        } label: {
                            // Hidden rather than absent: a chip with no label has
                            // nothing to size and draws nothing at all.
                            FlatChip(fill: colour.rgba) {
                                Image(systemName: "checkmark").font(Macaron.body(.label)).opacity(isHeld ? 1 : 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "Colour \(index + 1)"))
                        .accessibilityAddTraits(isHeld ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func selector<Label: View>(
        _ name: String,
        isHeld: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) -> some View {
        Button(action: action) {
            FlatChip(fill: isHeld ? theme.accent : nil, label: label)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isHeld ? .isSelected : [])
    }

    // Each reads the tool again at the tap, as the bar's swatches and
    // widths do: a band chip can change it in the same turn, and the editor
    // traps on a style for a tool that types nothing.

    /// The style in hand, changed by `change`.
    func restyle(_ change: (TextStyle) -> TextStyle) {
        guard case .text(let style, _) = editor.tool else { return }
        editor.setTextStyle(change(style))
    }

    func align(_ alignment: TNModel.TextAlignment) {
        guard case .text = editor.tool else { return }
        editor.setTextAlignment(alignment)
    }
}

private extension TNModel.TextAlignment {
    var symbol: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }

    var name: String {
        switch self {
        case .leading: "Align left"
        case .center: "Centre"
        case .trailing: "Align right"
        }
    }
}
