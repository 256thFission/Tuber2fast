import SwiftUI
import TNEditor
import TNModel
import TNNotebook
import UIKit

/// One button on the strip.
///
/// A case per button rather than a case per tool: the two erasers share a
/// button and differ inside its popover, which is what the person sees.
enum EditorToolButton: Hashable, CaseIterable, Identifiable {
    case pen, pencil, highlighter, eraser, lasso, text

    var id: Self { self }

    /// Which button the tool in hand lights up.
    init(_ tool: EditorTool) {
        switch tool {
        case .ink(.pen, _): self = .pen
        case .ink(.pencil, _): self = .pencil
        case .ink(.highlighter, _): self = .highlighter
        case .eraseObject, .erasePixel: self = .eraser
        case .lasso: self = .lasso
        case .text: self = .text
        }
    }

    var inkKind: InkKind? {
        switch self {
        case .pen: .pen
        case .pencil: .pencil
        case .highlighter: .highlighter
        case .eraser, .lasso, .text: nil
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .text: "textformat"
        }
    }

    var label: String {
        switch self {
        case .pen: "Pen"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        case .text: "Text"
        }
    }

    /// Lasso has no attributes, so a second tap on it does nothing.
    var hasOptions: Bool { self != .lasso }
}

/// The tools across the left of the toolbar. Tapping an unselected tool
/// picks it up; tapping the one in hand opens its options over it.
///
/// Everything drawn comes from `editor.tool` or the palette, and everything
/// done is one call on the editor. The strip decides nothing.
struct ToolStrip: View {
    let editor: EditorViewModel

    @State private var optionsFor: EditorToolButton?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(EditorToolButton.allCases) { button in
                toolButton(button)
            }
        }
    }

    private func toolButton(_ button: EditorToolButton) -> some View {
        let isSelected = EditorToolButton(editor.tool) == button
        return Button {
            tap(button, isSelected: isSelected)
        } label: {
            Image(systemName: button.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? Slate.ground : Slate.chalk)
                .frame(width: 34, height: 34)
                .background {
                    if isSelected {
                        Circle().fill(Slate.yellow)
                    } else {
                        Circle().strokeBorder(Slate.chalkDim, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(button.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .popover(isPresented: presentation(of: button)) {
            toolOptions
        }
    }

    /// An ink button wears the colour it would draw in, so the strip answers
    /// "what colour is my pencil" without being tapped.
    private func tint(_ button: EditorToolButton) -> Color {
        guard let kind = button.inkKind, let preset = editor.palette.inks[kind] else {
            return .accentColor
        }
        return Color(preset.color.uiColor)
    }

    private func tap(_ button: EditorToolButton, isSelected: Bool) {
        guard isSelected else {
            switch button {
            case .pen: editor.select(kind: .pen)
            case .pencil: editor.select(kind: .pencil)
            case .highlighter: editor.select(kind: .highlighter)
            case .eraser: editor.selectEraser()
            case .lasso: editor.selectLasso()
            case .text: editor.selectText()
            }
            return
        }
        guard button.hasOptions else { return }
        optionsFor = button
    }

    /// One `optionsFor` for the whole strip, read as a per-button flag, so
    /// the popover anchors to the button that was tapped.
    private func presentation(of button: EditorToolButton) -> Binding<Bool> {
        Binding(
            get: { optionsFor == button },
            set: { shown in if !shown, optionsFor == button { optionsFor = nil } }
        )
    }

    /// The tool in hand decides what the popover holds, not the button it
    /// came out of: a popover only ever opens over the selected tool.
    @ViewBuilder
    private var toolOptions: some View {
        switch editor.tool {
        case .ink(_, let preset):
            InkOptions(editor: editor, preset: preset)
        case .eraseObject:
            EraserOptions(editor: editor, pixelWidth: nil)
        case .erasePixel(let width):
            EraserOptions(editor: editor, pixelWidth: width)
        case .text(let style, let alignment):
            TextOptions(editor: editor, style: style, alignment: alignment)
        case .lasso:
            // Unreachable: the popover only opens over the tool in hand, and
            // lasso's second tap does nothing.
            EmptyView()
        }
    }
}

/// Width and colour for the ink in hand.
private struct InkOptions: View {
    let editor: EditorViewModel
    let preset: InkPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WidthDots(selected: preset.width, choose: { editor.setWidth($0) })
            colors
            gestures
        }
        .padding(18)
        .presentationCompactAdaptation(.popover)
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Recents first: the colours the person actually drew with are
            // nearer the thumb than the ones the app shipped with.
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                ForEach(editor.palette.recentColors + ToolColor.defaults, id: \.rgba.hex) { color in
                    Button { editor.setColor(color) } label: {
                        Swatch(color: color, isSelected: color == preset.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.name(of: color))
                    .accessibilityAddTraits(color == preset.color ? .isSelected : [])
                }
            }
            ColorPicker(
                "Custom colour",
                selection: Binding(
                    get: { Color(preset.color.uiColor) },
                    set: { editor.setColor(ToolColor(UIColor($0))) }
                ),
                // Ink is always opaque: the highlighter's translucency is
                // PencilKit's, and a translucent colour over it dims twice.
                supportsOpacity: false
            )
            .font(.callout)
        }
    }

    /// One row per trigger. The bindings live beside the widths and colours
    /// because a gesture belongs to the pen in hand, and the person who
    /// asked for a gesture that never visits the toolbar should not have to
    /// visit one to switch it on. They are one set for pen, pencil and
    /// highlighter, so all three ink popovers draw the same rows.
    private var gestures: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(GestureTrigger.allCases, id: \.self) { trigger in
                Picker(
                    Self.name(of: trigger),
                    // A closure literal, as in `EraserOptions`: `bind` takes
                    // the trigger too, so there is no method to hand over.
                    selection: Binding(
                        get: { editor.palette.gestures[trigger] },
                        set: { editor.bind(trigger, to: $0) }
                    )
                ) {
                    // Off is the absent key, not an effect: the map is the
                    // record, and a trigger it does not name is unbound.
                    Text("Off").tag(GestureEffect?.none)
                    ForEach(GestureEffect.allCases, id: \.self) { effect in
                        Text(Self.name(of: effect)).tag(GestureEffect?.some(effect))
                    }
                }
                .pickerStyle(.menu)
                .font(.callout)
            }
        }
    }

    private static let columns = Array(
        repeating: GridItem(.fixed(30), spacing: 10, alignment: .leading),
        count: 8
    )

    /// VoiceOver has no word for a swatch, so it reads the bytes.
    private static func name(of color: ToolColor) -> String { color.rgba.hex }

    private static func name(of trigger: GestureTrigger) -> String {
        switch trigger {
        case .scribble: "Scribble"
        case .doubleCircle: "Double circle"
        }
    }

    private static func name(of effect: GestureEffect) -> String {
        switch effect {
        case .erase: "Erase"
        }
    }
}

