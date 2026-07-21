import PDFKit
import PencilKit
import SwiftUI
import UIKit

enum MagicLassoGeometry {
    static let minimumArea = 0.0025
    static let closeDistance = 0.25

    static func closedPath(from captured: [PageNormalizedPoint]) -> [PageNormalizedPoint]? {
        guard captured.count >= 3, captured.allSatisfy(\.isFiniteAndInUnitBounds) else { return nil }
        var closed = captured
        guard let first = closed.first, let last = closed.last else { return nil }
        guard hypot(last.x - first.x, last.y - first.y) <= closeDistance else { return nil }
        if last != first { closed.append(first) }
        guard abs(signedArea(of: closed)) >= minimumArea else { return nil }
        return closed
    }

    static func pageBounds(of path: [PageNormalizedPoint]) -> PageNormalizedRect? {
        guard !path.isEmpty else { return nil }
        let xs = path.map(\.x)
        let ys = path.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX > minX, maxY > minY else { return nil }
        return PageNormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Even-odd containment in page-normalized space. The input path is the
    /// exact closed region shown to the user, so replacement operations do not
    /// accidentally affect Pins merely near its rectangular crop.
    static func contains(_ point: PageNormalizedPoint, in closedPath: [PageNormalizedPoint]) -> Bool {
        guard point.isFiniteAndInUnitBounds, closedPath.count >= 4 else { return false }
        var inside = false
        var previousIndex = closedPath.count - 1
        for index in closedPath.indices {
            let current = closedPath[index]
            let previous = closedPath[previousIndex]
            if (current.y > point.y) != (previous.y > point.y),
               point.x < (previous.x - current.x) * (point.y - current.y)
                    / (previous.y - current.y) + current.x {
                inside.toggle()
            }
            previousIndex = index
        }
        return inside
    }

    static func cropRoundTripMaximumError(path: [PageNormalizedPoint], bounds: PageNormalizedRect) -> Double {
        path.reduce(0) { result, point in
            let crop = CropNormalizedPoint(
                x: (point.x - bounds.x) / bounds.width,
                y: (point.y - bounds.y) / bounds.height
            )
            let restored = SpatialCoordinateTransform.cropPointToPage(crop, cropPageBounds: bounds)
            return max(result, abs(restored.x - point.x), abs(restored.y - point.y))
        }
    }

    static func diagnosticChecksPass() -> Bool {
        let valid = [
            PageNormalizedPoint(x: 0.2, y: 0.2),
            PageNormalizedPoint(x: 0.8, y: 0.2),
            PageNormalizedPoint(x: 0.8, y: 0.7),
            PageNormalizedPoint(x: 0.21, y: 0.21)
        ]
        let degenerate = [
            PageNormalizedPoint(x: 0.2, y: 0.2),
            PageNormalizedPoint(x: 0.4, y: 0.4),
            PageNormalizedPoint(x: 0.6, y: 0.6)
        ]
        let open = [
            PageNormalizedPoint(x: 0.1, y: 0.1),
            PageNormalizedPoint(x: 0.8, y: 0.1),
            PageNormalizedPoint(x: 0.8, y: 0.8)
        ]
        guard let closed = closedPath(from: valid),
              let bounds = pageBounds(of: closed) else { return false }
        return closed.first == closed.last
            && closedPath(from: degenerate) == nil
            && closedPath(from: open) == nil
            && contains(PageNormalizedPoint(x: 0.5, y: 0.4), in: closed)
            && !contains(PageNormalizedPoint(x: 0.05, y: 0.05), in: closed)
            && cropRoundTripMaximumError(path: closed, bounds: bounds) <= 1e-6
    }

    private static func signedArea(of path: [PageNormalizedPoint]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { area, pair in
            area + pair.0.x * pair.1.y - pair.1.x * pair.0.y
        } / 2
    }
}

enum SelectionCropCompositor {
    static func artifact(
        id: UUID = UUID(),
        document: NotebookDocument,
        page: PageRecord,
        pdfPage: PDFPage?,
        drawing: PKDrawing,
        canvasSize: CGSize,
        capturedPath: [PageNormalizedPoint]
    ) -> SelectionArtifact? {
        guard let path = MagicLassoGeometry.closedPath(from: capturedPath),
              let pageBounds = MagicLassoGeometry.pageBounds(of: path),
              canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        let cropRect = CGRect(
            x: pageBounds.x * canvasSize.width,
            y: pageBounds.y * canvasSize.height,
            width: pageBounds.width * canvasSize.width,
            height: pageBounds.height * canvasSize.height
        ).integral
        guard cropRect.width >= 2, cropRect.height >= 2 else { return nil }

        let scale = min(CGFloat(2), 2048 / max(cropRect.width, cropRect.height))
        let pixelSize = CGSize(width: cropRect.width * scale, height: cropRect.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pixelSize, format: format).image { renderer in
            let context = renderer.cgContext
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: canvasSize))

