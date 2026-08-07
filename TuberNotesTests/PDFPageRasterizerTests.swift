import CoreGraphics
import Foundation
import Testing

@testable import TuberNotes

/// Phase 3 of `Docs/Forks/CanvasFeatureComplete.md`, rendering half, first
/// piece: a source PDF page as pixels.
///
/// What is proven here is what pixels can prove — that `/Rotate` 90 and 270
/// swap the extent *and* turn in opposite directions, that a CropBox with a
/// non-zero origin shows the cropped region and not the media's, that the
/// bottom-left-origin y-flip happens exactly once (the fixture's top is the
/// raster's top), that unpainted page is white rather than transparent noise,
/// that a sub-rect renders exactly that region, and that every refusal is a
/// typed error rather than a plausible wrong picture.
///
/// The fixtures are raw PDF bytes authored by `Fixture.pdf` below, because the
/// two properties under test — `/Rotate` and a CropBox origin — are exactly
/// the two no iOS PDF-authoring API exposes. Every page carries an asymmetric
/// four-color quadrant pattern (in *unrotated* display terms: top-left red,
/// top-right green, bottom-left blue, bottom-right yellow) on a non-square
/// box, so all four rotations, either axis flipped, and any dropped origin
/// each produce a distinct, assertable picture.
@Suite("PDF page rasterization")
struct PDFPageRasterizerTests {

    // MARK: - Rotation

    @Test("Rotate 0 renders upright at the crop's own extent")
    func rotateZeroIsUpright() async throws {
        let image = try await PDFPageRasterizer.rasterize(
            Fixture.quadrantPDF(rotate: 0), sourcePageIndex: 0, pixelsPerPagePoint: 1
        )
        #expect(image.width == 120 && image.height == 200)
        // Top-left red and bottom-left blue in one assertion pair is the
        // y-flip test: a double or missing flip swaps exactly these two.
        #expect(isRed(pixel(image, x: 5, y: 5)))
        #expect(isGreen(pixel(image, x: 114, y: 5)))
        #expect(isBlue(pixel(image, x: 5, y: 194)))
        #expect(isYellow(pixel(image, x: 114, y: 194)))
    }

    @Test("Rotate 90 swaps the extent and turns clockwise")
    func rotateNinetyIsClockwise() async throws {
        let image = try await PDFPageRasterizer.rasterize(
            Fixture.quadrantPDF(rotate: 90), sourcePageIndex: 0, pixelsPerPagePoint: 1
        )
        // A quarter turn: 120x200 displays as 200x120.
        #expect(image.width == 200 && image.height == 120)
        // Clockwise: the unrotated top-left (red) lands top-right.
        #expect(isBlue(pixel(image, x: 5, y: 5)))
        #expect(isRed(pixel(image, x: 194, y: 5)))
        #expect(isYellow(pixel(image, x: 5, y: 114)))
        #expect(isGreen(pixel(image, x: 194, y: 114)))
    }

    @Test("Rotate 270 swaps the extent and turns the other way from 90")
    func rotateTwoSeventyIsCounterClockwise() async throws {
        let image = try await PDFPageRasterizer.rasterize(
            Fixture.quadrantPDF(rotate: 270), sourcePageIndex: 0, pixelsPerPagePoint: 1
        )
        #expect(image.width == 200 && image.height == 120)
        // Counter-clockwise on screen: the unrotated top-left (red) lands
        // bottom-left. Every corner differs from the 90 case, so a renderer
        // that turns the wrong way cannot pass both tests.
        #expect(isGreen(pixel(image, x: 5, y: 5)))
        #expect(isYellow(pixel(image, x: 194, y: 5)))
        #expect(isRed(pixel(image, x: 5, y: 114)))
        #expect(isBlue(pixel(image, x: 194, y: 114)))
    }

    @Test("Rotate 180 keeps the extent and inverts both axes")
    func rotateOneEightyInvertsBothAxes() async throws {
        let image = try await PDFPageRasterizer.rasterize(
            Fixture.quadrantPDF(rotate: 180), sourcePageIndex: 0, pixelsPerPagePoint: 1
        )
        #expect(image.width == 120 && image.height == 200)
        #expect(isYellow(pixel(image, x: 5, y: 5)))
        #expect(isBlue(pixel(image, x: 114, y: 5)))
        #expect(isGreen(pixel(image, x: 5, y: 194)))
        #expect(isRed(pixel(image, x: 114, y: 194)))
    }

    // MARK: - CropBox

