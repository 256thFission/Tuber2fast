import PencilKit
import SwiftUI

/// Compatibility wrapper for the original one-page scaffold. New paged surfaces use
/// `PagePencilCanvas`, below, so a page's stable identity owns its drawing bytes.
struct PencilCanvas: UIViewRepresentable {
    let penFixture: PenFixture?
#if DEBUG
    @EnvironmentObject private var agentSession: AgentInteractionSession
#endif

    func makeCoordinator() -> Coordinator {
#if DEBUG
        Coordinator(session: agentSession)
#else
        Coordinator()
#endif
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = FixtureCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // The canvas sits on permanently white paper, so PencilKit must not
        // appearance-adjust ink when the surrounding app enters dark mode.
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.delegate = context.coordinator
        context.coordinator.canvas = canvas
        canvas.pendingFixture = penFixture

        DispatchQueue.main.async {
            guard canvas.window != nil else { return }
            let picker = PKToolPicker()
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            canvas.becomeFirstResponder()
            context.coordinator.toolPicker = picker
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
#if DEBUG
        context.coordinator.session = agentSession
#endif
        guard context.coordinator.loadedFixtureName != penFixture?.name else { return }
        (canvas as? FixtureCanvasView)?.pendingFixture = penFixture
        context.coordinator.loadedFixtureName = penFixture?.name
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        weak var canvas: PKCanvasView?
        var toolPicker: PKToolPicker?
        var loadedFixtureName: String?
#if DEBUG
        var session: AgentInteractionSession

        init(session: AgentInteractionSession) {
            self.session = session
            super.init()
        }
#else
        override init() {
            super.init()
        }
#endif

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
#if DEBUG
            Task { @MainActor in
                session.handleDrawingChange(drawing: canvasView.drawing, canvasSize: canvasView.bounds.size)
            }
#endif
        }
    }
}

private final class FixtureCanvasView: PKCanvasView {
    var pendingFixture: PenFixture? {
        didSet { setNeedsLayout() }
    }
    private var appliedFixtureName: String?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0,
              bounds.height > 0,
              let pendingFixture,
              appliedFixtureName != pendingFixture.name else { return }
        drawing = pendingFixture.makeDrawing(in: bounds.size)
        appliedFixtureName = pendingFixture.name
    }
}

/// PencilKit adapter used by each stable page in `SpatialCanvasView`.
/// Finger input remains available to the containing pager/zoom viewport.
struct PagePencilCanvas: UIViewRepresentable {
    let pageID: UUID
    let drawingData: Data?
    let toolMode: CanvasToolMode
    let penFixture: PenFixture?
    let onDrawingChanged: (UUID, Data) -> Void
    let onDrawingSnapshot: (UUID, PKDrawing, CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pageID: pageID,
            onDrawingChanged: onDrawingChanged,
            onDrawingSnapshot: onDrawingSnapshot
        )
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PageFixtureCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.delegate = context.coordinator
        canvas.initialDrawingData = drawingData
        canvas.pendingFixture = penFixture
        apply(toolMode, to: canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.pageID = pageID
        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.onDrawingSnapshot = onDrawingSnapshot
        apply(toolMode, to: canvas)

        if let drawingData,
           canvas.drawing.dataRepresentation() != drawingData,
           let drawing = try? PKDrawing(data: drawingData) {
            context.coordinator.isApplyingExternalDrawing = true
            canvas.drawing = drawing
            context.coordinator.isApplyingExternalDrawing = false
        }

        guard let fixtureCanvas = canvas as? PageFixtureCanvasView else { return }
        if fixtureCanvas.pendingFixture?.name != penFixture?.name {
            fixtureCanvas.pendingFixture = penFixture
        }
    }

    private func apply(_ mode: CanvasToolMode, to canvas: PKCanvasView) {
        switch mode {
        case .ink:
            canvas.isUserInteractionEnabled = true
            canvas.tool = PKInkingTool(.pen, color: .label, width: 3)
        case .erase:
            canvas.isUserInteractionEnabled = true
            canvas.tool = PKEraserTool(.vector)
        case .magicLasso, .navigate:
            canvas.isUserInteractionEnabled = false
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var pageID: UUID
        var onDrawingChanged: (UUID, Data) -> Void
        var onDrawingSnapshot: (UUID, PKDrawing, CGSize) -> Void
        var isApplyingExternalDrawing = false

        init(
            pageID: UUID,
            onDrawingChanged: @escaping (UUID, Data) -> Void,
            onDrawingSnapshot: @escaping (UUID, PKDrawing, CGSize) -> Void
        ) {
            self.pageID = pageID
            self.onDrawingChanged = onDrawingChanged
            self.onDrawingSnapshot = onDrawingSnapshot
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalDrawing else { return }
            onDrawingChanged(pageID, canvasView.drawing.dataRepresentation())
            onDrawingSnapshot(pageID, canvasView.drawing, canvasView.bounds.size)
        }
    }
}

private final class PageFixtureCanvasView: PKCanvasView {
    var initialDrawingData: Data?
    var pendingFixture: PenFixture? {
        didSet { setNeedsLayout() }
    }

    private var didApplyInitialContent = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didApplyInitialContent, bounds.width > 0, bounds.height > 0 else { return }
        didApplyInitialContent = true

        if let initialDrawingData, let restored = try? PKDrawing(data: initialDrawingData) {
            drawing = restored
        } else if let pendingFixture {
            drawing = pendingFixture.makeDrawing(in: bounds.size)
        }
    }
}