            if let pdfPage {
                pdfPage.thumbnail(
                    of: CGSize(width: canvasSize.width * 2, height: canvasSize.height * 2),
                    for: .mediaBox
                ).draw(in: CGRect(origin: .zero, size: canvasSize))
            }
            drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: 2)
                .draw(in: CGRect(origin: .zero, size: canvasSize))

            let polygon = UIBezierPath()
            for (index, point) in path.enumerated() {
                let canvas = SpatialCoordinateTransform.pageCanvasPoint(
                    for: point,
                    pageSize: PageCanvasSize(width: Double(canvasSize.width), height: Double(canvasSize.height))
                )
                let cgPoint = CGPoint(x: canvas.x, y: canvas.y)
                index == 0 ? polygon.move(to: cgPoint) : polygon.addLine(to: cgPoint)
            }
            polygon.close()
            context.saveGState()
            context.addRect(cropRect)
            context.addPath(polygon.cgPath)
            context.setFillColor(UIColor.black.withAlphaComponent(0.18).cgColor)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }
        guard let imageData = image.pngData() else { return nil }

        let error = MagicLassoGeometry.cropRoundTripMaximumError(path: path, bounds: pageBounds)
        assert(error <= 1e-6, "Selection crop round-trip exceeded 1e-6")
        return SelectionArtifact(
            id: id,
            documentID: document.id,
            pageID: page.id,
            pageIndex: page.index,
            lassoPath: path,
            pageBounds: pageBounds,
            crop: SelectionCrop(
                imageData: imageData,
                mediaType: "image/png",
                pixelWidth: Int(pixelSize.width.rounded()),
                pixelHeight: Int(pixelSize.height.rounded()),
                pageBounds: pageBounds
            ),
            context: SelectionContext(
                documentTitle: document.title,
                sourceDocumentID: document.id,
                pageNumber: page.index + 1,
                nearbyText: nil
            )
        )
    }
}

struct MagicLassoOverlay: UIViewRepresentable {
    let enabled: Bool
    let initialPath: [PageNormalizedPoint]?
    let onCapturedPath: ([PageNormalizedPoint], CGSize) -> Void

    func makeUIView(context: Context) -> MagicLassoInputView {
        let view = MagicLassoInputView()
        view.onCapturedPath = onCapturedPath
        view.isEnabled = enabled
        view.initialPath = initialPath
        return view
    }

    func updateUIView(_ view: MagicLassoInputView, context: Context) {
        view.onCapturedPath = onCapturedPath
        view.isEnabled = enabled
        view.initialPath = initialPath
    }
}

final class MagicLassoInputView: UIView {
    var onCapturedPath: (([PageNormalizedPoint], CGSize) -> Void)?
    var isEnabled = false { didSet { isUserInteractionEnabled = isEnabled } }
    var initialPath: [PageNormalizedPoint]? { didSet { setNeedsLayout() } }
    private var captured: [PageNormalizedPoint] = []
    private var appliedInitialPath: [PageNormalizedPoint]?
    private var appliedBoundsSize: CGSize?
    private let boundaryLayer = CAShapeLayer()
    private let traceAccentLayer = CAShapeLayer()
    private let dimLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = UIColor.black.withAlphaComponent(0.13).cgColor
        boundaryLayer.fillColor = UIColor.clear.cgColor
        boundaryLayer.strokeColor = UIColor.systemIndigo.cgColor
        boundaryLayer.lineWidth = 3
        boundaryLayer.lineJoin = .round
        boundaryLayer.shadowColor = UIColor.systemIndigo.cgColor
        boundaryLayer.shadowOpacity = 0.32
        boundaryLayer.shadowRadius = 4
        traceAccentLayer.fillColor = UIColor.clear.cgColor
        traceAccentLayer.strokeColor = UIColor.systemCyan.withAlphaComponent(0.78).cgColor
        traceAccentLayer.lineWidth = 1.25
        traceAccentLayer.lineJoin = .round
        traceAccentLayer.lineCap = .round
        traceAccentLayer.lineDashPattern = [3, 11]
        layer.addSublayer(dimLayer)
        layer.addSublayer(boundaryLayer)
        layer.addSublayer(traceAccentLayer)
        accessibilityIdentifier = "magic-lasso-overlay"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        dimLayer.frame = bounds
        boundaryLayer.frame = bounds
        traceAccentLayer.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let initialPath else {
            guard appliedInitialPath != nil || appliedBoundsSize != bounds.size else { return }
            appliedInitialPath = nil
            appliedBoundsSize = bounds.size
            captured = []
            render([], selected: false, drawing: false)
            return
        }
        guard initialPath != appliedInitialPath || appliedBoundsSize != bounds.size else { return }
        appliedInitialPath = initialPath
        appliedBoundsSize = bounds.size
        captured = initialPath
        boundaryLayer.strokeColor = UIColor.systemIndigo.cgColor
        render(initialPath, selected: true, drawing: false)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, let touch = touches.first else { return }
        captured = [normalized(touch.location(in: self))]
        render(captured, selected: false, drawing: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, let touch = touches.first else { return }
        captured.append(normalized(touch.location(in: self)))
        render(captured, selected: false, drawing: true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, let touch = touches.first else { return }
        captured.append(normalized(touch.location(in: self)))
        finish(captured)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        captured = []
        render([], selected: false, drawing: false)
    }

    private func finish(_ path: [PageNormalizedPoint]) {
        guard let closed = MagicLassoGeometry.closedPath(from: path) else {
            captured = []
            boundaryLayer.strokeColor = UIColor.systemRed.cgColor
            render(path, selected: false, drawing: false)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.boundaryLayer.strokeColor = UIColor.systemIndigo.cgColor
                self.render([], selected: false, drawing: false)
            }
            return
        }
        boundaryLayer.strokeColor = UIColor.systemIndigo.cgColor
        captured = closed
        render(closed, selected: true, drawing: false)
        animateLoopSeal()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCapturedPath?(closed, bounds.size)
    }

