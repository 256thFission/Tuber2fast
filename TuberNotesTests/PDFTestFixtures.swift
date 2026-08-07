import CoreGraphics
import Foundation

/// A minimal PDF writer, shared by every suite that needs a byte-exact PDF
/// fixture. Raw bytes rather than `UIGraphicsPDFRenderer` because that
/// renderer can author neither `/Rotate` nor a CropBox with its own origin —
/// the two properties `PDFPageRasterizerTests` exists to pin — and because a
/// fixture whose every byte is visible in the test is a fixture whose meaning
/// cannot drift.
///
/// Extracted from `PDFPageRasterizerTests` when phase 3c's composite tests
/// needed the same fixtures; one writer rather than two that can disagree.
enum PDFFixture {
    struct Page {
        let mediaBox: CGRect
        var cropBox: CGRect?
        var rotate: Int?
        /// A PDF content stream: `r g b rg` sets a fill color,
        /// `x y w h re f` fills a rectangle, in PDF user space (y up).
        let content: String

        init(mediaBox: CGRect, cropBox: CGRect? = nil, rotate: Int? = nil, content: String) {
            self.mediaBox = mediaBox
            self.cropBox = cropBox
            self.rotate = rotate
            self.content = content
        }
    }

    /// The asymmetric quadrant fixture: a 120x200 crop whose displayed
    /// (unrotated) top-left is red, top-right green, bottom-left blue,
    /// bottom-right yellow — PDF user space is y-up, so "top" is high y.
    /// With a non-zero `cropOrigin` the MediaBox extends 40 points past
    /// the crop on every side and is painted black beneath the quadrants,
    /// so a dropped origin becomes a visibly wrong picture.
    static func quadrantPDF(rotate: Int, cropOrigin: CGPoint = .zero) -> Data {
        // Deliberately non-square, so a swapped extent is observable in
        // the image's own dimensions.
        let w = 120.0, h = 200.0
        let ox = Double(cropOrigin.x), oy = Double(cropOrigin.y)
        let crop = CGRect(x: ox, y: oy, width: w, height: h)
        let media = cropOrigin == .zero
            ? crop
            : crop.insetBy(dx: -40, dy: -40)

        var ops = ""
        if cropOrigin != .zero {
            ops += "0 0 0 rg \(media.minX) \(media.minY) \(media.width) \(media.height) re f\n"
        }
        ops += "1 0 0 rg \(ox) \(oy + h / 2) \(w / 2) \(h / 2) re f\n"        // top-left red
        ops += "0 1 0 rg \(ox + w / 2) \(oy + h / 2) \(w / 2) \(h / 2) re f\n" // top-right green
        ops += "0 0 1 rg \(ox) \(oy) \(w / 2) \(h / 2) re f\n"                // bottom-left blue
        ops += "1 1 0 rg \(ox + w / 2) \(oy) \(w / 2) \(h / 2) re f\n"        // bottom-right yellow

        return pdf(pages: [Page(
            mediaBox: media,
            cropBox: cropOrigin == .zero ? nil : crop,
            rotate: rotate == 0 ? nil : rotate,
            content: ops
        )])
    }

    /// A fixture whose sharpness is observable: half-point vertical black
    /// stripes on a one-point period, across a square page. At one raster
    /// pixel per point every pixel is half black, half white — a uniform
    /// grey; at two pixels per point, pure black and pure white columns
    /// alternate. That difference is what "the lens is sharper than the
    /// scaled-up base" means in a form a test can assert.
    static func stripePDF(side: Double = 100) -> Data {
        var ops = "0 0 0 rg\n"
        var x = 0.0
        while x < side {
            ops += "\(x) 0 0.5 \(side) re f\n"
            x += 1
        }
        return pdf(pages: [Page(
            mediaBox: CGRect(x: 0, y: 0, width: side, height: side), content: ops
        )])
    }

    /// Assembles objects, computes the xref table's byte offsets, and
    /// returns a complete PDF. Uncompressed, ASCII, one content stream
    /// per page.
    static func pdf(pages: [Page]) -> Data {
        // Object numbers: 1 catalog, 2 page tree, then (page, contents)
        // pairs from 3.
        var objects: [String] = []
        let kids = pages.indices.map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>")

        func box(_ rect: CGRect) -> String {
            "[\(rect.minX) \(rect.minY) \(rect.maxX) \(rect.maxY)]"
        }

        for (offset, page) in pages.enumerated() {
            var dict = "<< /Type /Page /Parent 2 0 R /MediaBox \(box(page.mediaBox))"
            if let crop = page.cropBox { dict += " /CropBox \(box(crop))" }
            if let rotate = page.rotate { dict += " /Rotate \(rotate)" }
            dict += " /Contents \(4 + offset * 2) 0 R >>"
            objects.append(dict)
            objects.append(
                "<< /Length \(page.content.utf8.count) >>\nstream\n\(page.content)endstream"
            )
        }

        var body = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefStart = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            body += String(format: "%010d 00000 n \n", offset)
        }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        body += "startxref\n\(xrefStart)\n%%EOF\n"
        return Data(body.utf8)
    }
}
