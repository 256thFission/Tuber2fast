import PencilKit
import SwiftUI
import UIKit

/// GoodNotes-style page with pinch/button zoom. Ruled paper, placed images, the
/// PencilKit canvas, and the lasso overlay share one zooming content view.
///
/// The lasso works like a traditional lasso: loop around strokes to select them,
/// then drag inside to move them.
struct NotebookCanvas: UIViewRepresentable {
    let pageID: UUID
    let drawingData: Data
    let backgroundDrawingData: Data
    let tool: WritingTool
    let color: UIColor
    let width: CGFloat
    let template: PageTemplate
    let zoomScale: CGFloat
    let fingerDrawing: Bool
    let isLassoActive: Bool
    let lassoRect: CGRect?
    let snapStraight: Bool
    let images: [PlacedImage]
    let isArrangingImages: Bool
    let selectedImageID: UUID?
    let isPageLocked: Bool
    let undo: NotebookUndoBridge
    let pencilDoubleTapEnabled: Bool
    let pencilSqueezeEnabled: Bool
    let pencilHoverPreviewEnabled: Bool
    var onChange: (Data) -> Void
    var onPencilToggleEraser: () -> Void
    var onPencilSwapTool: () -> Void
    /// Point is in global screen space so the SwiftUI layer can clamp the
    /// palette independently of page padding, pan, and zoom.
    var onPencilShowPalette: (CGPoint, Bool) -> Void
    var onLongPress: () -> Void
    var onZoomChanged: (CGFloat) -> Void
    var onLassoChanged: (CGRect?) -> Void
    var onImagesChanged: ([PlacedImage]) -> Void
    var onSelectImage: (UUID?) -> Void
    var onFlipChanged: (CGFloat) -> Void
    var onFlipEnded: (CGFloat, CGFloat) -> Void
    var onPageViewportChange: (CGRect) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ZoomablePageView {
        let view = ZoomablePageView()
        view.scrollView.delegate = context.coordinator
        view.canvasView.delegate = context.coordinator
        view.canvasView.tool = tool.pkTool(color: color, width: width)
        view.paperView.template = template
        view.setBackgroundDrawingData(backgroundDrawingData)
        view.onPageViewportChange = onPageViewportChange

        let c = context.coordinator
        view.lassoView.onLoopComplete = { [weak c, weak view] points in c?.completeLasso(points, view) }
        view.lassoView.beginMoveIfInside = { [weak c, weak view] p in c?.beginMove(at: p, view) ?? false }
        view.lassoView.onMove = { [weak c, weak view] delta in c?.moveSelection(by: delta, view) }
        view.lassoView.onMoveEnded = { [weak c, weak view] in c?.commitMove(view) }

        view.imageLayer.onChange = onImagesChanged
        view.imageLayer.onSelect = onSelectImage
        view.imageLayer.setImages(images)

        view.straightenRecognizer.delegate = context.coordinator
        view.straightenRecognizer.onHoldStraighten = { [weak c, weak view] start, end in
            c?.straighten(from: start, to: end, in: view)
        }

        view.hoverRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.hover(_:)))

        let pencil = view.pencilController
        pencil.onToggleEraser = { [weak c] in c?.parent.onPencilToggleEraser() }
        pencil.onSwapPreviousTool = { [weak c] in c?.parent.onPencilSwapTool() }
        pencil.onShowColorPalette = { [weak c, weak view] point in
            guard let c, let view else { return }
            c.parent.onPencilShowPalette(view.convertToScreen(point), true)
        }
        pencil.onSqueeze = { [weak c, weak view] point in
            guard let c, let view else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            c.parent.onPencilShowPalette(view.convertToScreen(point), false)
        }
        pencil.fallbackPoint = { [weak c, weak view] in
            guard let view else { return .zero }
            if let lastPoint = c?.lastHoverPoint {
                return view.contentView.convert(lastPoint, to: view)
            }
            return CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        }

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.longPress(_:))
        )
        longPress.minimumPressDuration = 0.55
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        view.scrollView.addGestureRecognizer(longPress)

        // Pencil always belongs to the drawing surface; page pan and turn
        // gestures accept direct (finger) touches only.
        let fingerOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        view.scrollView.panGestureRecognizer.allowedTouchTypes = fingerOnly

        let flipPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleFlipPan(_:))
        )
        flipPan.allowedTouchTypes = fingerOnly
        flipPan.maximumNumberOfTouches = 1
        flipPan.delegate = context.coordinator
        view.scrollView.addGestureRecognizer(flipPan)
        context.coordinator.flipPan = flipPan

        view.undoBridge = undo

        applyMode(to: view)
        context.coordinator.load(drawingData, pageID: pageID, into: view)
        view.scrollView.setZoomScale(zoomScale, animated: false)
        DispatchQueue.main.async { view.reportPageViewport() }
        return view
    }

    func updateUIView(_ view: ZoomablePageView, context: Context) {
        context.coordinator.parent = self
        view.canvasView.tool = tool.pkTool(color: color, width: width)
        if view.paperView.template != template {
            view.paperView.template = template
            view.paperView.setNeedsDisplay()
        }
        view.imageLayer.setImages(images)
        view.setBackgroundDrawingData(backgroundDrawingData)
        view.onPageViewportChange = onPageViewportChange
        applyMode(to: view)
        if !isLassoActive || lassoRect == nil {
            view.lassoView.clear()
            context.coordinator.clearLassoSelection()
        }
        if context.coordinator.loadedPageID != pageID
            || context.coordinator.loadedDrawingData != drawingData {
            context.coordinator.load(drawingData, pageID: pageID, into: view)
        }
        // Viewport reporting re-enters this update on every pinch frame. The
        // bound scale intentionally settles when the gesture ends, so never
        // feed that temporarily stale value back into the active UIKit zoom.
        context.coordinator.applyBoundZoomScale(zoomScale, to: view)
    }

    private func applyMode(to view: ZoomablePageView) {
        view.canvasView.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        view.scrollView.panGestureRecognizer.minimumNumberOfTouches = fingerDrawing ? 2 : 1

        view.lassoView.isHidden = !isLassoActive
        view.lassoView.isUserInteractionEnabled = isLassoActive

        view.imageLayer.isEditing = isArrangingImages
        view.imageLayer.selectedID = selectedImageID

        let interacting = isLassoActive || isArrangingImages
        view.canvasView.isUserInteractionEnabled = !interacting
        view.scrollView.isScrollEnabled = !interacting && !isPageLocked
        view.scrollView.pinchGestureRecognizer?.isEnabled = !interacting && !isPageLocked

        view.straightenRecognizer.acceptsFinger = fingerDrawing
        view.straightenRecognizer.isEnabled = snapStraight && !interacting && tool != .eraser

        view.pencilController.isDoubleTapEnabled = pencilDoubleTapEnabled
        view.pencilController.isSqueezeEnabled = pencilSqueezeEnabled

        let showsHoverPreview = pencilHoverPreviewEnabled
            && PencilInteractionController.prefersHoverPreview
            && !interacting
        view.hoverRecognizer.isEnabled = showsHoverPreview
        if !showsHoverPreview { view.hoverPreview.hide() }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: NotebookCanvas
        weak var view: ZoomablePageView?
        weak var flipPan: UIPanGestureRecognizer?
        private(set) var loadedPageID: UUID?
        private(set) var loadedDrawingData = Data()
        private var isLoading = false
        private var isProgrammatic = false
        private(set) var isUserZooming = false
        private var programmaticZoomTarget: CGFloat?
        private var lassoSelection: [Int] = []
        private var movingStrokes: [PKStroke] = []
        private var moveTranslation: CGPoint = .zero
        private var preMoveDrawing: PKDrawing?
        private(set) var lastHoverPoint: CGPoint?

        init(_ parent: NotebookCanvas) { self.parent = parent }

        func load(_ data: Data, pageID: UUID, into view: ZoomablePageView) {
            self.view = view
            isLoading = true
            parent.undo.withoutRegistration {
                view.canvasView.drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
            }
            parent.undo.reset()
            loadedPageID = pageID
            loadedDrawingData = data
            lassoSelection = []
            DispatchQueue.main.async { self.isLoading = false }
        }

        /// Replaces the active drawing as one undoable operation. Undo calls
        /// back through the same path, which registers the matching redo.
        func applyDrawing(_ drawing: PKDrawing, to view: ZoomablePageView, actionName: String) {
            let previousDrawing = view.canvasView.drawing
            parent.undo.withoutRegistration {
                isProgrammatic = true
                view.canvasView.drawing = drawing
                isProgrammatic = false
            }

            parent.undo.manager.registerUndo(withTarget: self) { target in
                target.applyDrawing(previousDrawing, to: view, actionName: actionName)
            }
            parent.undo.manager.setActionName(actionName)

            let data = drawing.dataRepresentation()
            loadedDrawingData = data
            parent.onChange(data)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isLoading, !isProgrammatic else { return }
            let data = canvasView.drawing.dataRepresentation()
            loadedDrawingData = data
            parent.onChange(data)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            view?.hoverPreview.hide()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {}

        @objc func hover(_ recognizer: UIHoverGestureRecognizer) {
            guard let view else { return }
            switch recognizer.state {
            case .began, .changed:
                // Trackpad and pointer hover report no Pencil distance.
                guard recognizer.zOffset > 0 else {
                    view.hoverPreview.hide()
                    return
                }
                let point = recognizer.location(in: view.contentView)
                lastHoverPoint = point
                view.hoverPreview.show(
                    at: point,
                    tool: parent.tool,
                    color: parent.color,
                    width: parent.width
                )
            case .ended, .cancelled, .failed:
                view.hoverPreview.hide()
            default:
                break
            }
        }

        // MARK: Lasso (select + move)

        func clearLassoSelection() { lassoSelection = [] }

        func completeLasso(_ points: [CGPoint], _ view: ZoomablePageView?) {
            guard let view, points.count > 2 else { return }
            let drawing = view.canvasView.drawing
            lassoSelection = strokesInside(polygon: points, drawing: drawing)

            var rect = CGRect.null
            for i in lassoSelection where drawing.strokes.indices.contains(i) {
                rect = rect.union(drawing.strokes[i].renderBounds)
            }
            if rect.isNull {
                let xs = points.map(\.x), ys = points.map(\.y)
                rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }
            rect = rect.insetBy(dx: -8, dy: -8)

            view.lassoView.showSelection(rect)
            parent.onLassoChanged(normalize(rect))
        }

        /// Lift the selected strokes into a lightweight image so dragging is cheap.
        func beginMove(at point: CGPoint, _ view: ZoomablePageView?) -> Bool {
            guard let view, !lassoSelection.isEmpty else { return false }
            let drawing = view.canvasView.drawing
            let selected = lassoSelection.compactMap { drawing.strokes.indices.contains($0) ? drawing.strokes[$0] : nil }
            guard !selected.isEmpty else { return false }

            let temp = PKDrawing(strokes: selected)
            let bounds = temp.bounds
            guard !bounds.isNull else { return false }

            var image: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = temp.image(from: bounds, scale: UIScreen.main.scale)
            }
            view.moveImageView.image = image
            view.moveImageView.frame = bounds
            view.moveImageView.isHidden = false

            var remaining = drawing
            remaining.strokes = drawing.strokes.enumerated()
                .filter { !lassoSelection.contains($0.offset) }
                .map { $0.element }
            preMoveDrawing = drawing
            parent.undo.withoutRegistration {
                isProgrammatic = true
                view.canvasView.drawing = remaining
                isProgrammatic = false
            }

            movingStrokes = selected
            moveTranslation = .zero
            return true
        }

        func moveSelection(by delta: CGPoint, _ view: ZoomablePageView?) {
            guard let view, !movingStrokes.isEmpty else { return }
            moveTranslation.x += delta.x
            moveTranslation.y += delta.y
            view.moveImageView.center = CGPoint(x: view.moveImageView.center.x + delta.x,
                                                y: view.moveImageView.center.y + delta.y)
        }

        func commitMove(_ view: ZoomablePageView?) {
            guard let view, !movingStrokes.isEmpty else { return }
            let translate = CGAffineTransform(translationX: moveTranslation.x, y: moveTranslation.y)
            var drawing = view.canvasView.drawing
            let baseCount = drawing.strokes.count
            var moved = movingStrokes
            for i in moved.indices { moved[i].transform = moved[i].transform.concatenating(translate) }
            drawing.strokes.append(contentsOf: moved)

            parent.undo.withoutRegistration {
                isProgrammatic = true
                view.canvasView.drawing = drawing
                isProgrammatic = false
            }

            if let drawingBeforeMove = preMoveDrawing {
                parent.undo.manager.registerUndo(withTarget: self) { target in
                    target.applyDrawing(drawingBeforeMove, to: view, actionName: "Move Selection")
                }
                parent.undo.manager.setActionName("Move Selection")
            }
            preMoveDrawing = nil

            lassoSelection = Array(baseCount..<drawing.strokes.count)
            view.moveImageView.isHidden = true
            view.moveImageView.image = nil
            movingStrokes = []
            let data = drawing.dataRepresentation()
            loadedDrawingData = data
            parent.onChange(data)

            var rect = CGRect.null
            for i in lassoSelection where drawing.strokes.indices.contains(i) {
                rect = rect.union(drawing.strokes[i].renderBounds)
            }
            if !rect.isNull {
                rect = rect.insetBy(dx: -8, dy: -8)
                view.lassoView.showSelection(rect)
                parent.onLassoChanged(normalize(rect))
            }
        }

        private func normalize(_ rect: CGRect) -> CGRect {
            let page = NotebookPageLayout.size
            return CGRect(x: rect.minX / page.width, y: rect.minY / page.height,
                          width: rect.width / page.width, height: rect.height / page.height)
        }

        // MARK: Hold-to-straighten

        func straighten(from start: CGPoint, to end: CGPoint, in view: ZoomablePageView?) {
            guard let view else { return }
            let p = parent
            guard !p.isLassoActive, !p.isArrangingImages, p.tool != .eraser else { return }
            guard hypot(end.x - start.x, end.y - start.y) > 12 else { return }

            DispatchQueue.main.async {
                var drawing = view.canvasView.drawing
                guard !drawing.strokes.isEmpty else { return }
                drawing.strokes.removeLast()

                let inkType: PKInk.InkType = p.tool == .pencil ? .pencil : (p.tool == .marker ? .marker : .pen)
                var color = p.color
                if p.tool == .marker { color = color.withAlphaComponent(0.4) }
                let ink = PKInk(inkType, color: color)
                let w = p.width

                func point(_ location: CGPoint, _ t: TimeInterval) -> PKStrokePoint {
                    PKStrokePoint(location: location, timeOffset: t,
                                  size: CGSize(width: w, height: w),
                                  opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                let path = PKStrokePath(controlPoints: [point(start, 0), point(end, 0.05)], creationDate: Date())
                drawing.strokes.append(PKStroke(ink: ink, path: path))

                self.applyDrawing(drawing, to: view, actionName: "Straighten")
            }
        }

        // MARK: Zoom

        func applyBoundZoomScale(_ scale: CGFloat, to view: ZoomablePageView) {
            guard !isUserZooming,
                  abs(view.scrollView.zoomScale - scale) > 0.001 else { return }
            if let programmaticZoomTarget,
               abs(programmaticZoomTarget - scale) <= 0.001 {
                return
            }
            programmaticZoomTarget = scale
            view.scrollView.setZoomScale(scale, animated: true)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view?.contentView }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            programmaticZoomTarget = nil
            isUserZooming = true
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { view?.reportPageViewport() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Do not mutate contentInset while UIKit is actively zooming.  The
            // inset participates in the scroll view's geometry, so changing it
            // on every pinch frame makes the page and its layers visibly jump.
            // Insets are refreshed at layout/gesture boundaries instead.
            view?.reportPageViewport()
            if let programmaticZoomTarget,
               abs(scrollView.zoomScale - programmaticZoomTarget) <= 0.001 {
                self.programmaticZoomTarget = nil
            }
        }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            programmaticZoomTarget = nil
            isUserZooming = false
            self.view?.recenter()
            parent.onZoomChanged(scale)
        }

        @objc func longPress(_ gr: UILongPressGestureRecognizer) {
            if gr.state == .began { parent.onLongPress() }
        }

        @objc func handleFlipPan(_ recognizer: UIPanGestureRecognizer) {
            // Window-relative translation is stable while SwiftUI offsets the
            // canvas in response to this gesture.
            let referenceView = recognizer.view?.window
            let translation = recognizer.translation(in: referenceView).x
            switch recognizer.state {
            case .began, .changed:
                parent.onFlipChanged(translation)
            case .ended:
                parent.onFlipEnded(translation, recognizer.velocity(in: referenceView).x)
            case .cancelled, .failed:
                parent.onFlipEnded(translation, 0)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  pan === flipPan else { return true }
            guard let scrollView = view?.scrollView else { return false }
            let pageFitsViewport = scrollView.zoomScale <= 1.02
            let hasCompetingMode = parent.isLassoActive
                || parent.isArrangingImages
                || parent.fingerDrawing
                || parent.isPageLocked
            guard pageFitsViewport, !hasCompetingMode else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// MARK: - Stroke selection helpers

private func pointInPolygon(_ p: CGPoint, _ polygon: [CGPoint]) -> Bool {
    guard polygon.count > 2 else { return false }
    var inside = false
    var j = polygon.count - 1
    for i in 0..<polygon.count {
        let a = polygon[i], b = polygon[j]
        if (a.y > p.y) != (b.y > p.y) {
            let slope = (p.y - a.y) / (b.y - a.y)
            if p.x < a.x + slope * (b.x - a.x) { inside.toggle() }
        }
        j = i
    }
    return inside
}

private func strokesInside(polygon: [CGPoint], drawing: PKDrawing) -> [Int] {
    var result: [Int] = []
    for (i, stroke) in drawing.strokes.enumerated() {
        var inside = 0, total = 0
        for point in stroke.path {
            let loc = point.location.applying(stroke.transform)
            total += 1
            if pointInPolygon(loc, polygon) { inside += 1 }
        }
        if total > 0, Double(inside) / Double(total) >= 0.5 {
            result.append(i)
        } else {
            let c = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
            if pointInPolygon(c, polygon) { result.append(i) }
        }
    }
    return result
}

// MARK: - Hold-to-straighten recognizer

final class HoldStraightenRecognizer: UIGestureRecognizer {
    var holdDuration: CFTimeInterval = 0.5
    var moveTolerance: CGFloat = 8
    var acceptsFinger = false
    var onHoldStraighten: ((CGPoint, CGPoint) -> Void)?

    private var startPoint: CGPoint = .zero
    private var anchorPoint: CGPoint = .zero
    private var anchorTime: CFTimeInterval = 0
    private var didHold = false
    private var tracking = false
    private var timer: Timer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        if !acceptsFinger && t.type != .pencil { tracking = false; return }
        let p = t.location(in: view)
        startPoint = p; anchorPoint = p; anchorTime = CACurrentMediaTime()
        didHold = false; tracking = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.tracking, !self.didHold else { return }
            if CACurrentMediaTime() - self.anchorTime >= self.holdDuration { self.didHold = true }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking, let t = touches.first else { return }
        let p = t.location(in: view)
        if hypot(p.x - anchorPoint.x, p.y - anchorPoint.y) > moveTolerance {
            anchorPoint = p
            anchorTime = CACurrentMediaTime()
            didHold = false
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        if tracking && didHold { onHoldStraighten?(startPoint, anchorPoint) }
        tracking = false
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate(); tracking = false; state = .failed
    }

    override func reset() {
        super.reset()
        timer?.invalidate(); didHold = false; tracking = false
    }
}

// MARK: - Image layer

final class ImageLayerView: UIView {
    private(set) var images: [PlacedImage] = []
    private var views: [UUID: UIImageView] = [:]
    var onChange: (([PlacedImage]) -> Void)?
    var onSelect: ((UUID?) -> Void)?

    var isEditing = false {
        didSet { isUserInteractionEnabled = isEditing; refreshSelection() }
    }
    var selectedID: UUID? { didSet { refreshSelection() } }

    private var interacting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        pan.delegate = self; pinch.delegate = self
        addGestureRecognizer(pan); addGestureRecognizer(pinch); addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setImages(_ newImages: [PlacedImage]) {
        guard !interacting else { return }
        images = newImages
        for (id, v) in views where !newImages.contains(where: { $0.id == id }) {
            v.removeFromSuperview(); views[id] = nil
        }
        for placed in newImages {
            let v = views[placed.id] ?? {
                let iv = UIImageView()
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 4
                insertSubview(iv, at: 0)
                views[placed.id] = iv
                return iv
            }()
            if v.image == nil { v.image = placed.image }
            v.frame = denormalize(placed.rect)
        }
        refreshSelection()
    }

    private func denormalize(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height,
               width: r.width * bounds.width, height: r.height * bounds.height)
    }
    private func normalize(_ f: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGRect(x: f.minX / bounds.width, y: f.minY / bounds.height,
                      width: f.width / bounds.width, height: f.height / bounds.height)
    }

    private func refreshSelection() {
        for (id, v) in views {
            let on = isEditing && id == selectedID
            v.layer.borderWidth = on ? 2 : 0
            v.layer.borderColor = on ? UIColor.systemBlue.cgColor : UIColor.clear.cgColor
        }
    }

    private func commit(_ id: UUID) {
        guard let v = views[id], let idx = images.firstIndex(where: { $0.id == id }) else { return }
        images[idx].rect = normalize(v.frame)
        onChange?(images)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        guard isEditing else { return }
        let p = gr.location(in: self)
        let hit = images.reversed().first { denormalize($0.rect).contains(p) }
        selectedID = hit?.id
        onSelect?(hit?.id)
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        guard isEditing, let id = selectedID, let v = views[id] else { return }
        let t = gr.translation(in: self)
        v.center = CGPoint(x: v.center.x + t.x, y: v.center.y + t.y)
        gr.setTranslation(.zero, in: self)
        interacting = gr.state == .began || gr.state == .changed
        if gr.state == .ended || gr.state == .cancelled { interacting = false; commit(id) }
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        guard isEditing, let id = selectedID, let v = views[id] else { return }
        var b = v.bounds
        b.size.width = max(40, min(b.width * gr.scale, bounds.width * 2))
        b.size.height = max(40, min(b.height * gr.scale, bounds.height * 2))
        v.bounds = b
        gr.scale = 1
        interacting = gr.state == .began || gr.state == .changed
        if gr.state == .ended || gr.state == .cancelled { interacting = false; commit(id) }
    }
}

extension ImageLayerView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: - Zooming container

final class ZoomablePageView: UIView {
    let scrollView = UIScrollView()
    let contentView = UIView()
    let paperView = PaperSheetView()
    let imageLayer = ImageLayerView()
    let backgroundCanvasView = PKCanvasView()
    let canvasView = PKCanvasView()
    let hoverPreview = InkHoverPreviewView()
    let moveImageView = UIImageView()
    let lassoView = LassoOverlayView()
    let straightenRecognizer = HoldStraightenRecognizer()
    let hoverRecognizer = UIHoverGestureRecognizer()
    let pencilController = PencilInteractionController()
    var undoBridge: NotebookUndoBridge?
    var onPageViewportChange: ((CGRect) -> Void)?
    private var loadedBackgroundDrawingData = Data()
    private var lastReportedPageViewport: CGRect?

    override var undoManager: UndoManager? { undoBridge?.manager }

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

        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.5
        contentView.layer.shadowRadius = 26
        contentView.layer.shadowOffset = CGSize(width: 0, height: 12)
        contentView.layer.shadowPath = UIBezierPath(rect: CGRect(origin: .zero, size: page)).cgPath

        paperView.frame = contentView.bounds
        paperView.isUserInteractionEnabled = false
        paperView.layer.cornerRadius = 3
        paperView.layer.masksToBounds = true
        contentView.addSubview(paperView)

        imageLayer.frame = contentView.bounds
        contentView.addSubview(imageLayer)

        backgroundCanvasView.frame = contentView.bounds
        backgroundCanvasView.backgroundColor = .clear
        backgroundCanvasView.isOpaque = false
        backgroundCanvasView.isScrollEnabled = false
        backgroundCanvasView.isUserInteractionEnabled = false
        backgroundCanvasView.overrideUserInterfaceStyle = .light
        contentView.addSubview(backgroundCanvasView)

        canvasView.frame = contentView.bounds
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isScrollEnabled = false
        canvasView.overrideUserInterfaceStyle = .light
        contentView.addSubview(canvasView)

        straightenRecognizer.cancelsTouchesInView = false
        straightenRecognizer.delaysTouchesBegan = false
        straightenRecognizer.delaysTouchesEnded = false
        canvasView.addGestureRecognizer(straightenRecognizer)

        hoverPreview.frame = contentView.bounds
        contentView.addSubview(hoverPreview)

        hoverRecognizer.cancelsTouchesInView = false
        contentView.addGestureRecognizer(hoverRecognizer)

        addInteraction(pencilController.interaction)

        moveImageView.isHidden = true
        moveImageView.isUserInteractionEnabled = false
        moveImageView.contentMode = .scaleToFill
        contentView.addSubview(moveImageView)

        lassoView.frame = contentView.bounds
        lassoView.isHidden = true
        contentView.addSubview(lassoView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        recenter()
        DispatchQueue.main.async { [weak self] in self?.reportPageViewport() }
    }

    func recenter() {
        let page = NotebookPageLayout.size
        let scaledW = page.width * scrollView.zoomScale
        let scaledH = page.height * scrollView.zoomScale
        let hInset = max(0, (scrollView.bounds.width - scaledW) / 2)
        let vInset = max(16, (scrollView.bounds.height - scaledH) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vInset, left: hInset, bottom: 140, right: hInset)
    }

    func convertToScreen(_ point: CGPoint) -> CGPoint {
        convert(point, to: nil)
    }

    func setBackgroundDrawingData(_ data: Data) {
        guard loadedBackgroundDrawingData != data else { return }
        loadedBackgroundDrawingData = data
        backgroundCanvasView.drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
    }

    func reportPageViewport() {
        let frame = convert(contentView.bounds, from: contentView)
        guard frame.width > 0, frame.height > 0 else { return }
        guard frame != lastReportedPageViewport else { return }
        lastReportedPageViewport = frame
        onPageViewportChange?(frame)
    }
}

// MARK: - Hover ink preview

/// Page-space preview of the active tool under a supported hovering Pencil.
/// Keeping it inside the zooming content makes it follow pan and zoom without
/// an additional coordinate transform.
final class InkHoverPreviewView: UIView {
    private let dot = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        dot.fillColor = UIColor.clear.cgColor
        dot.strokeColor = UIColor.clear.cgColor
        layer.addSublayer(dot)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func show(at point: CGPoint, tool: WritingTool, color: UIColor, width: CGFloat) {
        let diameter = max(width, 2)
        let rect = CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.path = UIBezierPath(ovalIn: rect).cgPath
        switch tool {
        case .eraser:
            dot.fillColor = UIColor.clear.cgColor
            dot.strokeColor = UIColor.label.withAlphaComponent(0.5).cgColor
            dot.lineWidth = 1.5
        case .marker:
            dot.fillColor = color.withAlphaComponent(0.4).cgColor
            dot.strokeColor = UIColor.clear.cgColor
        case .pen, .pencil:
            dot.fillColor = color.cgColor
            dot.strokeColor = UIColor.clear.cgColor
        }
        CATransaction.commit()
        isHidden = false
    }

    func hide() { isHidden = true }
}

// MARK: - Lasso overlay (loop to select, drag to move)

final class LassoOverlayView: UIView {
    private enum Mode { case idle, loop, move }

    private let loopLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private var loopPoints: [CGPoint] = []
    private var mode: Mode = .idle
    private var lastMovePoint: CGPoint = .zero
    private(set) var selectionRect: CGRect?

    var onLoopComplete: (([CGPoint]) -> Void)?
    var beginMoveIfInside: ((CGPoint) -> Bool)?
    var onMove: ((CGPoint) -> Void)?
    var onMoveEnded: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        loopLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        loopLayer.strokeColor = UIColor.systemBlue.cgColor
        loopLayer.lineWidth = 2
        loopLayer.lineDashPattern = [6, 4]
        loopLayer.lineJoin = .round
        layer.addSublayer(loopLayer)

        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [6, 4]
        layer.addSublayer(selectionLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        loopLayer.frame = bounds
        selectionLayer.frame = bounds
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        let p = gr.location(in: self)
        switch gr.state {
        case .began:
            if let rect = selectionRect, rect.insetBy(dx: -20, dy: -20).contains(p),
               beginMoveIfInside?(p) == true {
                mode = .move
                lastMovePoint = p
            } else {
                mode = .loop
                loopPoints = [p]
                selectionLayer.path = nil
                selectionRect = nil
                startMarching(loopLayer)
            }
        case .changed:
            if mode == .move {
                let d = CGPoint(x: p.x - lastMovePoint.x, y: p.y - lastMovePoint.y)
                lastMovePoint = p
                onMove?(d)
                if var r = selectionRect { r.origin.x += d.x; r.origin.y += d.y; showSelection(r) }
            } else if mode == .loop {
                loopPoints.append(p)
                drawLoop(closed: false)
            }
        case .ended, .cancelled:
            if mode == .move {
                onMoveEnded?()
            } else if mode == .loop {
                drawLoop(closed: true)
                loopLayer.path = nil
                onLoopComplete?(loopPoints)
            }
            mode = .idle
        default:
            break
        }
    }

    private func drawLoop(closed: Bool) {
        guard let first = loopPoints.first else { loopLayer.path = nil; return }
        let path = UIBezierPath()
        path.move(to: first)
        for pt in loopPoints.dropFirst() { path.addLine(to: pt) }
        if closed { path.close() }
        loopLayer.path = path.cgPath
    }

    func showSelection(_ rect: CGRect?) {
        selectionRect = rect
        guard let rect else { selectionLayer.path = nil; return }
        selectionLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
        startMarching(selectionLayer)
    }

    func clear() {
        loopPoints = []
        loopLayer.path = nil
        selectionLayer.path = nil
        selectionRect = nil
        mode = .idle
    }

    private func startMarching(_ layer: CAShapeLayer) {
        guard layer.animation(forKey: "march") == nil else { return }
        let anim = CABasicAnimation(keyPath: "lineDashPhase")
        anim.fromValue = 0
        anim.toValue = 10
        anim.duration = 0.45
        anim.repeatCount = .infinity
        layer.add(anim, forKey: "march")
    }
}

// MARK: - Ruled paper

final class PaperSheetView: UIView {
    var template: PageTemplate = .linedMedium { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(bounds)

        guard template.spacing > 0 else { return }
        let spacing = template.spacing

        if template.isDotted {
            let dotColor = UIColor(red: 0.55, green: 0.64, blue: 0.80, alpha: 0.75)
            ctx.setFillColor(dotColor.cgColor)
            let radius: CGFloat = spacing >= 40 ? 1.7 : (spacing >= 30 ? 1.5 : 1.3)
            var y = spacing
            while y < bounds.height {
                var x = spacing
                while x < bounds.width {
                    ctx.fillEllipse(
                        in: CGRect(
                            x: x - radius,
                            y: y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                    )
                    x += spacing
                }
                y += spacing
            }
            return
        }

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