    @Test("A CropBox with a non-zero origin shows the crop, not the media")
    func nonZeroCropOriginIsHonoured() async throws {
        // The MediaBox is painted black wall to wall beneath the quadrants,
        // and the quadrants are painted inside the offset crop only. A
        // rasterizer that drops the origin — reading the crop as
        // (0, 0, w, h) — shows black where a quadrant belongs.
        let image = try await PDFPageRasterizer.rasterize(
            Fixture.quadrantPDF(rotate: 0, cropOrigin: CGPoint(x: 40, y: 70)),
            sourcePageIndex: 0,
            pixelsPerPagePoint: 1
        )
        #expect(image.width == 120 && image.height == 200)
        #expect(isRed(pixel(image, x: 5, y: 5)))
        #expect(isGreen(pixel(image, x: 114, y: 5)))
        #expect(isBlue(pixel(image, x: 5, y: 194)))
        #expect(isYellow(pixel(image, x: 114, y: 194)))
    }

    @Test("CropBox origin and rotation compose")
    func cropOriginAndRotationCompose() async throws {
        let image = try await PDFPageRasterizer.rasterize(
            Fixture.quadrantPDF(rotate: 90, cropOrigin: CGPoint(x: 40, y: 70)),
            sourcePageIndex: 0,
            pixelsPerPagePoint: 1
        )
        #expect(image.width == 200 && image.height == 120)
        #expect(isBlue(pixel(image, x: 5, y: 5)))
        #expect(isRed(pixel(image, x: 194, y: 5)))
        #expect(isYellow(pixel(image, x: 5, y: 114)))
        #expect(isGreen(pixel(image, x: 194, y: 114)))
    }

    // MARK: - The sub-rect, which is the lens

    @Test("A sub-rect renders exactly that region of the displayed page")
    func aSubRectIsThatRegion() async throws {
        let bytes = Fixture.quadrantPDF(rotate: 0)

        // The display's top-left quadrant is solid red; its bottom-right is
        // solid yellow. Each renders as a uniform image of its own extent.
        let topLeft = try await PDFPageRasterizer.rasterize(
            bytes, sourcePageIndex: 0, pixelsPerPagePoint: 1,
            subRect: CGRect(x: 0, y: 0, width: 60, height: 100)
        )
        #expect(topLeft.width == 60 && topLeft.height == 100)
        #expect(isRed(pixel(topLeft, x: 5, y: 5)))
        #expect(isRed(pixel(topLeft, x: 54, y: 94)))

        let bottomRight = try await PDFPageRasterizer.rasterize(
            bytes, sourcePageIndex: 0, pixelsPerPagePoint: 1,
            subRect: CGRect(x: 60, y: 100, width: 60, height: 100)
        )
        #expect(isYellow(pixel(bottomRight, x: 5, y: 5)))
        #expect(isYellow(pixel(bottomRight, x: 54, y: 94)))
    }

    @Test("A sub-rect is stated in display space, so it composes with rotation")
    func aSubRectComposesWithRotation() async throws {
        // On the page displayed at /Rotate 90, the top-left quadrant is the
        // unrotated bottom-left one: blue. The lens asks about what the user
        // sees, never about PDF user space.
        let image = try await PDFPageRasterizer.rasterize(
            Fixture.quadrantPDF(rotate: 90), sourcePageIndex: 0, pixelsPerPagePoint: 1,
            subRect: CGRect(x: 0, y: 0, width: 100, height: 60)
        )
        #expect(image.width == 100 && image.height == 60)
        #expect(isBlue(pixel(image, x: 5, y: 5)))
        #expect(isBlue(pixel(image, x: 94, y: 54)))
    }

    // MARK: - Scale, background, page selection

    @Test("The level of detail scales the pixels, not the picture")
    func scaleScalesPixels() async throws {
        let image = try await PDFPageRasterizer.rasterize(
            Fixture.quadrantPDF(rotate: 0), sourcePageIndex: 0, pixelsPerPagePoint: 2.5
        )
        #expect(image.width == 300 && image.height == 500)
        #expect(isRed(pixel(image, x: 10, y: 10)))
        #expect(isYellow(pixel(image, x: 290, y: 490)))
    }

