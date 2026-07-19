import PencilKit
import SwiftUI
import UIKit

/// GoodNotes-style page with pinch/button zoom. The PencilKit canvas and the
/// ruled paper live inside a shared zooming content view so they scale together
/// and stay aligned. Pencil draws; a finger pans/zooms (unless finger-drawing is
/// on, in which case a finger draws and two fingers pan).
///
/// Lasso mode overlays a selection tool: drawing a loop marks a region that the
/// assistant analyzes in isolation.
struct NotebookCanvas: UIViewRepresentable {
    let pageID: UUID
    let drawingData: Data
    let tool: WritingTool
    let color: UIColor
    let width: CGFloat
    let template: PageTemplate
    let zoomScale: CGFloat
    let fingerDrawing: Bool
    let isLassoActive: Bool
    let lassoRect: CGRect?
    var onChange: (Data) -> Void
    var onLongPress: () -> Void
    var onZoomChanged: (CGFloat) -> Void
    var onLassoChanged: (CGRect?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ZoomablePageView {
        let view = ZoomablePageView()
        view.scrollView.delegate = context.coordinator
        view.canvasView.delegate = context.coordinator
        view.canvasView.tool = tool.pkTool(color: color, width: width)
        view.paperView.template = template

        let onLasso = onLassoChanged
        view.lassoView.onFinished = { rect in
            guard let r = rect else { onLasso(nil); return }
            let page = NotebookPageLayout.size
            onLasso(CGRect(x: r.minX / page.width, y: r.minY / page.height,
                           width: r.width / page.width, height: r.height / page.height))
        }

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.longPress(_:))
        )
        longPress.minimumPressDuration = 0.55
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        view.scrollView.addGestureRecognizer(longPress)

