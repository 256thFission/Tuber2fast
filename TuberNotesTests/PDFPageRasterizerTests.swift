import CoreGraphics
import Foundation
import Testing
@testable import TuberNotes
@testable import TuberRender

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
/// Since `OpenPDFDocument` replaced the two free `PDFPageRasterizer`
/// functions, two more things are proven here and nowhere else: that a
/// `displaySize` + `rasterize` pair parses the source **once**, and that its
/// pixels are byte-identical to the two-open path it replaced.
///
/// The fixtures are raw PDF bytes authored by the shared `PDFFixture` writer, because the
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
    func rotateZeroIsUpright() throws {
        let image = try OpenPDFDocument(bytes: PDFFixture.quadrantPDF(rotate: 0))
            .rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 1)
        #expect(image.width == 120 && image.height == 200)
        // Top-left red and bottom-left blue in one assertion pair is the
        // y-flip test: a double or missing flip swaps exactly these two.
        #expect(isRed(pixel(image, x: 5, y: 5)))
        #expect(isGreen(pixel(image, x: 114, y: 5)))
        #expect(isBlue(pixel(image, x: 5, y: 194)))
        #expect(isYellow(pixel(image, x: 114, y: 194)))
    }

    @Test("Rotate 90 swaps the extent and turns clockwise")
    func rotateNinetyIsClockwise() throws {
        let image = try OpenPDFDocument(bytes: PDFFixture.quadrantPDF(rotate: 90))
            .rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 1)
        // A quarter turn: 120x200 displays as 200x120.
        #expect(image.width == 200 && image.height == 120)
        // Clockwise: the unrotated top-left (red) lands top-right.
        #expect(isBlue(pixel(image, x: 5, y: 5)))
        #expect(isRed(pixel(image, x: 194, y: 5)))
        #expect(isYellow(pixel(image, x: 5, y: 114)))
        #expect(isGreen(pixel(image, x: 194, y: 114)))
    }

    @Test("Rotate 270 swaps the extent and turns the other way from 90")
    func rotateTwoSeventyIsCounterClockwise() throws {
        let image = try OpenPDFDocument(bytes: PDFFixture.quadrantPDF(rotate: 270))
            .rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 1)
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
    func rotateOneEightyInvertsBothAxes() throws {
        let image = try OpenPDFDocument(bytes: PDFFixture.quadrantPDF(rotate: 180))
            .rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 1)
        #expect(image.width == 120 && image.height == 200)
        #expect(isYellow(pixel(image, x: 5, y: 5)))
        #expect(isBlue(pixel(image, x: 114, y: 5)))
        #expect(isGreen(pixel(image, x: 5, y: 194)))
        #expect(isRed(pixel(image, x: 114, y: 194)))
    }

    // MARK: - CropBox

    @Test("A CropBox with a non-zero origin shows the crop, not the media")
    func nonZeroCropOriginIsHonoured() throws {
        // The MediaBox is painted black wall to wall beneath the quadrants,
        // and the quadrants are painted inside the offset crop only. A
        // rasterizer that drops the origin — reading the crop as
        // (0, 0, w, h) — shows black where a quadrant belongs.
        let image = try OpenPDFDocument(
            bytes: PDFFixture.quadrantPDF(rotate: 0, cropOrigin: CGPoint(x: 40, y: 70))
        ).rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 1)
        #expect(image.width == 120 && image.height == 200)
        #expect(isRed(pixel(image, x: 5, y: 5)))
        #expect(isGreen(pixel(image, x: 114, y: 5)))
        #expect(isBlue(pixel(image, x: 5, y: 194)))
        #expect(isYellow(pixel(image, x: 114, y: 194)))
    }

    @Test("CropBox origin and rotation compose")
    func cropOriginAndRotationCompose() throws {
        let image = try OpenPDFDocument(
            bytes: PDFFixture.quadrantPDF(rotate: 90, cropOrigin: CGPoint(x: 40, y: 70))
        ).rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 1)
        #expect(image.width == 200 && image.height == 120)
        #expect(isBlue(pixel(image, x: 5, y: 5)))
        #expect(isRed(pixel(image, x: 194, y: 5)))
        #expect(isYellow(pixel(image, x: 5, y: 114)))
        #expect(isGreen(pixel(image, x: 194, y: 114)))
    }

    // MARK: - The sub-rect, which is the lens

    @Test("A sub-rect renders exactly that region of the displayed page")
    func aSubRectIsThatRegion() throws {
        let document = try OpenPDFDocument(bytes: PDFFixture.quadrantPDF(rotate: 0))

        // The display's top-left quadrant is solid red; its bottom-right is
        // solid yellow. Each renders as a uniform image of its own extent.
        let topLeft = try document.rasterize(
            sourcePageIndex: 0, pixelsPerPagePoint: 1,
            subRect: CGRect(x: 0, y: 0, width: 60, height: 100)
        )
        #expect(topLeft.width == 60 && topLeft.height == 100)
        #expect(isRed(pixel(topLeft, x: 5, y: 5)))
        #expect(isRed(pixel(topLeft, x: 54, y: 94)))

        let bottomRight = try document.rasterize(
            sourcePageIndex: 0, pixelsPerPagePoint: 1,
            subRect: CGRect(x: 60, y: 100, width: 60, height: 100)
        )
        #expect(isYellow(pixel(bottomRight, x: 5, y: 5)))
        #expect(isYellow(pixel(bottomRight, x: 54, y: 94)))
    }

    @Test("A sub-rect is stated in display space, so it composes with rotation")
    func aSubRectComposesWithRotation() throws {
        // On the page displayed at /Rotate 90, the top-left quadrant is the
        // unrotated bottom-left one: blue. The lens asks about what the user
        // sees, never about PDF user space.
        let image = try OpenPDFDocument(bytes: PDFFixture.quadrantPDF(rotate: 90)).rasterize(
            sourcePageIndex: 0, pixelsPerPagePoint: 1,
            subRect: CGRect(x: 0, y: 0, width: 100, height: 60)
        )
        #expect(image.width == 100 && image.height == 60)
        #expect(isBlue(pixel(image, x: 5, y: 5)))
        #expect(isBlue(pixel(image, x: 94, y: 54)))
    }

    // MARK: - Scale, background, page selection

    @Test("The level of detail scales the pixels, not the picture")
    func scaleScalesPixels() throws {
        let image = try OpenPDFDocument(bytes: PDFFixture.quadrantPDF(rotate: 0))
            .rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 2.5)
        #expect(image.width == 300 && image.height == 500)
        #expect(isRed(pixel(image, x: 10, y: 10)))
        #expect(isYellow(pixel(image, x: 290, y: 490)))
    }

    @Test("Unpainted page is white, never transparent")
    func unpaintedPageIsWhite() throws {
        let image = try OpenPDFDocument(bytes: PDFFixture.pdf(pages: [PDFFixture.Page(
            mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100), content: ""
        )])).rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 1)
        #expect(isWhite(pixel(image, x: 50, y: 50)))
        #expect(image.alphaInfo == .noneSkipFirst, "the raster is opaque by construction")
    }

    @Test("The page asked for is the page rendered")
    func theRightPageIsRendered() throws {
        let bytes = PDFFixture.pdf(pages: [
            PDFFixture.Page(
                mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100),
                content: "1 0 0 rg 0 0 100 100 re f\n"
            ),
            PDFFixture.Page(
                mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100),
                content: "0 1 0 rg 0 0 100 100 re f\n"
            ),
        ])
        let second = try OpenPDFDocument(bytes: bytes)
            .rasterize(sourcePageIndex: 1, pixelsPerPagePoint: 1)
        #expect(isGreen(pixel(second, x: 50, y: 50)))
    }

    // MARK: - Refusals

    @Test("Bytes that are not a PDF refuse loudly")
    func garbageRefuses() {
        #expect(throws: PDFRasterizeError.notAPDF) {
            _ = try OpenPDFDocument(bytes: Data("not a pdf".utf8))
        }
    }

    @Test("A page index outside the document refuses, in both directions")
    func outOfRangeRefuses() throws {
        let document = try OpenPDFDocument(bytes: PDFFixture.quadrantPDF(rotate: 0))
        #expect(throws: PDFRasterizeError.pageOutOfRange(index: 1, pageCount: 1)) {
            _ = try document.rasterize(sourcePageIndex: 1, pixelsPerPagePoint: 1)
        }
        #expect(throws: PDFRasterizeError.pageOutOfRange(index: -1, pageCount: 1)) {
            _ = try document.rasterize(sourcePageIndex: -1, pixelsPerPagePoint: 1)
        }
        // `displaySize` refuses exactly what `rasterize` refuses, which is the
        // promise its doc comment makes to `StaticLayerRenderer`.
        #expect(throws: PDFRasterizeError.pageOutOfRange(index: 1, pageCount: 1)) {
            _ = try document.displaySize(sourcePageIndex: 1)
        }
    }

    @Test("A /Rotate that is not a quarter turn refuses the page")
    func aDiagonalRotateRefuses() throws {
        let document = try OpenPDFDocument(bytes: PDFFixture.pdf(pages: [PDFFixture.Page(
            mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100), rotate: 45, content: ""
        )]))
        #expect(throws: PDFRasterizeError.unreadableSourcePage(index: 0)) {
            _ = try document.rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 1)
        }
    }

    @Test("A sub-rect past the page's edge refuses rather than answering less")
    func aSubRectOutsideThePageRefuses() throws {
        let document = try OpenPDFDocument(bytes: PDFFixture.quadrantPDF(rotate: 0))
        #expect(throws: PDFRasterizeError.rasterOutsidePage(index: 0)) {
            _ = try document.rasterize(
                sourcePageIndex: 0, pixelsPerPagePoint: 1,
                subRect: CGRect(x: 100, y: 100, width: 60, height: 200)
            )
        }
        #expect(throws: PDFRasterizeError.rasterOutsidePage(index: 0)) {
            _ = try document.rasterize(
                sourcePageIndex: 0, pixelsPerPagePoint: 1,
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
            let bytes = PDFFixture.quadrantPDF(rotate: rotate, cropOrigin: CGPoint(x: 40, y: 70))
            let measured = try await PDFSource.pages(in: bytes)[0]
            let image = try OpenPDFDocument(bytes: bytes)
                .rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 1)
            #expect(Double(image.width) == measured.width, "/Rotate \(rotate)")
            #expect(Double(image.height) == measured.height, "/Rotate \(rotate)")
        }
    }

    // MARK: - Defect P1: one open, and the same pixels as two

    /// The parse count, observed rather than asserted from the shape of the
    /// code — and observed without a seam in the production type.
    ///
    /// The trick is the fixture, not the renderer: `Data(bytesNoCopy:)` does
    /// not copy, so the buffer handed to `OpenPDFDocument` is still this
    /// test's to write. Blanking the `%PDF` header afterwards makes any
    /// *further* open impossible while leaving every xref offset — and so the
    /// document already parsed — untouched. A path that parses a second time
    /// therefore throws `.notAPDF` where it used to return pixels, which is
    /// exactly what reverting to the two-open `PDFPageRasterizer` does.
    @Test("A displaySize and rasterize pair parses the source exactly once")
    func thePairParsesOnce() throws {
        let fixture = MutableFixture(PDFFixture.quadrantPDF(rotate: 0))
        let document = try OpenPDFDocument(bytes: fixture.bytes)
        fixture.blankTheHeader()

        // The corruption bites. Without this the assertions below would pass
        // against a rasterizer that reopened the document ten more times.
        #expect(throws: PDFRasterizeError.notAPDF) {
            _ = try OpenPDFDocument(bytes: fixture.bytes)
        }

        // Neither call may open anything: both read the document `init` built.
        let size = try document.displaySize(sourcePageIndex: 0)
        #expect(size == CGSize(width: 120, height: 200))
        let image = try document.rasterize(sourcePageIndex: 0, pixelsPerPagePoint: 1)
        #expect(image.width == 120 && image.height == 200)
        #expect(isRed(pixel(image, x: 5, y: 5)))
        #expect(isYellow(pixel(image, x: 114, y: 194)))
    }

    /// The refactor, kept honest: one handle serving both calls must produce
    /// the very bytes two independent opens produced, because that pair — a
    /// document opened for the size, a second opened for the pixels — *is* the
    /// path `OpenPDFDocument` replaced. Two opens of the same bytes are still
    /// reachable through the new API, so the comparison is against the real
    /// thing rather than against a recorded golden that would rot with the
    /// next Quartz.
    @Test("One open renders byte-identically to the two-open path it replaced")
    func oneOpenMatchesTwo() throws {
        // Every fixture property the box decision touches, swept in one place
        // — rotation, a CropBox origin, the level of detail, and the lens's
        // sub-rect — because the whole risk of collapsing two opens into one
        // is that the surviving one derives a different rectangle.
        let cases: [(rotate: Int, cropOrigin: CGPoint, scale: Double, subRect: CGRect?)] = [
            (0, .zero, 1, nil),
            (90, .zero, 1, nil),
            (180, .zero, 1, nil),
            (270, .zero, 1, nil),
            (0, CGPoint(x: 40, y: 70), 1, nil),
            (90, CGPoint(x: 40, y: 70), 2.5, nil),
            (0, .zero, 3, CGRect(x: 20, y: 30, width: 60, height: 100)),
            (270, CGPoint(x: 40, y: 70), 1.5, CGRect(x: 10, y: 5, width: 90, height: 50)),
        ]

        for fixture in cases {
            let what = "/Rotate \(fixture.rotate), crop \(fixture.cropOrigin), "
                + "\(fixture.scale) px/pt, sub-rect \(String(describing: fixture.subRect))"
            let bytes = PDFFixture.quadrantPDF(
                rotate: fixture.rotate, cropOrigin: fixture.cropOrigin
            )

            // The old path: one open answers the size, a second draws the
            // pixels — two `CGPDFDocument`s over the same `Data`.
            let twoOpenSize = try OpenPDFDocument(bytes: bytes).displaySize(sourcePageIndex: 0)
            let twoOpenImage = try OpenPDFDocument(bytes: bytes).rasterize(
                sourcePageIndex: 0, pixelsPerPagePoint: fixture.scale, subRect: fixture.subRect
            )

            // The new path: one handle answers both.
            let document = try OpenPDFDocument(bytes: bytes)
            let oneOpenSize = try document.displaySize(sourcePageIndex: 0)
            let oneOpenImage = try document.rasterize(
                sourcePageIndex: 0, pixelsPerPagePoint: fixture.scale, subRect: fixture.subRect
            )

            #expect(oneOpenSize == twoOpenSize, "\(what)")
            #expect(oneOpenImage.width == twoOpenImage.width, "\(what)")
            #expect(oneOpenImage.height == twoOpenImage.height, "\(what)")
            #expect(oneOpenImage.bytesPerRow == twoOpenImage.bytesPerRow, "\(what)")
            #expect(oneOpenImage.bitmapInfo == twoOpenImage.bitmapInfo, "\(what)")

            let oneOpenBytes = try rasterBytes(oneOpenImage)
            let twoOpenBytes = try rasterBytes(twoOpenImage)
            #expect(
                oneOpenBytes == twoOpenBytes,
                "the collapsed open changed the picture at \(what)"
            )
        }
    }

    // MARK: - Fixtures

    /// PDF bytes this test can still write to after handing them over.
    ///
    /// `Data(bytesNoCopy:)` takes the buffer as it stands, and `.free` gives
    /// the `Data` its lifetime — so nothing here leaks and nothing here
    /// dangles, while the bytes `CGDataProvider` reads remain the bytes below.
    private final class MutableFixture {
        let bytes: Data
        private let buffer: UnsafeMutableRawPointer

        init(_ raw: Data) {
            let buffer = malloc(raw.count)!
            raw.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: raw.count) }
            self.buffer = buffer
            self.bytes = Data(bytesNoCopy: buffer, count: raw.count, deallocator: .free)
        }

        /// Turns `%PDF-1.4` into ` PDF-1.4`: no byte moves, so every xref
        /// offset still addresses what it addressed, and only the *opening*
        /// of the file becomes impossible.
        func blankTheHeader() {
            buffer.storeBytes(of: UInt8(0x20), toByteOffset: 0, as: UInt8.self)
        }
    }

    // MARK: - Pixels

    /// Every byte a raster is made of, straight from the image's own provider
    /// — not resampled through a second context, because "byte-identical" has
    /// to mean the bytes.
    private func rasterBytes(_ image: CGImage) throws -> Data {
        let provider = try #require(image.dataProvider, "a rasterized CGImage has a data provider")
        return try #require(provider.data, "the provider yields its bytes") as Data
    }

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

}
