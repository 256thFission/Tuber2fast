import SwiftUI

struct SpatialCanvasView: View {
    let pins: [Pin]
    let penFixture: PenFixture?

    var body: some View {
        ZStack {
            NotebookPaper()
            PencilCanvas(penFixture: penFixture)
            PinOverlayView(pins: pins)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
        .padding(20)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("spatial-canvas")
    }
}

private struct NotebookPaper: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var lines = Path()
            stride(from: 36.0, through: size.height, by: 36.0).forEach { y in
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(.blue.opacity(0.12)), lineWidth: 1)
        }
    }
}

