import UIKit

/// Produces bounded, immutable visual evidence without changing notebook content.
/// The caller owns page compositing and must draw the visible paper, placed images,
/// and ink into `renderPage` in that order.
enum SelectionEvidenceRenderer {
    enum Role: String, Sendable {
        case tightEvidence
        case pageContext
    }

    struct Image: Sendable {
        let role: Role
        let imageData: Data
        let mediaType: String
        let pixelWidth: Int
        let pixelHeight: Int
        let pageBounds: PageNormalizedRect
        let isCoordinateBearing: Bool
    }

    struct Bundle: Sendable {
        let tight: Image
        let context: Image
        let selectionPageBounds: PageNormalizedRect
        let lassoPath: [PageNormalizedPoint]
    }

    enum RenderError: Error, Equatable {
        case invalidPageSize
        case invalidSelection
        case encodingFailed
        case tightImageTooLarge(actualBytes: Int, limitBytes: Int)
        case requestTooLarge(actualBytes: Int, limitBytes: Int)
        case validationFailed
    }

    static let tightPaddingPoints: CGFloat = 24
    static let tightMaximumDimension = 2_048
    static let contextMaximumDimension = 1_536
    static let imageMaximumBytes = 4 * 1_024 * 1_024
    static let requestMaximumBytes = 6 * 1_024 * 1_024
    static let maximumScale: CGFloat = 2

    /// `renderPage` receives the complete logical page rectangle and a context
    /// already transformed into logical page coordinates.
    static func render(
        pageSize: CGSize,
        selectionPageBounds: PageNormalizedRect,
        lassoPath: [PageNormalizedPoint],
        renderPage: (_ context: CGContext, _ pageRect: CGRect) -> Void
    ) throws -> Bundle {
        guard pageSize.width.isFinite, pageSize.height.isFinite,
              pageSize.width > 0, pageSize.height > 0 else {
            throw RenderError.invalidPageSize
        }
        guard selectionPageBounds.isFiniteAndInUnitBounds,
              selectionPageBounds.width > 0, selectionPageBounds.height > 0,
              lassoPath.count >= 3,
              lassoPath.allSatisfy(\.isFiniteAndInUnitBounds),
              lassoPath.allSatisfy({ contains($0, in: selectionPageBounds) }) else {
            throw RenderError.invalidSelection
        }

        let pageRect = CGRect(origin: .zero, size: pageSize)
        let selectionRect = rect(for: selectionPageBounds, pageSize: pageSize)
        let tightRect = selectionRect
            .insetBy(dx: -tightPaddingPoints, dy: -tightPaddingPoints)
            .intersection(pageRect)
            .integral
        guard tightRect.width >= 2, tightRect.height >= 2 else {
            throw RenderError.invalidSelection
        }

        let contextInsetX = max(48, pageSize.width * 0.12)
        let contextInsetY = max(48, pageSize.height * 0.12)
        let contextRect = tightRect
            .insetBy(dx: -contextInsetX, dy: -contextInsetY)
            .intersection(pageRect)
            .integral

        let tightScale = boundedScale(for: tightRect, maximumDimension: tightMaximumDimension)
        let tightData = try renderPNG(
            pageRect: pageRect,
            cropRect: tightRect,
            scale: tightScale,
            lassoPath: lassoPath,
            dimsOutsideLasso: true,
            renderPage: renderPage
        )
        guard tightData.data.count <= imageMaximumBytes else {
            throw RenderError.tightImageTooLarge(
                actualBytes: tightData.data.count,
                limitBytes: imageMaximumBytes
            )
        }

        var contextScale = boundedScale(for: contextRect, maximumDimension: contextMaximumDimension)
        var contextData = try renderPNG(
            pageRect: pageRect,
            cropRect: contextRect,
            scale: contextScale,
            lassoPath: lassoPath,
            dimsOutsideLasso: false,
            renderPage: renderPage
        )
        while (contextData.data.count > imageMaximumBytes
               || tightData.data.count + contextData.data.count > requestMaximumBytes),
              contextScale > 0.25 {
            contextScale = max(0.25, contextScale * 0.75)
            contextData = try renderPNG(
                pageRect: pageRect,
                cropRect: contextRect,
                scale: contextScale,
                lassoPath: lassoPath,
                dimsOutsideLasso: false,
                renderPage: renderPage
            )
        }
        guard contextData.data.count <= imageMaximumBytes else {
            throw RenderError.requestTooLarge(
                actualBytes: tightData.data.count + contextData.data.count,
                limitBytes: requestMaximumBytes
            )
        }
        let aggregateBytes = tightData.data.count + contextData.data.count
        guard aggregateBytes <= requestMaximumBytes else {
            throw RenderError.requestTooLarge(actualBytes: aggregateBytes, limitBytes: requestMaximumBytes)
        }

        let tight = Image(
            role: .tightEvidence,
            imageData: tightData.data,
            mediaType: "image/png",
            pixelWidth: tightData.width,
            pixelHeight: tightData.height,
            pageBounds: normalized(tightRect, pageSize: pageSize),
            isCoordinateBearing: true
        )
        let context = Image(
            role: .pageContext,
            imageData: contextData.data,
            mediaType: "image/png",
            pixelWidth: contextData.width,
            pixelHeight: contextData.height,
            pageBounds: normalized(contextRect, pageSize: pageSize),
            isCoordinateBearing: false
        )
        guard validates(tight), validates(context),
              tight.pixelWidth <= tightMaximumDimension,
              tight.pixelHeight <= tightMaximumDimension,
              context.pixelWidth <= contextMaximumDimension,
              context.pixelHeight <= contextMaximumDimension else {
            throw RenderError.validationFailed
        }
        return Bundle(
            tight: tight,
            context: context,
            selectionPageBounds: selectionPageBounds,
            lassoPath: lassoPath
        )
    }

