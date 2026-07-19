import CoreGraphics
import PencilKit
import UIKit

/// Ramer-Douglas-Peucker simplification used only while emitting a PDF.
/// The live PencilKit drawing and persisted note remain untouched.
enum PDFStrokeCompressor {
    struct Result {
        let points: [CGPoint]
        let originalPointCount: Int
        let maximumDeviation: CGFloat

        var removedPointCount: Int { originalPointCount - points.count }
    }

    /// Simplifies a stroke and verifies the result against the requested tolerance.
    /// If validation ever fails, the original finite points are returned instead.
    static func compress(_ input: [CGPoint], tolerance requestedTolerance: CGFloat) -> Result {
        let points = finitePoints(from: input)
        guard points.count > 2 else {
            return Result(points: points, originalPointCount: input.count, maximumDeviation: 0)
        }

        let tolerance = max(0, requestedTolerance)
        let simplified = simplify(points, tolerance: tolerance)
        let deviation = maximumDeviation(of: points, from: simplified)
        let validationSlack = max(CGFloat.ulpOfOne * 32, tolerance * 0.000_001)

        guard deviation <= tolerance + validationSlack else {
            return Result(points: points, originalPointCount: input.count, maximumDeviation: 0)
        }

        return Result(
            points: simplified,
            originalPointCount: input.count,
            maximumDeviation: deviation
        )
    }

    private static func finitePoints(from input: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(input.count)

        for point in input where point.x.isFinite && point.y.isFinite {
            if result.last != point {
                result.append(point)
            }
        }
        return result
    }

    /// Iterative RDP avoids recursion depth becoming dependent on Pencil sample count.
    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var retained = Array(repeating: false, count: points.count)
        retained[0] = true
        retained[points.count - 1] = true
        var ranges = [(0, points.count - 1)]

        while let (start, end) = ranges.popLast() {
            guard end > start + 1 else { continue }

            var farthestIndex: Int?
            var farthestDistance: CGFloat = -1
            for index in (start + 1)..<end {
                let distance = distanceFromSegment(
                    points[index],
                    start: points[start],
                    end: points[end]
                )
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthestIndex = index
                }
            }

            if farthestDistance > tolerance, let farthestIndex {
                retained[farthestIndex] = true
                ranges.append((start, farthestIndex))
                ranges.append((farthestIndex, end))
            }
        }

        return zip(points, retained).compactMap { point, shouldRetain in
            shouldRetain ? point : nil
        }
    }

    private static func maximumDeviation(of source: [CGPoint], from polyline: [CGPoint]) -> CGFloat {
        guard polyline.count > 1 else {
            return source.map { hypot($0.x - polyline[0].x, $0.y - polyline[0].y) }.max() ?? 0
        }

        var maximum: CGFloat = 0
        for point in source {
            var nearest = CGFloat.greatestFiniteMagnitude
            for index in 1..<polyline.count {
                nearest = min(
                    nearest,
                    distanceFromSegment(point, start: polyline[index - 1], end: polyline[index])
                )
            }
            maximum = max(maximum, nearest)
        }
        return maximum
    }

    private static func distanceFromSegment(_ point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }

        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let clamped = min(1, max(0, projection))
        let closest = CGPoint(x: start.x + clamped * dx, y: start.y + clamped * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }
}

struct PDFExportResult {
    let data: Data
    let originalPointCount: Int
    let emittedPointCount: Int
    let maximumDeviation: CGFloat
}

/// The sole PDF-emission seam for note ink. Every stroke is compressed and
/// independently validated immediately before its vector path is written.
enum NotePDFExporter {
    /// A sub-pixel default at standard PDF scale. Callers can choose a larger
    /// tolerance for smaller files, but validation always enforces that value.
    static let defaultTolerance: CGFloat = 0.35

    static func makePDF(
        from drawing: PKDrawing,
        pageBounds: CGRect,
        tolerance: CGFloat = defaultTolerance
    ) -> PDFExportResult {
        let compressedStrokes = drawing.strokes.map { stroke in
            let samples = (0..<stroke.path.count).map { stroke.path[$0] }
            let compression = PDFStrokeCompressor.compress(
                samples.map(\.location),
                tolerance: tolerance
            )
            let averageWidth = samples.isEmpty
                ? CGFloat(1)
                : samples.reduce(CGFloat.zero) { $0 + max($1.size.width, $1.size.height) } / CGFloat(samples.count)
            let averageOpacity = samples.isEmpty
                ? CGFloat(1)
                : samples.reduce(CGFloat.zero) { $0 + $1.opacity } / CGFloat(samples.count)
            return CompressedStroke(
                points: compression.points,
                color: stroke.ink.color,
                width: max(0.5, averageWidth),
                opacity: min(1, max(0, averageOpacity)),
                originalPointCount: compression.originalPointCount,
                maximumDeviation: compression.maximumDeviation
            )
        }

        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: format)
        let data = renderer.pdfData { rendererContext in
            rendererContext.beginPage()
            let context = rendererContext.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(pageBounds)

            for stroke in compressedStrokes {
                draw(stroke, in: context)
            }
        }

        return PDFExportResult(
            data: data,
            originalPointCount: compressedStrokes.reduce(0) { $0 + $1.originalPointCount },
            emittedPointCount: compressedStrokes.reduce(0) { $0 + $1.points.count },
            maximumDeviation: compressedStrokes.map(\.maximumDeviation).max() ?? 0
        )
    }

    private struct CompressedStroke {
        let points: [CGPoint]
        let color: UIColor
        let width: CGFloat
        let opacity: CGFloat
        let originalPointCount: Int
        let maximumDeviation: CGFloat
    }

    private static func draw(_ stroke: CompressedStroke, in context: CGContext) {
        guard let first = stroke.points.first else { return }

        context.saveGState()
        context.setStrokeColor(stroke.color.cgColor)
        context.setFillColor(stroke.color.cgColor)
        context.setAlpha(stroke.opacity)
        context.setLineWidth(stroke.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if stroke.points.count == 1 {
            let radius = stroke.width / 2
            context.fillEllipse(in: CGRect(
                x: first.x - radius,
                y: first.y - radius,
                width: stroke.width,
                height: stroke.width
            ))
        } else {
            context.beginPath()
            context.move(to: first)
            for point in stroke.points.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
        }
        context.restoreGState()
    }
}
