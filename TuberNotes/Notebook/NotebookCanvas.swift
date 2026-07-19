import PencilKit
import SwiftUI
import UIKit

/// Product drawing surface for a single page. Unlike the DEBUG `PencilCanvas`,
/// this is not entangled with fixture recording — it just reads/writes a page's
/// serialized `PKDrawing`, applies the selected tool, and reports long presses
/// so the parent can open the page navigator.
struct NotebookCanvas: UIViewRepresentable {
    let pageID: UUID
    let drawingData: Data
    let tool: WritingTool
    let inkColor: InkColor
    let strokeWidth: CGFloat
    var onChange: (Data) -> Void
    var onLongPress: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onLongPress: onLongPress)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput          // switch to `.pencilOnly` for Pencil-only input
        canvas.delegate = context.coordinator
        canvas.tool = tool.pkTool(color: inkColor.uiColor, width: strokeWidth)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false
        longPress.delegate = context.coordinator
        canvas.addGestureRecognizer(longPress)

        context.coordinator.load(drawingData, into: canvas, pageID: pageID)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onLongPress = onLongPress
        canvas.tool = tool.pkTool(color: inkColor.uiColor, width: strokeWidth)

        if context.coordinator.loadedPageID != pageID {
            context.coordinator.load(drawingData, into: canvas, pageID: pageID)
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var onChange: (Data) -> Void
        var onLongPress: () -> Void
        private(set) var loadedPageID: UUID?
        private var isLoading = false

        init(onChange: @escaping (Data) -> Void, onLongPress: @escaping () -> Void) {
            self.onChange = onChange
            self.onLongPress = onLongPress
        }

        func load(_ data: Data, into canvas: PKCanvasView, pageID: UUID) {
            isLoading = true
            canvas.drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
            loadedPageID = pageID
            // Ignore the change callback triggered by the programmatic assignment.
            DispatchQueue.main.async { self.isLoading = false }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isLoading else { return }
            onChange(canvasView.drawing.dataRepresentation())
        }

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            if gr.state == .began { onLongPress() }
        }

        // Let the long-press coexist with PencilKit's own drawing gestures.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
