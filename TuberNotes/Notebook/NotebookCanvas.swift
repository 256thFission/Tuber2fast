import PencilKit
import SwiftUI
import UIKit

/// GoodNotes-style page: a fixed-size portrait sheet that scrolls vertically.
/// PencilKit's canvas is itself a scroll view, so we size its content to the
/// page and let the finger pan/scroll while the Pencil draws.
struct NotebookCanvas: UIViewRepresentable {
    let pageID: UUID
    let drawingData: Data
    let tool: WritingTool
    let color: UIColor
    let width: CGFloat
    var onChange: (Data) -> Void
    var onLongPress: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onLongPress: onLongPress)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PageCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Pencil draws; a single finger scrolls the tall page (GoodNotes feel).
        // Switch to `.anyInput` if you want to draw with a finger too — but then
        // one-finger scrolling of the page is no longer available.
        canvas.drawingPolicy = .pencilOnly
        canvas.alwaysBounceVertical = true
        canvas.showsVerticalScrollIndicator = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.delegate = context.coordinator
        canvas.tool = tool.pkTool(color: color, width: width)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.55
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
        canvas.tool = tool.pkTool(color: color, width: width)

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
            DispatchQueue.main.async { self.isLoading = false }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isLoading else { return }
            onChange(canvasView.drawing.dataRepresentation())
        }

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            if gr.state == .began { onLongPress() }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// MARK: - Page canvas + ruled paper

/// PKCanvasView sized to a fixed portrait sheet, centered horizontally, with a
/// ruled-paper background drawn behind the ink and scrolling with the content.
private final class PageCanvasView: PKCanvasView {
    private let paper = PaperSheetView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        paper.isUserInteractionEnabled = false
        paper.backgroundColor = .clear
        addSubview(paper)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        paper.isUserInteractionEnabled = false
        addSubview(paper)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let page = NotebookPageLayout.size
        contentSize = page
        paper.frame = CGRect(origin: .zero, size: page)
        sendSubviewToBack(paper)

        let hInset = max(0, (bounds.width - page.width) / 2)
        contentInset = UIEdgeInsets(top: 16, left: hInset, bottom: 140, right: hInset)
    }
}

/// White ruled sheet with a margin line, drawn in page-space coordinates.
private final class PaperSheetView: UIView {
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(bounds)

        ctx.setStrokeColor(UIColor(red: 0.60, green: 0.72, blue: 0.90, alpha: 0.5).cgColor)
        ctx.setLineWidth(1)
        var y = NotebookPageLayout.lineSpacing
        while y < bounds.height {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            y += NotebookPageLayout.lineSpacing
        }
        ctx.strokePath()

        ctx.setStrokeColor(UIColor(red: 0.90, green: 0.45, blue: 0.45, alpha: 0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: NotebookPageLayout.marginX, y: 0))
        ctx.addLine(to: CGPoint(x: NotebookPageLayout.marginX, y: bounds.height))
        ctx.strokePath()
    }
}