    static func validates(_ image: Image) -> Bool {
        guard image.mediaType == "image/png",
              image.pixelWidth > 0, image.pixelHeight > 0,
              image.pageBounds.isFiniteAndInUnitBounds,
              image.pageBounds.width > 0, image.pageBounds.height > 0,
              image.imageData.count <= imageMaximumBytes,
              let decoded = UIImage(data: image.imageData),
              let cgImage = decoded.cgImage else { return false }
        return cgImage.width == image.pixelWidth && cgImage.height == image.pixelHeight
            && (image.role == .tightEvidence) == image.isCoordinateBearing
    }

    private static func boundedScale(for rect: CGRect, maximumDimension: Int) -> CGFloat {
        min(maximumScale, CGFloat(maximumDimension) / max(rect.width, rect.height))
    }

    private static func renderPNG(
        pageRect: CGRect,
        cropRect: CGRect,
        scale: CGFloat,
        lassoPath: [PageNormalizedPoint],
        dimsOutsideLasso: Bool,
        renderPage: (_ context: CGContext, _ pageRect: CGRect) -> Void
    ) throws -> (data: Data, width: Int, height: Int) {
        let width = max(1, Int((cropRect.width * scale).rounded()))
        let height = max(1, Int((cropRect.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
            renderPage(context, pageRect)
            if dimsOutsideLasso {
                let polygon = UIBezierPath()
                for (index, point) in lassoPath.enumerated() {
                    let pagePoint = CGPoint(
                        x: CGFloat(point.x) * pageRect.width,
                        y: CGFloat(point.y) * pageRect.height
                    )
                    index == 0 ? polygon.move(to: pagePoint) : polygon.addLine(to: pagePoint)
                }
                polygon.close()
                context.addRect(cropRect)
                context.addPath(polygon.cgPath)
                context.setFillColor(UIColor.white.withAlphaComponent(0.38).cgColor)
                context.fillPath(using: .evenOdd)
            }
            context.restoreGState()
        }
        guard let data = rendered.pngData() else { throw RenderError.encodingFailed }
        return (data, width, height)
    }

    private static func rect(for bounds: PageNormalizedRect, pageSize: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(bounds.x) * pageSize.width,
            y: CGFloat(bounds.y) * pageSize.height,
            width: CGFloat(bounds.width) * pageSize.width,
            height: CGFloat(bounds.height) * pageSize.height
        )
    }

    private static func contains(_ point: PageNormalizedPoint, in bounds: PageNormalizedRect) -> Bool {
        let tolerance = 1e-9
        return point.x >= bounds.x - tolerance
            && point.x <= bounds.x + bounds.width + tolerance
            && point.y >= bounds.y - tolerance
            && point.y <= bounds.y + bounds.height + tolerance
    }

    private static func normalized(_ rect: CGRect, pageSize: CGSize) -> PageNormalizedRect {
        PageNormalizedRect(
            x: Double(rect.minX / pageSize.width),
            y: Double(rect.minY / pageSize.height),
            width: Double(rect.width / pageSize.width),
            height: Double(rect.height / pageSize.height)
        )
    }
}