/// Size, weight, alignment and colour for the text in hand. Defaults and
/// the well only: a colour typed with is never a recent (`README.md`,
/// decision 3).
private struct TextOptions: View {
    let editor: EditorViewModel
    let style: TextStyle
    let alignment: TNModel.TextAlignment

    /// Points. Taste, like the ink widths; `Docs/Unproven.md` holds it.
    private static let sizes: [Double] = [12, 14, 16, 18, 24, 32, 48]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Picker("Size", selection: Binding(get: { style.size }, set: { editor.setTextStyle(style.with(size: $0)) })) {
                    ForEach(Self.sizes, id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Bold", systemImage: "bold", isOn: Binding(get: { style.bold }, set: { editor.setTextStyle(style.with(bold: $0)) }))
                Toggle("Italic", systemImage: "italic", isOn: Binding(get: { style.italic }, set: { editor.setTextStyle(style.with(italic: $0)) }))
                Toggle("Underline", systemImage: "underline", isOn: Binding(get: { style.underline }, set: { editor.setTextStyle(style.with(underline: $0)) }))
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            Picker("Alignment", selection: Binding(get: { alignment }, set: { editor.setTextAlignment($0) })) {
                Image(systemName: "text.alignleft").tag(TNModel.TextAlignment.leading)
                Image(systemName: "text.aligncenter").tag(TNModel.TextAlignment.center)
                Image(systemName: "text.alignright").tag(TNModel.TextAlignment.trailing)
            }
            .pickerStyle(.segmented)
            colors
        }
        .frame(width: 340)
        .padding(18)
        .presentationCompactAdaptation(.popover)
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                ForEach(ToolColor.defaults, id: \.rgba.hex) { color in
                    Button { editor.setTextStyle(style.with(color: color.rgba)) } label: {
                        Swatch(color: color, isSelected: color.rgba == style.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.rgba.hex)
                    .accessibilityAddTraits(color.rgba == style.color ? .isSelected : [])
                }
            }
            ColorPicker(
                "Custom colour",
                selection: Binding(
                    get: { Color(ToolColor(rgba: style.color).uiColor) },
                    set: { editor.setTextStyle(style.with(color: ToolColor(UIColor($0)).rgba)) }
                ),
                supportsOpacity: false
            )
            .font(.callout)
        }
    }

    private static let columns = Array(
        repeating: GridItem(.fixed(30), spacing: 10, alignment: .leading),
        count: 8
    )
}

