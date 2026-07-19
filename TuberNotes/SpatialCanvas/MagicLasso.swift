import PDFKit
import PencilKit
import SwiftUI
import UIKit

enum MagicLassoGeometry {
    static let minimumArea = 0.0025
    static let closeDistance = 0.06

    static func closedPath(from captured: [PageNormalizedPoint]) -> [PageNormalizedPoint]? {
        guard captured.count >= 3, captured.allSatisfy(\.isFiniteAndInUnitBounds) else { return nil }
        var closed = captured
        guard let first = closed.first, let last = closed.last else { return nil }
        guard hypot(last.x - first.x, last.y - first.y) <= closeDistance else { return nil }
        closed[closed.count - 1] = first
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
    private let boundaryLayer = CAShapeLayer()
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
        boundaryLayer.shadowOpacity = 0.65
        boundaryLayer.shadowRadius = 7
        layer.addSublayer(dimLayer)
        layer.addSublayer(boundaryLayer)
        accessibilityIdentifier = "magic-lasso-overlay"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        dimLayer.frame = bounds
        boundaryLayer.frame = bounds
        guard bounds.width > 0, bounds.height > 0,
              let initialPath, initialPath != appliedInitialPath else { return }
        appliedInitialPath = initialPath
        finish(initialPath)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, let touch = touches.first, touch.type == .pencil else { return }
        captured = [normalized(touch.location(in: self))]
        render(captured, selected: false)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, let touch = touches.first, touch.type == .pencil else { return }
        captured.append(normalized(touch.location(in: self)))
        render(captured, selected: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isEnabled, let touch = touches.first, touch.type == .pencil else { return }
        captured.append(normalized(touch.location(in: self)))
        finish(captured)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        captured = []
        render([], selected: false)
    }

    private func finish(_ path: [PageNormalizedPoint]) {
        guard let closed = MagicLassoGeometry.closedPath(from: path) else {
            captured = []
            render([], selected: false)
            return
        }
        captured = closed
        render(closed, selected: true)
        onCapturedPath?(closed, bounds.size)
    }

    private func normalized(_ point: CGPoint) -> PageNormalizedPoint {
        SpatialCoordinateTransform.pageNormalizedPoint(
            for: PageCanvasPoint(x: point.x, y: point.y),
            pageSize: PageCanvasSize(width: Double(bounds.width), height: Double(bounds.height))
        )
    }

    private func render(_ points: [PageNormalizedPoint], selected: Bool) {
        let path = UIBezierPath()
        for (index, point) in points.enumerated() {
            let canvas = SpatialCoordinateTransform.pageCanvasPoint(
                for: point,
                pageSize: PageCanvasSize(width: Double(bounds.width), height: Double(bounds.height))
            )
            let cgPoint = CGPoint(x: canvas.x, y: canvas.y)
            index == 0 ? path.move(to: cgPoint) : path.addLine(to: cgPoint)
        }
        boundaryLayer.path = path.cgPath
        if selected {
            let dim = UIBezierPath(rect: bounds)
            dim.append(path)
            dim.usesEvenOddFillRule = true
            dimLayer.path = dim.cgPath
        } else {
            dimLayer.path = nil
        }
    }
}
