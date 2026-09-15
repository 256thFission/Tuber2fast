import SwiftUI
import TNEditor
import TNModel

// PROTOTYPE: the writing bar. Always an overlay; rests at one of eight snap
// points. It never insets the canvas and the page never re-fits for it.

enum SnapPoint: String, Codable, CaseIterable {
    case topLeading, top, topTrailing, leading, trailing, bottomLeading, bottom, bottomTrailing

    var isRow: Bool { self == .top || self == .bottom }

    static let margin: CGFloat = 12

    static func key(landscape: Bool) -> String { "macaron.bar.\(landscape ? "landscape" : "portrait")" }

    static func load(landscape: Bool) -> SnapPoint? {
        UserDefaults.standard.string(forKey: key(landscape: landscape)).flatMap(SnapPoint.init(rawValue:))
    }

    func save(landscape: Bool) {
        UserDefaults.standard.set(rawValue, forKey: Self.key(landscape: landscape))
    }

    /// Rule 1: slack is on the axis where page and iPad disagree.
    static func proposed(page: PageGeometry, viewport: CGSize) -> SnapPoint {
        let pageAspect = CGFloat(page.width / page.height)
        return pageAspect < viewport.width / viewport.height ? .leading : .bottom
    }

    /// The bar's centre when resting here, for a bar of this size.
    func center(in viewport: CGSize, size: CGSize) -> CGPoint {
        let m = Self.margin
        let left = m + size.width / 2, right = viewport.width - m - size.width / 2
        let top = m + size.height / 2, bottom = viewport.height - m - size.height / 2
        switch self {
        case .topLeading: return CGPoint(x: left, y: top)
        case .top: return CGPoint(x: viewport.width / 2, y: top)
        case .topTrailing: return CGPoint(x: right, y: top)
        case .leading: return CGPoint(x: left, y: viewport.height / 2)
        case .trailing: return CGPoint(x: right, y: viewport.height / 2)
        case .bottomLeading: return CGPoint(x: left, y: bottom)
        case .bottom: return CGPoint(x: viewport.width / 2, y: bottom)
        case .bottomTrailing: return CGPoint(x: right, y: bottom)
        }
    }

    /// The resting place nearest a point, judged against each point's own
    /// anchor on the edge, so a flick toward a corner lands in the corner.
    static func nearest(to point: CGPoint, in viewport: CGSize) -> SnapPoint {
        let anchors: [(SnapPoint, CGPoint)] = [
            (.topLeading, CGPoint(x: 0, y: 0)), (.top, CGPoint(x: viewport.width / 2, y: 0)),
            (.topTrailing, CGPoint(x: viewport.width, y: 0)),
            (.leading, CGPoint(x: 0, y: viewport.height / 2)), (.trailing, CGPoint(x: viewport.width, y: viewport.height / 2)),
            (.bottomLeading, CGPoint(x: 0, y: viewport.height)), (.bottom, CGPoint(x: viewport.width / 2, y: viewport.height)),
            (.bottomTrailing, CGPoint(x: viewport.width, y: viewport.height)),
        ]
        return anchors.min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }!.0
    }
}

enum BarMetrics {
    static let chip: CGFloat = 42
    static let swatch: CGFloat = 28
}

/// The writing bar: pill, four instruments, widths, colours, undo. Only the
/// pill drags. Width and colour act on the held instrument.
struct WritingBar: View {
    let editor: EditorViewModel
    let vertical: Bool
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    private var chip: CGFloat { BarMetrics.chip }

    var body: some View {
        Group {
            if vertical {
                VStack(spacing: 8) { contents }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
            } else {
                HStack(spacing: 8) { contents }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .macaronCard(fill: Macaron.card, radius: 14, shadow: 6)
    }

    @ViewBuilder private var contents: some View {
        pill
        ToolStrip(editor: editor, buttons: [.pen, .pencil, .highlighter, .eraser], vertical: vertical, chip: chip)
        bar
        widths
        bar
        swatches
        bar
        Button { editor.undo() } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(MacaronChipStyle(size: chip))
        .disabled(!editor.canUndo)
        .contextMenu {
            Button { editor.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!editor.canRedo)
        }
        .accessibilityLabel("Undo")
    }

    private var bar: some View {
        Rectangle().fill(Macaron.ink)
            .frame(width: vertical ? chip - 12 : Macaron.outline, height: vertical ? Macaron.outline : chip - 12)
    }

    /// The held instrument's width, or nil where there is none to set.
    private var heldWidth: ToolWidth? {
        switch editor.tool {
        case .ink(_, let preset): preset.width
        case .erasePixel(let width): width
        case .eraseObject, .lasso, .text: nil
        }
    }

    private var heldColor: ToolColor? {
        if case .ink(_, let preset) = editor.tool { return preset.color }
        return nil
    }

    @ViewBuilder private var widths: some View {
        ForEach(ToolWidth.allCases, id: \.self) { width in
            let held = heldWidth == width
            Button { editor.setWidth(width) } label: {
                Circle()
                    .fill(held ? Color.white : Macaron.ink)
                    .frame(width: Self.diameter(width), height: Self.diameter(width))
            }
            .buttonStyle(MacaronChipStyle(isOn: held, size: chip))
            .disabled(heldWidth == nil)
        }
    }

    private static func diameter(_ width: ToolWidth) -> CGFloat {
        switch width {
        case .thin: 6
        case .medium: 12
        case .thick: 20
        }
    }

    /// Seven defaults. A column is too tall at one swatch wide, so it stacks
    /// them two wide.
    @ViewBuilder private var swatches: some View {
        let colors = ToolColor.defaults
        if vertical {
            LazyVGrid(columns: [GridItem(.fixed(BarMetrics.swatch), spacing: 6), GridItem(.fixed(BarMetrics.swatch), spacing: 6)], spacing: 6) {
                ForEach(colors, id: \.rgba.hex) { swatch($0) }
            }
            .padding(.horizontal, 2)
        } else {
            ForEach(colors, id: \.rgba.hex) { swatch($0) }
        }
    }

    private func swatch(_ color: ToolColor) -> some View {
        let held = heldColor == color
        return Button { editor.setColor(color) } label: {
            Circle()
                .fill(Color(color.uiColor))
                .frame(width: BarMetrics.swatch, height: BarMetrics.swatch)
                .background(Circle().fill(Macaron.ink).offset(x: held ? 3 : 0, y: held ? 3 : 0))
                .overlay(Circle().strokeBorder(Macaron.ink, lineWidth: Macaron.outline))
        }
        .buttonStyle(.plain)
        .disabled(heldColor == nil)
        .opacity(heldColor == nil ? 0.35 : 1)
        .accessibilityLabel(color.rgba.hex)
    }

    private var pill: some View {
        Capsule()
            .fill(Macaron.ink)
            .frame(width: vertical ? 22 : 6, height: vertical ? 6 : 22)
            .frame(width: vertical ? chip : 24, height: vertical ? 24 : chip)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("editor"))
                    .onChanged(onDragChanged)
                    .onEnded(onDragEnded)
            )
            .accessibilityLabel("Move the tools")
    }
}
