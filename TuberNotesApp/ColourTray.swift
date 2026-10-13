import SwiftUI
import TNCore
import TNEditor
import TNModel
import UIKit

/// A colour as the tray's wheel and slider hold it: the hue round the
/// wheel, the saturation out from its middle and the value along the
/// slider, each in 0...1.
///
/// Held apart from the colour it makes, because the colour forgets the
/// rest: at a value of zero every hue is black, and a slider dragged down
/// to black and back must come back to the hue it left.
struct HSV: Equatable {
    var hue: CGFloat
    var saturation: CGFloat
    var value: CGFloat

    /// Through UIKit's own conversion, in sRGB.
    var colour: ToolColor {
        ToolColor(UIColor(hue: hue, saturation: saturation, brightness: value, alpha: 1))
    }
}

extension HSV {
    init(_ colour: ToolColor) {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var value: CGFloat = 0
        var alpha: CGFloat = 0
        guard colour.uiColor.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha) else {
            TNPrecondition.fail("a tool colour with no hue: \(colour.rgba.hex)")
        }
        self.init(hue: hue, saturation: saturation, value: value)
    }
}

/// The colour tray, in a bubble whose tail points at the swatch a hold
/// opened it from. A colour picked on the wheel, on the slider or from the
/// recents goes into the hand and over that swatch, and the last one picked
/// becomes a recent when the tray closes.
///
/// Flat, as every bubble is: the wheel, the slider and the recents stand on
/// no wall.
struct ColourTray: View {
    let editor: EditorViewModel
    /// The swatch that opened the tray, in the run the tool in hand shows.
    let index: Int

    @Environment(Workspace.self) private var workspace
    @Environment(\.macaron) private var theme
    @State private var hsv: HSV
    /// What this session last put in the hand, which is the one recent it
    /// makes, however many colours the wheel passed through.
    @State private var picked: ToolColor?

    /// 214 across, with 10 at the sides and foot where the bubble pads 8.
    private static let side: CGFloat = 10
    private static let width: CGFloat = 214 - 2 * side
    private static let knob: CGFloat = 22
    private static let slider: CGFloat = 16
    private static let thumb = CGSize(width: 16, height: 22)
    private static let gap: CGFloat = 9
    /// Round the wheel from the trailing edge, clockwise, as SwiftUI turns
    /// an angle.
    private static let hues = (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }

    init(editor: EditorViewModel, index: Int, colour: ToolColor) {
        self.editor = editor
        self.index = index
        _hsv = State(initialValue: HSV(colour))
    }

    private var outline: Color { theme.outline(of: theme.chrome).color }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack {
                heading("Colour")
                Spacer()
                heading(String(hsv.colour.rgba.hex.prefix(7))).monospacedDigit()
            }
            wheel
            slider
            Capsule().fill(outline.opacity(0.35)).frame(height: Macaron.line)
            heading("Recently used")
            recents
        }
        .frame(width: Self.width)
        .padding([.horizontal, .bottom], Self.side - Macaron.shellPadding)
        .onDisappear {
            if let picked { editor.trayClosed(on: picked) }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(verbatim: text.uppercased())
            // macaron: one-off. The tray's mock sets its headings at 900, a
            // weight neither of the kit's faces has.
            .font(.system(size: TypeScale.detail.rawValue, weight: .black, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(outline)
    }

    // MARK: The wheel

    private var wheel: some View {
        GeometryReader { proxy in
            let centre = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            // Full saturation is the ring's inner edge.
            let reach = min(centre.x, centre.y) - Macaron.line
            ZStack {
                Circle().fill(AngularGradient(colors: Self.hues, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: reach))
                Circle().strokeBorder(outline, lineWidth: Macaron.line)
                Circle()
                    .fill(hsv.colour.rgba.color)
                    .overlay { Circle().strokeBorder(theme.ink.color, lineWidth: Macaron.line) }
                    .frame(width: Self.knob, height: Self.knob)
                    .position(
                        x: centre.x + cos(hsv.hue * 2 * .pi) * hsv.saturation * reach,
                        y: centre.y + sin(hsv.hue * 2 * .pi) * hsv.saturation * reach
                    )
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let dx = drag.location.x - centre.x
                        let dy = drag.location.y - centre.y
                        let turn = atan2(dy, dx) / (2 * .pi)
                        hsv.hue = turn < 0 ? turn + 1 : turn
                        // A finger past the rim holds the rim.
                        hsv.saturation = min(1, hypot(dx, dy) / reach)
                    }
                    .onEnded { _ in pick(hsv.colour) }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Hue and saturation")
    }

    // MARK: The slider

    /// Black at the leading end, and at the trailing end the wheel's colour
    /// at full value.
    private var slider: some View {
        GeometryReader { proxy in
            let travel = proxy.size.width - Self.thumb.width
            let full = HSV(hue: hsv.hue, saturation: hsv.saturation, value: 1).colour
            Capsule()
                .fill(LinearGradient(colors: [.black, full.rgba.color], startPoint: .leading, endPoint: .trailing))
                .overlay { Capsule().strokeBorder(outline, lineWidth: Macaron.line) }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.chrome.color)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(outline, lineWidth: Macaron.line)
                        }
                        .frame(width: Self.thumb.width, height: Self.thumb.height)
                        .offset(x: hsv.value * travel)
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            // A finger past either end holds that end.
                            hsv.value = min(1, max(0, (drag.location.x - Self.thumb.width / 2) / travel))
                        }
                        .onEnded { _ in pick(hsv.colour) }
                )
        }
        .frame(height: Self.slider)
        .accessibilityElement()
        .accessibilityLabel("Brightness")
    }

    // MARK: The recents

    @ViewBuilder private var recents: some View {
        let colours = editor.palette.recentColors
        Group {
            if colours.isEmpty {
                MacaronNote(text: "Nothing yet. Draw something.")
            } else {
                HStack(spacing: Macaron.rowGap) {
                    ForEach(Array(colours.enumerated()), id: \.offset) { offset, colour in
                        recent(colour, number: offset + 1)
                    }
                }
            }
        }
        .frame(minHeight: Macaron.heldSwatch)
    }

    private func recent(_ colour: ToolColor, number: Int) -> some View {
        let isHeld = colour == editor.tool.color
        let size = isHeld ? Macaron.heldSwatch : Macaron.swatch
        let shape = RoundedRectangle(cornerRadius: Macaron.swatchRadius, style: .continuous)
        return Button {
            hsv = HSV(colour)
            pick(colour)
        } label: {
            shape.fill(colour.rgba.color)
                .overlay { shape.strokeBorder(theme.outline(of: colour.rgba).color, lineWidth: Macaron.line) }
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "Recent colour \(number)"))
        .accessibilityAddTraits(isHeld ? .isSelected : [])
    }

    /// Into the hand and over the swatch. The tool is read again here, as
    /// the bar's swatches read it at the tap: it can leave ink while the
    /// tray is open, and the editor traps on a colour for a tool with none.
    private func pick(_ colour: ToolColor) {
        guard editor.tool.color != nil else { return }
        editor.pick(colour, over: index, of: SwatchKey(workspace.choice, editor.tool.swatchRun), in: theme)
        picked = colour
    }
}
