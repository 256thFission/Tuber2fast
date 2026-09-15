import SwiftUI
import TNEditor
import TNModel

// PROTOTYPE: the instrument cluster. One card, two arrangements, snaps or
// floats. Docked is an inset; floating is an overlay.

enum ClusterEdge: String, Codable { case leading, trailing, top, bottom
    var isVertical: Bool { self == .leading || self == .trailing }
}

enum ClusterPlacement: Codable, Equatable {
    case snapped(ClusterEdge)
    /// Fractions of the viewport, never points.
    case floating(fx: CGFloat, fy: CGFloat)

    var isFloating: Bool { if case .floating = self { return true } else { return false } }

    static func key(landscape: Bool) -> String { "macaron.cluster.\(landscape ? "landscape" : "portrait")" }

    static func load(landscape: Bool) -> ClusterPlacement? {
        guard let data = UserDefaults.standard.data(forKey: key(landscape: landscape)) else { return nil }
        return try? JSONDecoder().decode(ClusterPlacement.self, from: data)
    }

    func save(landscape: Bool) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(landscape: landscape))
    }

    /// Rule 1: slack is on the axis where page and iPad disagree.
    static func proposed(page: PageGeometry, viewport: CGSize) -> ClusterPlacement {
        let pageAspect = CGFloat(page.width / page.height)
        let viewportAspect = viewport.width / viewport.height
        return pageAspect < viewportAspect ? .snapped(.leading) : .snapped(.bottom)
    }
}

enum ClusterMetrics {
    static let thickness: CGFloat = 56
    static let ribbonThickness: CGFloat = 44
    static let chip: CGFloat = 42
    static let smallChip: CGFloat = 36
    static let snapDistance: CGFloat = 60

    /// Points of slack left beside the fitted page on the given edge.
    static func slack(on edge: ClusterEdge, page: PageGeometry, viewport: CGSize) -> CGFloat {
        let scale = min(viewport.width / CGFloat(page.width), viewport.height / CGFloat(page.height))
        return edge.isVertical
            ? viewport.width - CGFloat(page.width) * scale
            : viewport.height - CGFloat(page.height) * scale
    }
}

/// The cluster itself: pill, six tools, a bar, undo. Only the pill drags.
struct ClusterView: View {
    let editor: EditorViewModel
    let vertical: Bool
    let chip: CGFloat
    let floating: Bool
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    var body: some View {
        Group {
            if vertical {
                VStack(spacing: 8) { contents }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 5)
            } else {
                HStack(spacing: 8) { contents }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
        }
        .macaronCard(fill: Macaron.card, radius: 14, shadow: floating ? 6 : 0)
    }

    @ViewBuilder private var contents: some View {
        pill
        ToolStrip(editor: editor, vertical: vertical, chip: chip)
        Rectangle().fill(Macaron.ink)
            .frame(width: vertical ? chip - 12 : Macaron.outline, height: vertical ? Macaron.outline : chip - 12)
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