private extension TextStyle {
    func with(size: Double? = nil, bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, color: RGBA8? = nil) -> TextStyle {
        TextStyle(
            font: font, size: size ?? self.size, bold: bold ?? self.bold, italic: italic ?? self.italic,
            underline: underline ?? self.underline, color: color ?? self.color
        )
    }
}

/// Which eraser, and how wide when it is the pixel one.
private struct EraserOptions: View {
    let editor: EditorViewModel
    /// `nil` in object mode, where there is no width to pick. One field
    /// rather than a mode beside it, so a width on the object eraser is
    /// as unrepresentable here as it is in `EditorTool`.
    let pixelWidth: ToolWidth?

    private var mode: EraserMode { pixelWidth == nil ? .object : .pixel }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(
                "Eraser",
                // KNOWN DEFECT: the setter is a closure literal because
                // `set: editor.setEraserMode` crashes the compiler. Apple
                // Swift 6.3.3 dies in IRGen emitting the reabstraction thunk
                // `@$s8TNEditor10EraserModeOScA_pSgIeAghyg_ACIeAghn_TR` for a
                // main-actor method handed straight to `Binding.init`.
                // Measured on this file, 2026-09-11. The literal costs
                // nothing; delete this note when the toolchain moves.
                selection: Binding(get: { mode }, set: { editor.setEraserMode($0) })
            ) {
                Text("Object").tag(EraserMode.object)
                Text("Pixel").tag(EraserMode.pixel)
            }
            .pickerStyle(.segmented)

            // The object eraser takes whole strokes and has no width, so the
            // dots are absent rather than disabled: `setWidth` traps on it.
            if let pixelWidth {
                WidthDots(selected: pixelWidth, choose: { editor.setWidth($0) })
            }
        }
        .frame(width: 260)
        .padding(18)
        .presentationCompactAdaptation(.popover)
    }
}

/// The three widths, drawn at a size that reads as what each one picks.
private struct WidthDots: View {
    let selected: ToolWidth
    /// What a dot does. The dots are the same three in either popover; which
    /// call it makes is the tool's business, not theirs.
    let choose: (ToolWidth) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ToolWidth.allCases, id: \.self) { width in
                Button { choose(width) } label: {
                    Circle()
                        .fill(.primary)
                        .frame(width: Self.diameter(width), height: Self.diameter(width))
                        .frame(width: 44, height: 44)
                        .background(
                            selected == width ? Color.accentColor.opacity(0.22) : .clear,
                            in: .rect(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.label(width))
                .accessibilityAddTraits(selected == width ? .isSelected : [])
            }
        }
    }

    /// Screen points, not page points: the dot is a picture of the choice,
    /// and the smallest ink width drawn true would be a speck.
    private static func diameter(_ width: ToolWidth) -> CGFloat {
        switch width {
        case .thin: 6
        case .medium: 12
        case .thick: 20
        }
    }

    private static func label(_ width: ToolWidth) -> String {
        switch width {
        case .thin: "Thin"
        case .medium: "Medium"
        case .thick: "Thick"
        }
    }
}

/// One colour in the row, with the ring that says it is the one in hand.
private struct Swatch: View {
    let color: ToolColor
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(Color(color.uiColor))
            .frame(width: 26, height: 26)
            // A hairline, so a white or near-white swatch still has an edge
            // against the popover.
            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
            .overlay(
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                    .padding(-3)
            )
            .frame(width: 30, height: 30)
    }
}
