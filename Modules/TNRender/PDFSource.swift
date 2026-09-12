import CoreGraphics
import Foundation
import TNModel

/// A PDF opened with `CGPDFDocument`, never PDFKit: a page count and a page
/// box do not need a document view stack.
package struct PDFSource: @unchecked Sendable {
    private let document: CGPDFDocument

    package init?(data: Data) {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return nil }
        self.document = document
    }

    package var pageCount: Int { document.numberOfPages }

    /// Zero-based, as every durable index is.
    package func page(at index: Int) -> CGPDFPage? {
        guard index >= 0, index < document.numberOfPages else { return nil }
        return document.page(at: index + 1)
    }

    /// The displayed source rectangle: crop box, else media box, with the
    /// page's rotation normalized. Recorded at import as `sourceExtent` and
    /// re-derived at render; disagreement refuses the layer.
    package static func displayExtent(of page: CGPDFPage) -> SourceExtent? {
        var box = page.getBoxRect(.cropBox)
        if box.isNull || box.isEmpty { box = page.getBoxRect(.mediaBox) }
        guard !box.isNull, !box.isEmpty else { return nil }
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let rotated = rotation == 90 || rotation == 270
        return SourceExtent(
            x: box.minX, y: box.minY,
            width: rotated ? box.height : box.width,
            height: rotated ? box.width : box.height,
            rotation: rotation
        )
    }

    /// Draws the page into a context whose current transform maps the
    /// unit square to the page's placement, upright and y-down.
    package static func draw(_ page: CGPDFPage, extent: SourceExtent, in context: CGContext) {
        context.saveGState()
        // The unit square is the displayed extent; PDF space is y-up.
        context.scaleBy(x: 1 / extent.width, y: 1 / extent.height)
        context.translateBy(x: 0, y: extent.height)
        context.scaleBy(x: 1, y: -1)
        let target = CGRect(x: 0, y: 0, width: extent.width, height: extent.height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.restoreGState()
    }
}