    @Test("Unpainted page is white, never transparent")
    func unpaintedPageIsWhite() async throws {
        let image = try await PDFPageRasterizer.rasterize(
            Fixture.pdf(pages: [Fixture.Page(
                mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100), content: ""
            )]),
            sourcePageIndex: 0,
            pixelsPerPagePoint: 1
        )
        #expect(isWhite(pixel(image, x: 50, y: 50)))
        #expect(image.alphaInfo == .noneSkipFirst, "the raster is opaque by construction")
    }

    @Test("The page asked for is the page rendered")
    func theRightPageIsRendered() async throws {
        let bytes = Fixture.pdf(pages: [
            Fixture.Page(
                mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100),
                content: "1 0 0 rg 0 0 100 100 re f\n"
            ),
            Fixture.Page(
                mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100),
                content: "0 1 0 rg 0 0 100 100 re f\n"
            ),
        ])
        let second = try await PDFPageRasterizer.rasterize(
            bytes, sourcePageIndex: 1, pixelsPerPagePoint: 1
        )
        #expect(isGreen(pixel(second, x: 50, y: 50)))
    }

    // MARK: - Refusals

    @Test("Bytes that are not a PDF refuse loudly")
    func garbageRefuses() async {
        await #expect(throws: PDFRasterizeError.notAPDF) {
            _ = try await PDFPageRasterizer.rasterize(
                Data("not a pdf".utf8), sourcePageIndex: 0, pixelsPerPagePoint: 1
            )
        }
    }

    @Test("A page index outside the document refuses, in both directions")
    func outOfRangeRefuses() async {
        let bytes = Fixture.quadrantPDF(rotate: 0)
        await #expect(throws: PDFRasterizeError.pageOutOfRange(index: 1, pageCount: 1)) {
            _ = try await PDFPageRasterizer.rasterize(bytes, sourcePageIndex: 1, pixelsPerPagePoint: 1)
        }
        await #expect(throws: PDFRasterizeError.pageOutOfRange(index: -1, pageCount: 1)) {
            _ = try await PDFPageRasterizer.rasterize(bytes, sourcePageIndex: -1, pixelsPerPagePoint: 1)
        }
    }

    @Test("A /Rotate that is not a quarter turn refuses the page")
    func aDiagonalRotateRefuses() async {
        let bytes = Fixture.pdf(pages: [Fixture.Page(
            mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100), rotate: 45, content: ""
        )])
        await #expect(throws: PDFRasterizeError.unreadableSourcePage(index: 0)) {
            _ = try await PDFPageRasterizer.rasterize(bytes, sourcePageIndex: 0, pixelsPerPagePoint: 1)
        }
    }

    @Test("A sub-rect past the page's edge refuses rather than answering less")
    func aSubRectOutsideThePageRefuses() async {
        let bytes = Fixture.quadrantPDF(rotate: 0)
        await #expect(throws: PDFRasterizeError.rasterOutsidePage(index: 0)) {
            _ = try await PDFPageRasterizer.rasterize(
                bytes, sourcePageIndex: 0, pixelsPerPagePoint: 1,
                subRect: CGRect(x: 100, y: 100, width: 60, height: 200)
            )
        }
        await #expect(throws: PDFRasterizeError.rasterOutsidePage(index: 0)) {
            _ = try await PDFPageRasterizer.rasterize(
                bytes, sourcePageIndex: 0, pixelsPerPagePoint: 1,
                subRect: CGRect(x: 10, y: 10, width: 0, height: 10)
            )
        }
    }

    // MARK: - The one derivation, held to the import's own answers

    @Test("The rasterized extent is the extent the import measured")
    func theRasterAgreesWithTheImport() async throws {
        // `PDFSource.pages` and the rasterizer read the same derivation; this
        // holds them together so the shared function cannot quietly serve one
        // of them something else.
        for rotate in [0, 90, 180, 270] {
            let bytes = Fixture.quadrantPDF(rotate: rotate, cropOrigin: CGPoint(x: 40, y: 70))
            let measured = try await PDFSource.pages(in: bytes)[0]
            let image = try await PDFPageRasterizer.rasterize(
                bytes, sourcePageIndex: 0, pixelsPerPagePoint: 1
            )
            #expect(Double(image.width) == measured.width, "/Rotate \(rotate)")
            #expect(Double(image.height) == measured.height, "/Rotate \(rotate)")
        }
    }

    // MARK: - Pixels

    /// One pixel as 8-bit RGB, read the way `StaticLayerRenderTests` reads
    /// them: drawn into a context of known layout, one y-flip at the read.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("could not build a one-pixel context")
            return (0, 0, 0)
        }
        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func near(_ value: Int, _ target: Int) -> Bool { abs(value - target) <= 12 }
    private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 0) && near(p.b, 0)
    }
    private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 0) && near(p.g, 255) && near(p.b, 0)
    }
    private func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 0) && near(p.g, 0) && near(p.b, 255)
    }
    private func isYellow(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 255) && near(p.b, 0)
    }
    private func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        near(p.r, 255) && near(p.g, 255) && near(p.b, 255)
    }

    // MARK: - Fixtures: raw PDF bytes, authored exactly

    /// A minimal PDF writer. Raw bytes rather than `UIGraphicsPDFRenderer`
    /// because that renderer can author neither `/Rotate` nor a CropBox with
    /// its own origin — the two properties this suite exists to pin — and
    /// because a fixture whose every byte is visible in the test is a fixture
    /// whose meaning cannot drift.
    private enum Fixture {
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
}
