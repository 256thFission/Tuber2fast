import SwiftUI
import TNEditor
import TNModel

/// What the bar's one run is made of. The run is drawn from a row of
/// these, so a bar laid out another way is another row and not another
/// view. `defaultRow` is the only row there is.
enum BarEntry {
    case grab
    case instrument(ToolPalette.Kind)
    case divider
    case widths
    case swatches

    /// In the order the design fixes.
    static let defaultRow: [BarEntry] = [
        .grab,
        .instrument(.ink(.pen)), .instrument(.ink(.pencil)),
        .instrument(.ink(.highlighter)), .instrument(.eraser),
        .divider, .widths, .divider, .swatches,
    ]
}

extension EditorTool {
    /// The eraser's glyph is its mode's, since a second tap on it switches
    /// the mode.
    var symbol: String {
        switch self {
        case .ink(.pen, _): "pencil.tip"
        case .ink(.pencil, _): "pencil"
        case .ink(.highlighter, _): "highlighter"
        case .eraseObject: "eraser"
        case .erasePixel: "eraser.line.dashed"
        case .text: "textformat"
        case .lasso: "lasso"
        }
    }

    var label: String {
        switch self {
        case .ink(.pen, _): "Pen"
        case .ink(.pencil, _): "Pencil"
        case .ink(.highlighter, _): "Highlighter"
        case .eraseObject, .erasePixel: "Eraser"
        case .text: "Text"
        case .lasso: "Lasso"
        }
    }

    /// What VoiceOver says after the label. Only the eraser has a state of
    /// its own to say.
    var value: String {
        switch self {
        case .eraseObject: "Whole strokes"
        case .erasePixel: "Pixels"
        case .ink, .text, .lasso: ""
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

/// The writing bar: one run drawn from a row of entries. The default row,
/// the only one built, is a grab pill, four instruments, the widths, and
/// four swatches.
struct WritingBar: View {
    let editor: EditorViewModel

    @Environment(Workspace.self) private var workspace
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
    /// Which swatch the colour tray hangs off, while it is open.
    @State private var tray: Int?
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
        let vertical = LaunchHooks.arguments.contains("-TNBarVertical")
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
        .task {
            // A screenshot of the open tray needs no hold to get to it. Late,
            // because a popover asked for before the bar is on screen is not
            // shown.
            guard LaunchScene.current.tray else { return }
            try? await Task.sleep(for: .seconds(1))
            tray = 0
        }
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

    /// One run, in the row's order. The layout container is what changes
    /// between the snap states, never the contents and never their order.
    @ViewBuilder private var contents: some View {
        ForEach(Array(BarEntry.defaultRow.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .grab:
                // Flat: it is a handle, not a button, and a wall would say
                // "press me".
                FlatChip {
                    Image(systemName: "line.3.horizontal")
                        .font(Macaron.body(.text))
                        .rotationEffect(.degrees(isHorizontal ? 0 : 90))
                }
                .gesture(grab)
                .accessibilityLabel("Move the writing bar")
            case .instrument(let kind): InstrumentCap(editor: editor, kind: kind)
            case .divider: MacaronDivider(vertical: !isHorizontal)
            case .widths: widths
            case .swatches: swatches
            }
        }
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
                widthChip(width, isHeld: width == editor.tool.width)
            }
        } else {
            // One chip standing for the width in hand; the other two live in
            // the bubble it opens. The system picks the bubble's side, which
            // is the page's: a side named here sent it off the screen.
            widthChip(editor.tool.width ?? .medium, isHeld: false)
                .macaronBubble(isPresented: $isShowingWidths) { widthChoices }
        }
    }

    /// The three widths in the standing bar's bubble.
    private var widthChoices: some View {
        HStack(spacing: Macaron.rowGap) {
            ForEach(ToolWidth.allCases, id: \.self) { width in
                Button {
                    take(width)
                    isShowingWidths = false
                } label: {
                    FlatChip(fill: width == editor.tool.width ? theme.accent : nil, isRound: true) {
                        Circle().frame(width: dot(width), height: dot(width))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(width.rawValue) width"))
            }
        }
    }

    private func widthChip(_ width: ToolWidth, isHeld: Bool) -> some View {
        Keycap(
            fill: isHeld ? theme.accent : theme.chrome,
            isHeld: isHeld,
            isEnabled: editor.tool.takesWidth
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

    /// Read again at the tap, not trusted from the last body pass: two
    /// fingers can land a width and a band chip in one turn, and the editor
    /// traps on a width the tool in hand cannot take.
    private func take(_ width: ToolWidth) {
        guard editor.tool.takesWidth else { return }
        editor.setWidth(width)
    }

    // MARK: Swatches

    /// The palette's run for the theme choice and the tool in hand, in one
    /// run of keycaps. The run is a row when the bar lies down and a column
    /// when it stands up, and never a column inside a row. A hold on one
    /// opens the colour tray off it.
    @ViewBuilder private var swatches: some View {
        let key = SwatchKey(workspace.choice, editor.tool.swatchRun)
        ForEach(Array(editor.palette.swatches(for: key, in: theme).enumerated()), id: \.offset) { index, colour in
            let isHeld = colour == editor.tool.color
            Keycap(
                fill: colour.rgba,
                size: CGSize(
                    width: isHeld ? Macaron.heldSwatch : Macaron.swatch,
                    height: isHeld ? Macaron.heldSwatch : Macaron.swatch
                ),
                radius: Macaron.swatchRadius,
                wall: Macaron.swatchWall,
                isHeld: isHeld,
                isEnabled: editor.tool.color != nil,
                hold: { openTray(at: index) }
            ) {
                // Read again at the tap, as a width is.
                guard editor.tool.color != nil else { return }
                editor.setColor(colour)
            }
            .accessibilityLabel(Text(verbatim: "Colour \(index + 1)"))
            .accessibilityAddTraits(isHeld ? .isSelected : [])
            .accessibilityAction(named: "Change colour") { openTray(at: index) }
            .macaronBubble(isPresented: Binding { tray == index } set: { if !$0 { tray = nil } }) {
                ColourTray(editor: editor, index: index, colour: colour)
            }
        }
    }

    /// Read again at the hold, as a tap is: a tray opened over a tool with
    /// no colour would offer colours nothing takes.
    private func openTray(at index: Int) {
        guard editor.tool.color != nil else { return }
        tray = index
    }
}

/// One instrument as a keycap. The one in hand is sunk into its own wall,
/// which is the entire selected state.
struct InstrumentCap: View {
    let editor: EditorViewModel
    let kind: ToolPalette.Kind
    @Environment(\.macaron) private var theme

    var body: some View {
        let isHeld = editor.tool.kind == kind
        let shown = editor.tool(for: kind)
        Keycap(
            shown.label,
            systemImage: shown.symbol,
            symbolSize: .instrument,
            fill: isHeld ? theme.accent : theme.chrome,
            isHeld: isHeld
        ) {
            editor.select(kind)
        }
        .accessibilityValue(shown.value)
        .accessibilityAddTraits(isHeld ? .isSelected : [])
    }
}
