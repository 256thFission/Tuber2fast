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

/// Where the bar can park: four corners and four edge midpoints.
///
/// The two horizontal-edge midpoints are the only places the bar lies down.
/// Everywhere else — the corners and the two side midpoints — it stands up,
/// which is what the two snap states are.
enum SnapPoint: CaseIterable {
    case topLeading, top, topTrailing, trailing
    case bottomTrailing, bottom, bottomLeading, leading

    var isHorizontal: Bool { self == .top || self == .bottom }

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .trailing: .trailing
        case .bottomTrailing: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeading: .bottomLeading
        case .leading: .leading
        }
    }

    /// The top-left a bar of `size` sits at when it is parked here.
    ///
    /// A corner, not a centre: the shell is placed by an offset from the
    /// surface's own origin, so that the tilt and the lift during a drag
    /// turn the bar about itself rather than about the surface.
    func origin(of size: CGSize, in bounds: CGSize, inset: CGFloat) -> CGPoint {
        let x: CGFloat = switch self {
        case .topLeading, .leading, .bottomLeading: inset
        case .top, .bottom: (bounds.width - size.width) / 2
        case .topTrailing, .trailing, .bottomTrailing: bounds.width - inset - size.width
        }
        let y: CGFloat = switch self {
        case .topLeading, .top, .topTrailing: inset
        case .leading, .trailing: (bounds.height - size.height) / 2
        case .bottomLeading, .bottom, .bottomTrailing: bounds.height - inset - size.height
        }
        return CGPoint(x: x, y: y)
    }

    /// The centre of that same rectangle, which is what a throw's predicted
    /// end location is compared against.
    func centre(of size: CGSize, in bounds: CGSize, inset: CGFloat) -> CGPoint {
        let corner = origin(of: size, in: bounds, inset: inset)
        return CGPoint(x: corner.x + size.width / 2, y: corner.y + size.height / 2)
    }
}

/// The writing bar: a grab pill, four instruments, the widths, and four
/// swatches in one run. Nothing else is on it, and nothing else ever is.
struct WritingBar: View {
    let editor: EditorViewModel

    @Environment(\.macaron) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var snap: SnapPoint
    @State private var drag: CGSize = .zero
    /// Explicit, rather than read off a non-zero translation: the first
    /// change of a drag can report exactly zero, and a dialect switched on
    /// by a comparison to zero flickers on and off at the start of one.
    @State private var isDragging = false
    @State private var target: SnapPoint?
    @State private var measured: CGSize = .zero
    @State private var isShowingWidths = false
    /// The editor surface, as the last layout reported it: what the eight
    /// candidate centres are measured in.
    @State private var boundsGuess: CGSize = .zero

    private static let inset: CGFloat = 16
    /// The bar's own surface. A throw's predicted end has to be measured in
    /// the same space as the eight candidates it is compared against.
    private static let space = "writing-bar"

    init(editor: EditorViewModel) {
        self.editor = editor
        // A screenshot of the standing state needs no touches to get to it.
        let vertical = ProcessInfo.processInfo.arguments.contains("-TNBarVertical")
        _snap = State(initialValue: vertical ? .trailing : .top)
    }