    private func normalized(_ point: CGPoint) -> PageNormalizedPoint {
        SpatialCoordinateTransform.pageNormalizedPoint(
            for: PageCanvasPoint(x: point.x, y: point.y),
            pageSize: PageCanvasSize(width: Double(bounds.width), height: Double(bounds.height))
        )
    }

    private func render(_ points: [PageNormalizedPoint], selected: Bool, drawing: Bool) {
        let path = UIBezierPath()
        for (index, point) in points.enumerated() {
            let canvas = SpatialCoordinateTransform.pageCanvasPoint(
                for: point,
                pageSize: PageCanvasSize(width: Double(bounds.width), height: Double(bounds.height))
            )
            let cgPoint = CGPoint(x: canvas.x, y: canvas.y)
            index == 0 ? path.move(to: cgPoint) : path.addLine(to: cgPoint)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boundaryLayer.path = path.cgPath
        traceAccentLayer.path = path.cgPath
        if selected {
            let dim = UIBezierPath(rect: bounds)
            dim.append(path)
            dim.usesEvenOddFillRule = true
            dimLayer.path = dim.cgPath
            boundaryLayer.shadowOpacity = 0.38
            traceAccentLayer.opacity = 0.24
        } else {
            dimLayer.path = nil
            boundaryLayer.shadowOpacity = drawing ? 0.32 : 0
            traceAccentLayer.opacity = drawing ? 0.72 : 0
        }
        CATransaction.commit()

        if drawing, !UIAccessibility.isReduceMotionEnabled, !points.isEmpty {
            if traceAccentLayer.animation(forKey: "magic-trace-drift") == nil {
                let drift = CABasicAnimation(keyPath: "lineDashPhase")
                drift.byValue = -14
                drift.duration = 0.7
                drift.repeatCount = .infinity
                drift.timingFunction = CAMediaTimingFunction(name: .linear)
                traceAccentLayer.add(drift, forKey: "magic-trace-drift")
            }
        } else {
            traceAccentLayer.removeAnimation(forKey: "magic-trace-drift")
        }
    }

    private func animateLoopSeal() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        let seal = CAAnimationGroup()
        let drawClosedSegment = CABasicAnimation(keyPath: "strokeEnd")
        drawClosedSegment.fromValue = 0.9
        drawClosedSegment.toValue = 1
        let settleWidth = CABasicAnimation(keyPath: "lineWidth")
        settleWidth.fromValue = 4.5
        settleWidth.toValue = boundaryLayer.lineWidth
        let settleGlow = CABasicAnimation(keyPath: "shadowOpacity")
        settleGlow.fromValue = 0.72
        settleGlow.toValue = boundaryLayer.shadowOpacity
        seal.animations = [drawClosedSegment, settleWidth, settleGlow]
        seal.duration = 0.24
        seal.timingFunction = CAMediaTimingFunction(name: .easeOut)
        boundaryLayer.add(seal, forKey: "magic-loop-seal")

        let accentSeal = CABasicAnimation(keyPath: "opacity")
        accentSeal.fromValue = 0.82
        accentSeal.toValue = traceAccentLayer.opacity
        accentSeal.duration = 0.24
        accentSeal.timingFunction = CAMediaTimingFunction(name: .easeOut)
        traceAccentLayer.add(accentSeal, forKey: "magic-loop-seal-accent")
    }
}
