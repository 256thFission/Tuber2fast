import PDFKit
import PencilKit
import PointBackKit
import UIKit

/// The living CanvasHost example: SpatialCanvas remains an ordinary host and PointBackKit sees
/// only page identity, window-space projection, composed snapshots, and change notifications.
@MainActor
final class ReferenceCanvasHost: PointBackKit.CanvasHost, ObservableObject {
    let documentID: UUID
    private(set) var pages: [PointBackKit.PageDescriptor]
    private(set) var currentPageID: UUID?
    let changes: AsyncStream<PointBackKit.CanvasHostChange>

    private var document: NotebookDocument
    private var pdfDocument: PDFDocument?
    private var viewportByPageID: [UUID: PageViewportTransform] = [:]
    private var drawingByPageID: [UUID: (drawing: PKDrawing, size: CGSize)] = [:]
    private let continuation: AsyncStream<PointBackKit.CanvasHostChange>.Continuation

    init(document: NotebookDocument, currentPageID: UUID?, pdfDocument: PDFDocument?) {
        self.document = document
        documentID = document.id
        pages = document.pages.map { .init(id: $0.id, index: $0.index) }
        self.currentPageID = currentPageID
        self.pdfDocument = pdfDocument
        let stream = AsyncStream<PointBackKit.CanvasHostChange>.makeStream()
        changes = stream.stream
        continuation = stream.continuation
    }

    func update(document: NotebookDocument, pdfDocument: PDFDocument?) {
        self.document = document
        self.pdfDocument = pdfDocument
        pages = document.pages.map { .init(id: $0.id, index: $0.index) }
        continuation.yield(.pages)
    }

    func updateCurrentPage(_ pageID: UUID?) {
        guard currentPageID != pageID else { return }
        currentPageID = pageID
        continuation.yield(.currentPage(pageID))
    }

    func updateViewport(_ state: PageViewportState) {
        viewportByPageID[state.pageID] = state.transform
        continuation.yield(.viewport(pageID: state.pageID))
    }

    func updateDrawing(pageID: UUID, drawing: PKDrawing, size: CGSize) {
        drawingByPageID[pageID] = (drawing, size)
        continuation.yield(.content(pageID: pageID))
    }

    func projectToWindow(_ point: PointBackKit.PagePoint, on pageID: UUID) -> CGPoint? {
        guard pageID == currentPageID, point.isValid, let viewport = viewportByPageID[pageID] else {
            return nil
        }
        let projected = viewport.projectedViewPoint(
            for: PageNormalizedPoint(x: point.x, y: point.y)
        )
        return CGPoint(x: projected.x, y: projected.y)
    }

    func unprojectFromWindow(_ point: CGPoint) -> (pageID: UUID, point: PointBackKit.PagePoint)? {
        guard let pageID = currentPageID, let viewport = viewportByPageID[pageID] else { return nil }
        let normalized = viewport.pageNormalizedPoint(
            for: PageViewPoint(x: point.x, y: point.y)
        )
        let result = PointBackKit.PagePoint(x: normalized.x, y: normalized.y)
        return result.isValid ? (pageID, result) : nil
    }

    func snapshot(_ rect: PointBackKit.PageRect, on pageID: UUID) async -> PointBackKit.SelectionCrop? {
        guard rect.isValid,
              let page = document.pages.first(where: { $0.id == pageID }),
              let content = drawingByPageID[pageID],
              content.size.width > 0, content.size.height > 0 else { return nil }

        let cropRect = CGRect(
            x: rect.x * content.size.width,
            y: rect.y * content.size.height,
            width: rect.width * content.size.width,
            height: rect.height * content.size.height
        ).integral
        guard cropRect.width >= 2, cropRect.height >= 2 else { return nil }
        let scale = min(CGFloat(2), 2048 / max(cropRect.width, cropRect.height))
        let outputSize = CGSize(width: cropRect.width * scale, height: cropRect.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: outputSize, format: format).image { renderer in
            let context = renderer.cgContext
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
            drawBackground(for: page, in: content.size, context: context)
            content.drawing.image(
                from: CGRect(origin: .zero, size: content.size),
                scale: 2
            ).draw(in: CGRect(origin: .zero, size: content.size))
        }
        guard let data = image.pngData() else { return nil }
        return PointBackKit.SelectionCrop(
            imageData: data,
            mediaType: "image/png",
            pixelWidth: Int(outputSize.width.rounded()),
            pixelHeight: Int(outputSize.height.rounded()),
            pageBounds: rect
        )
    }

    func selectionContext(on pageID: UUID) -> PointBackKit.SelectionContext {
        let page = document.pages.first { $0.id == pageID }
        return PointBackKit.SelectionContext(
            documentTitle: document.title,
            sourceDocumentID: document.id,
            pageNumber: page.map { $0.index + 1 }
        )
    }

    private func drawBackground(for page: PageRecord, in size: CGSize, context: CGContext) {
        context.setFillColor(UIColor(red: 0.992, green: 0.978, blue: 0.936, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        switch page.background {
        case let .pdf(_, pageIndex):
            pdfDocument?.page(at: pageIndex)?.thumbnail(
                of: CGSize(width: size.width * 2, height: size.height * 2),
                for: .mediaBox
            ).draw(in: CGRect(origin: .zero, size: size))
        case let .blank(style, _):
            drawPaper(style: style, in: size, context: context)
        }
    }

    private func drawPaper(style: PaperStyle, in size: CGSize, context: CGContext) {
        guard style != .plain else { return }
        let margin = max(28, min(size.width, size.height) * 0.055)
        let spacing = max(18, min(size.width, size.height) / 27)
        let ink = UIColor(red: 0.20, green: 0.25, blue: 0.42, alpha: 0.17)
        context.setStrokeColor(ink.cgColor)
        context.setFillColor(ink.cgColor)
        context.setLineWidth(0.7)
        if style == .ruled || style == .grid {
            stride(from: margin + spacing, through: size.height - margin, by: spacing).forEach { y in
                context.move(to: CGPoint(x: margin, y: y))
                context.addLine(to: CGPoint(x: size.width - margin, y: y))
            }
            if style == .grid {
                stride(from: margin, through: size.width - margin, by: spacing).forEach { x in
                    context.move(to: CGPoint(x: x, y: margin))
                    context.addLine(to: CGPoint(x: x, y: size.height - margin))
                }
            }
            context.strokePath()
        } else if style == .tuberDotGrid {
            let radius = max(0.8, min(1.35, spacing * 0.055))
            stride(from: margin, through: size.width - margin, by: spacing).forEach { x in
                stride(from: margin, through: size.height - margin, by: spacing).forEach { y in
                    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                }
            }
        }
    }
}