        applyMode(to: view)
        context.coordinator.load(drawingData, pageID: pageID, into: view)
        view.scrollView.setZoomScale(zoomScale, animated: false)
        return view
    }

    func updateUIView(_ view: ZoomablePageView, context: Context) {
        context.coordinator.parent = self
        view.canvasView.tool = tool.pkTool(color: color, width: width)
        if view.paperView.template != template {
            view.paperView.template = template
            view.paperView.setNeedsDisplay()
        }
        applyMode(to: view)
        if lassoRect == nil { view.lassoView.clear() }
        if context.coordinator.loadedPageID != pageID {
            context.coordinator.load(drawingData, pageID: pageID, into: view)
        }
        if abs(view.scrollView.zoomScale - zoomScale) > 0.001 {
            view.scrollView.setZoomScale(zoomScale, animated: true)
        }
    }

    private func applyMode(to view: ZoomablePageView) {
        view.canvasView.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        view.scrollView.panGestureRecognizer.minimumNumberOfTouches = fingerDrawing ? 2 : 1

        view.lassoView.isHidden = !isLassoActive
        view.lassoView.isUserInteractionEnabled = isLassoActive
        view.canvasView.isUserInteractionEnabled = !isLassoActive
        view.scrollView.isScrollEnabled = !isLassoActive
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: NotebookCanvas
        weak var view: ZoomablePageView?
        private(set) var loadedPageID: UUID?
        private var isLoading = false

        init(_ parent: NotebookCanvas) { self.parent = parent }

        func load(_ data: Data, pageID: UUID, into view: ZoomablePageView) {
            self.view = view
            isLoading = true
            view.canvasView.drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
            loadedPageID = pageID
            DispatchQueue.main.async { self.isLoading = false }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isLoading else { return }
            parent.onChange(canvasView.drawing.dataRepresentation())
        }

        // Zoom
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view?.contentView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { view?.recenter() }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            parent.onZoomChanged(scale)
        }

        @objc func longPress(_ gr: UILongPressGestureRecognizer) {
            if gr.state == .began { parent.onLongPress() }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// MARK: - Zooming container

/// Hosts a scroll view whose zooming content holds the paper, the PencilKit
/// canvas, and the lasso overlay.
final class ZoomablePageView: UIView {
    let scrollView = UIScrollView()
    let contentView = UIView()
    let paperView = PaperSheetView()
    let canvasView = PKCanvasView()
    let lassoView = LassoOverlayView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceVertical = true
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 5
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        let page = NotebookPageLayout.size
        contentView.frame = CGRect(origin: .zero, size: page)
        scrollView.contentSize = page
        scrollView.addSubview(contentView)

        // Soft shadow so the white page floats on the dark backdrop.
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.45
        contentView.layer.shadowRadius = 22
        contentView.layer.shadowOffset = CGSize(width: 0, height: 10)
        contentView.layer.shadowPath = UIBezierPath(rect: CGRect(origin: .zero, size: page)).cgPath

        paperView.frame = contentView.bounds
        paperView.isUserInteractionEnabled = false
        paperView.layer.cornerRadius = 3
        paperView.layer.masksToBounds = true
        contentView.addSubview(paperView)

        canvasView.frame = contentView.bounds
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isScrollEnabled = false
        // Keep ink colors exactly as chosen (no dark-mode remap on the white page).
        canvasView.overrideUserInterfaceStyle = .light
        contentView.addSubview(canvasView)

        lassoView.frame = contentView.bounds
        lassoView.isHidden = true
        contentView.addSubview(lassoView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        recenter()
    }

    func recenter() {
        let page = NotebookPageLayout.size
        let scaledW = page.width * scrollView.zoomScale
        let scaledH = page.height * scrollView.zoomScale
        let hInset = max(0, (scrollView.bounds.width - scaledW) / 2)
        let vInset = max(16, (scrollView.bounds.height - scaledH) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vInset, left: hInset, bottom: 140, right: hInset)
    }
}

// MARK: - Lasso overlay

/// Transparent overlay (in page space) that captures a freeform loop and reports
/// its bounding rect. Draws animated "marching ants" while a region is selected.
final class LassoOverlayView: UIView {
    private let shapeLayer = CAShapeLayer()
    private var points: [CGPoint] = []
    var onFinished: ((CGRect?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shapeLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.10).cgColor
        shapeLayer.strokeColor = UIColor.systemBlue.cgColor
        shapeLayer.lineWidth = 2
        shapeLayer.lineDashPattern = [6, 4]
        shapeLayer.lineJoin = .round
        layer.addSublayer(shapeLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        let p = gr.location(in: self)
        switch gr.state {
        case .began:
            points = [p]
            startMarching()
        case .changed:
            points.append(p)
            updatePath(closed: false)
        case .ended, .cancelled:
            updatePath(closed: true)
            onFinished?(boundingRect())
        default:
            break
        }
    }

    private func updatePath(closed: Bool) {
        guard let first = points.first else { shapeLayer.path = nil; return }
        let path = UIBezierPath()
        path.move(to: first)
        for pt in points.dropFirst() { path.addLine(to: pt) }
        if closed { path.close() }
        shapeLayer.path = path.cgPath
    }

    private func boundingRect() -> CGRect? {
        guard points.count > 2 else { clear(); return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard rect.width > 12, rect.height > 12 else { clear(); return nil }
        return rect
    }

    func clear() {
        points = []
        shapeLayer.path = nil
    }

    private func startMarching() {
        guard shapeLayer.animation(forKey: "march") == nil else { return }
        let anim = CABasicAnimation(keyPath: "lineDashPhase")
        anim.fromValue = 0
        anim.toValue = 10
        anim.duration = 0.45
        anim.repeatCount = .infinity
        shapeLayer.add(anim, forKey: "march")
    }
}

// MARK: - Ruled paper

/// White sheet drawn per `PageTemplate`. Lives inside the zooming content, so it
/// scales with the ink.
final class PaperSheetView: UIView {
    var template: PageTemplate = .linedMedium { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(bounds)

        guard template.spacing > 0 else { return }
        let spacing = template.spacing
        let lineColor = UIColor(red: 0.62, green: 0.72, blue: 0.88, alpha: 0.55)
        ctx.setStrokeColor(lineColor.cgColor)
        ctx.setLineWidth(1)

        var y = spacing
        while y < bounds.height {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            y += spacing
        }

        if template.isGrid {
            var x = spacing
            while x < bounds.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
                x += spacing
            }
        }
        ctx.strokePath()

        if template.isLined {
            ctx.setStrokeColor(UIColor(red: 0.90, green: 0.45, blue: 0.45, alpha: 0.5).cgColor)
            ctx.move(to: CGPoint(x: 60, y: 0))
            ctx.addLine(to: CGPoint(x: 60, y: bounds.height))
            ctx.strokePath()
        }
    }
}