    private var isHorizontal: Bool { snap.isHorizontal }
    private var gap: CGFloat { isHorizontal ? Macaron.rowGap : Macaron.columnGap }

    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.size
            let corner = snap.origin(of: measured, in: bounds, inset: Self.inset)
            ZStack(alignment: .topLeading) {
                if isDragging, let target {
                    ghost(for: target, in: bounds)
                }
                shell
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
                    // The peel is applied to the shell itself, before it is
                    // placed, so the tilt turns it about its own middle.
                    .rotationEffect(.degrees(isDragging ? -4 : 0))
                    .shadow(
                        color: theme.ink.color.opacity(isDragging ? 0.42 : 0),
                        radius: isDragging ? 18 : 0, x: 0, y: isDragging ? 12 : 0
                    )
                    .offset(
                        x: corner.x + drag.width,
                        y: corner.y + drag.height - (isDragging ? 5 : 0)
                    )
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.space))
            .onGeometryChange(for: CGSize.self) { _ in bounds } action: { boundsGuess = $0 }
        }
        .ignoresSafeArea(.keyboard)
    }

    // MARK: The shell

    @ViewBuilder private var shell: some View {
        MacaronShell {
            if isHorizontal {
                HStack(spacing: gap) { contents }
                    .frame(height: Macaron.shell - Macaron.shellPadding * 2)
            } else {
                VStack(spacing: gap) { contents }
                    .frame(width: Macaron.shell - Macaron.shellPadding * 2)
            }
        }
    }

    /// One run, in the one order. The layout container is what changes
    /// between the snap states, never the contents and never their order.
    @ViewBuilder private var contents: some View {
        grabPill
        InstrumentRun(editor: editor)
        MacaronDivider(vertical: !isHorizontal)
        widths
        MacaronDivider(vertical: !isHorizontal)
        swatches
    }

    /// Flat: it is a handle, not a button, and a wall would say "press me".
    private var grabPill: some View {
        RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
            .fill(theme.chrome.color)
            .overlay {
                RoundedRectangle(cornerRadius: Macaron.chipRadius, style: .continuous)
                    .strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
            }
            .overlay {
                Image(systemName: "line.3.horizontal")
                    .font(Macaron.body(13))
                    .foregroundStyle(theme.outline(of: theme.chrome).color)
                    .rotationEffect(.degrees(isHorizontal ? 0 : 90))
            }
            .frame(width: Macaron.chip, height: Macaron.chip)
            .gesture(grab)
            .accessibilityLabel("Move the writing bar")
    }

    private var grab: some Gesture {
        DragGesture(coordinateSpace: .named(Self.space))
            .onChanged { value in
                if !isDragging {
                    withAnimation(reduceMotion ? MacaronCurve.reduced : MacaronCurve.settle) {
                        isDragging = true
                    }
                }
                drag = value.translation
                target = nearest(to: value.predictedEndLocation)
            }
            .onEnded { value in
                let landing = nearest(to: value.predictedEndLocation)
                target = nil
                // The bar lands first and the peel comes off with it, in one
                // animation: two would fight over the same offset.
                withAnimation(reduceMotion ? MacaronCurve.reduced : MacaronCurve.snap) {
                    snap = landing
                    drag = .zero
                    isDragging = false
                }
            }
    }

    private func nearest(to point: CGPoint) -> SnapPoint {
        // The bar is placed in the editor's own space, so the eight candidate
        // centres are measured in it too.
        let bounds = boundsGuess
        return SnapPoint.allCases.min { first, second in
            distance(first.centre(of: size(for: first), in: bounds, inset: Self.inset), point)
                < distance(second.centre(of: size(for: second), in: bounds, inset: Self.inset), point)
        } ?? .top
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }

    /// What the shell measures in each state. The long axis is whatever the
    /// contents hug to; only the short axis is fixed at 56.
    private func size(for point: SnapPoint) -> CGSize {
        guard measured != .zero else { return CGSize(width: Macaron.shell, height: Macaron.shell) }
        return point.isHorizontal == isHorizontal
            ? measured
            : CGSize(width: measured.height, height: measured.width)
    }

    /// Dashed, because it is transient and has no body: the exact shell the
    /// bar will become where it will become it, so a change of orientation
    /// is seen before the finger lifts.
    private func ghost(for point: SnapPoint, in bounds: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: Macaron.shellRadius, style: .continuous)
        let size = size(for: point)
        return shape
            .strokeBorder(
                theme.accent.color,
                style: StrokeStyle(lineWidth: Macaron.line, dash: Macaron.dash)
            )
            .frame(width: size.width, height: size.height)
            .offset(
                x: point.origin(of: size, in: bounds, inset: Self.inset).x,
                y: point.origin(of: size, in: bounds, inset: Self.inset).y
            )
    }

    // MARK: Widths

    @ViewBuilder private var widths: some View {
        if isHorizontal {
            ForEach(ToolWidth.allCases, id: \.self) { width in
                widthChip(width, isHeld: width == currentWidth)
            }
        } else {
            // One chip standing for the width in hand; the other two live in
            // the bubble it opens.
            widthChip(currentWidth ?? .medium, isHeld: false)
                .popover(isPresented: $isShowingWidths, arrowEdge: .leading) { widthBubble }
        }
    }

    private func widthChip(_ width: ToolWidth, isHeld: Bool) -> some View {
        Keycap(
            fill: isHeld ? theme.accent : theme.chrome,
            isHeld: isHeld,
            isEnabled: widthApplies
        ) {
            if isHorizontal {
                take(width)
            } else {
                isShowingWidths = true
            }
        } label: {
            Circle()
                .fill(theme.outline(of: isHeld ? theme.accent : theme.chrome).color)
                .frame(width: dot(width), height: dot(width))
        }
        .accessibilityLabel(Text(verbatim: "\(width.rawValue) width"))
    }

    private func dot(_ width: ToolWidth) -> CGFloat {
        switch width {
        case .thin: 6
        case .medium: 11
        case .thick: 16
        }
    }

    /// The width the tool in hand carries, or nothing when it carries none.
    /// The object eraser is the interesting one: it has no width at all, so
    /// no chip is sunk while it is held.
    private var currentWidth: ToolWidth? {
        switch editor.tool {
        case .ink(_, let preset): preset.width
        case .erasePixel(let width): width
        case .eraseObject, .lasso, .text: nil
        }
    }

    /// Whether a width chip means anything with the tool in hand.
    ///
    /// The editor traps on a width set on a tool that has none, and it is
    /// right to: a view that draws a control the tool does not have is the
    /// defect. The lasso and text are the band's tools, not the bar's, so
    /// while one of them is in hand the bar's widths and swatches have no
    /// owner and are not offered.
    private var widthApplies: Bool {
        switch editor.tool {
        case .ink, .erasePixel, .eraseObject: true
        case .lasso, .text: false
        }
    }

    private var colourApplies: Bool {
        if case .ink = editor.tool { return true }
        return false
    }

    /// Asking the object eraser for a width is how it becomes the eraser
    /// that has one. Every other tool here already carries its own.
    private func take(_ width: ToolWidth) {
        if case .eraseObject = editor.tool { editor.setEraserMode(.pixel) }
        editor.setWidth(width)
    }

    /// A speech bubble with a tail pointing at the chip that owns it. No
    /// wall on the selectors: the bubble is a transient, not a keyboard.
    private var widthBubble: some View {
        HStack(spacing: Macaron.rowGap) {
            ForEach(ToolWidth.allCases, id: \.self) { width in
                Button {
                    take(width)
                    isShowingWidths = false
                } label: {
                    Circle()
                        .fill(width == currentWidth ? theme.accent.color : theme.chrome.color)
                        .overlay {
                            Circle().strokeBorder(
                                theme.outline(of: width == currentWidth ? theme.accent : theme.chrome).color,
                                lineWidth: Macaron.line
                            )
                        }
                        .overlay {
                            Circle()
                                .fill(theme.outline(of: theme.chrome).color)
                                .frame(width: dot(width), height: dot(width))
                        }
                        .frame(width: Macaron.chip, height: Macaron.chip)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(width.rawValue) width"))
            }
        }
        .padding(Macaron.shellPadding)
        .background {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(theme.chrome.color)
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(theme.outline(of: theme.chrome).color, lineWidth: Macaron.line)
                }
        }
        .padding(Macaron.line)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: Swatches

    /// Four, always, in one run. The run is a row when the bar lies down and
    /// a column when it stands up, and never a column inside a row.
    @ViewBuilder private var swatches: some View {
        ForEach(Array(fourColours.enumerated()), id: \.offset) { _, colour in
            let isHeld = colour == currentColour
            Keycap(
                fill: colour.rgba,
                size: CGSize(
                    width: isHeld ? Macaron.heldSwatch : Macaron.swatch,
                    height: isHeld ? Macaron.heldSwatch : Macaron.swatch
                ),
                radius: Macaron.swatchRadius,
                wall: Macaron.swatchWall,
                isHeld: isHeld,
                isEnabled: colourApplies
            ) {
                editor.setColor(colour)
            }
            .accessibilityAddTraits(isHeld ? .isSelected : [])
        }
    }

    /// The colours the person actually drew with, ahead of the shipped ones,
    /// cut to four. The document fixes the count and leaves the source to
    /// the palette that already holds it.
    private var fourColours: [ToolColor] {
        var seen: [ToolColor] = []
        for colour in editor.palette.recentColors + ToolColor.defaults where !seen.contains(colour) {
            seen.append(colour)
            if seen.count == 4 { break }
        }
        return seen
    }

    private var currentColour: ToolColor? {
        if case .ink(_, let preset) = editor.tool { return preset.color }
        return nil
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
