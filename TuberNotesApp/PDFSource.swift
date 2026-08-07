import CoreGraphics
import Foundation

/// What a source PDF says about itself — page count and each page's extent —
/// and, since the rendering half of phase 3, the pixels a page rasterizes to.
/// **The one place in this build that opens a PDF**, and therefore the one
/// place that decides which of a PDF page's five boxes "the page" means.
///
/// `PDFPageRasterizer` lives in this file rather than beside the canvas
/// runtime for exactly that reason: the durable payload stores no source
/// rectangle (see `PDFLayerRef`), so any renderer must re-derive the CropBox —
/// including a non-zero origin — and `/Rotate` from the asset itself, and two
/// files each deciding "which rectangle" independently is how the import's
/// extent and the render's pixels drift apart with no way to detect it. Both
/// consumers read one function, `PDFSource.displayGeometry`, and the decision
/// stays made once.
///
/// It touches no file: it is handed bytes and returns values, so `DocumentStore`
/// remains the only thing here that reads or writes storage (`Docs/Contract.md`
/// — Owners, golden rule 4).
///
/// `CoreGraphics` rather than `PDFKit`, on two grounds: `PDFKit` is a UIKit-era
/// document framework that brings a view stack with it, and `CGPDFDocument` is
/// the smaller surface that answers exactly these two questions. Nothing here
/// wants a `PDFView`.

/// One source page's extent, in the source's own points, ready to be fitted
/// into a page. Never durable: it is used to compute a layer's
/// `pageSpaceTransform` and then discarded. See `PDFLayerRef` for why.
struct PDFSourcePage: Sendable, Equatable {
    /// Zero-based, in the source document's own order — the value that becomes
    /// `PDFLayerRef.sourcePageIndex`.
    let index: Int
    let width: Double
    let height: Double
}

/// A source PDF this build will not import. Every case refuses the import
/// whole: a PDF that is half-readable is not a document, and importing the
/// readable half silently would be exactly the quiet correction the contract
/// forbids.
enum PDFSourceError: Error, Equatable {
    /// The bytes are not a PDF this build can open at all.
    case notAPDF
    /// A PDF with no pages. Valid per the spec's letter, importable by nothing.
    case noPages
    /// A page whose dictionary would not open, or whose box is empty, infinite,
    /// or otherwise not a rectangle anything can be placed in.
    case unreadableSourcePage(index: Int)
}

enum PDFSource {
    /// Every page of a source PDF, in order.
    ///
    /// `async` and `nonisolated`, which is load-bearing rather than decorative:
    /// a nonisolated async function runs on the generic executor rather than
    /// the caller's actor, so parsing a 50 MB import cannot land on the main
    /// thread from `EditorSession`. `Docs/Contract.md` — Performance names PDF
    /// work on the main thread specifically.
    ///
    /// **The box, decided here and stated once:** a page's rectangle is its
    /// **CropBox**, which is what every PDF viewer displays and what the user
    /// means by "the page"; the PDF specification defines CropBox to default to
    /// MediaBox, and this falls back explicitly rather than trusting Quartz to
    /// apply that default. `/Rotate` is applied to the extent, so a landscape
    /// page stored rotated fits landscape instead of arriving sideways.
    ///
    /// This decision is the reason the durable payload stores no source size: a
    /// layer's transform maps *this* rectangle's unit square into page space,
    /// and this is the only code that has to know which rectangle that is.
    static func pages(in bytes: Data) async throws -> [PDFSourcePage] {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let document = CGPDFDocument(provider)
        else {
            throw PDFSourceError.notAPDF
        }

        let count = document.numberOfPages
        guard count > 0 else { throw PDFSourceError.noPages }

        // CGPDFDocument numbers pages from one; every durable index in this
        // project is zero-based, and the conversion happens here so that
        // nothing downstream has to remember which convention it is holding.
        return try (1...count).map { number in
            guard let page = document.page(at: number),
                  let geometry = displayGeometry(of: page)
            else {
                throw PDFSourceError.unreadableSourcePage(index: number - 1)
            }
            return PDFSourcePage(
                index: number - 1,
                width: geometry.displayWidth,
                height: geometry.displayHeight
            )
        }
    }

    // MARK: - The rectangle, decided once

    /// Which rectangle a source page shows, and which way up.
    ///
    /// `box` is the CropBox falling back to MediaBox, **with its own origin** —
    /// a CropBox need not start at (0, 0), and a renderer that treats it as if
    /// it did paints the wrong region of the page. `rotationDegrees` is the
    /// page's `/Rotate`, normalized to 0 | 90 | 180 | 270. The displayed extent
    /// swaps width and height under a quarter turn.
    ///
    /// Never durable: the durable payload stores no source rectangle on
    /// purpose (`PDFLayerRef`), so this is re-derived from the asset's bytes
    /// wherever it is needed, and this function is the only place the
    /// derivation is written.
    struct DisplayGeometry: Sendable, Equatable {
        /// The displayed region, in the source's own coordinates: PDF user
        /// space, origin bottom-left, y up.
        let box: CGRect
        /// 0, 90, 180, or 270 — clockwise, as the PDF specification defines
        /// `/Rotate`.
        let rotationDegrees: Int

        /// The extent the user sees, after rotation: a quarter turn swaps it.
        var displayWidth: Double {
            rotationDegrees == 90 || rotationDegrees == 270 ? Double(box.height) : Double(box.width)
        }
        var displayHeight: Double {
            rotationDegrees == 90 || rotationDegrees == 270 ? Double(box.width) : Double(box.height)
        }
    }

    /// The one derivation of "which rectangle this page shows". `nil` is a
    /// refusal — a box that is empty, infinite, or not a rectangle, or a
    /// `/Rotate` that is not a multiple of 90 (the specification allows
    /// nothing else; anything else is a page this build refuses rather than
    /// rounds).
    static func displayGeometry(of page: CGPDFPage) -> DisplayGeometry? {
        var box = page.getBoxRect(.cropBox)
        if box.isNull || box.isEmpty { box = page.getBoxRect(.mediaBox) }

        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        guard rotation % 90 == 0 else { return nil }

        guard box.width.isFinite, box.width > 0,
              box.height.isFinite, box.height > 0,
              box.origin.x.isFinite, box.origin.y.isFinite
        else { return nil }

        return DisplayGeometry(box: box, rotationDegrees: rotation)
    }
}

// MARK: - Rasterization

/// A rasterization this build refuses. Typed and loud: a wrong picture served
/// quietly is the failure mode the layer model exists to prevent
/// (`Docs/Contract.md` — Invalid states fail loud).
enum PDFRasterizeError: Error, Equatable {
    /// The bytes are not a PDF this build can open at all.
    case notAPDF
    /// The page asked for does not exist in this document.
    case pageOutOfRange(index: Int, pageCount: Int)
    /// The page exists but its dictionary, box, or rotation is not something
    /// a rectangle of pixels can be made from.
    case unreadableSourcePage(index: Int)
    /// The sub-rect asked for lies outside the displayed page. The caller
    /// clamps its visible rect to the page before asking; a rect past the edge
    /// is a wrong question, not a smaller answer.
    case rasterOutsidePage(index: Int)
    /// The raster could not be produced: a zero-pixel target, a context that
    /// would not build, or a context that yielded no image.
    case rasterUnavailable(widthPixels: Int, heightPixels: Int)
}

/// One source page, as pixels. Pure rendering: bytes in, a `CGImage` out,
/// nothing durable touched and no file opened — it is handed bytes exactly as
/// `PDFSource.pages` is, so `DocumentStore` remains the only thing that reads
/// storage.
///
/// This is the renderer the base-and-lens design needs (`Docs/Forks/
/// CanvasFeatureComplete.md` — "Sharpness comes from base + lens"): the base
/// asks for the whole page at fit-width, the lens asks for the visible
/// sub-rect at the settled zoom. Neither integration exists yet — this type
/// answers the question and stops.
enum PDFPageRasterizer {
    /// The displayed extent of one source page, in the source's own points —
    /// CropBox falling back to MediaBox, `/Rotate` applied.
    ///
    /// The composite renderer needs this number *before* it can choose a
    /// rasterization scale: a layer's decode is bounded by where the layer
    /// lands on the page (`StaticLayerRenderer.maxPixelSize`), and turning
    /// that pixel bound into pixels-per-source-point requires the source's
    /// extent. It throws exactly the refusals `rasterize` would throw for the
    /// same bytes and index, so a caller that survives this call cannot then
    /// be surprised by the render.
    static func displaySize(of bytes: Data, sourcePageIndex: Int) throws -> CGSize {
        let geometry = try displayGeometry(of: bytes, sourcePageIndex: sourcePageIndex).geometry
        return CGSize(width: geometry.displayWidth, height: geometry.displayHeight)
    }

    /// Opens the document, validates the page index, and derives the one
    /// display geometry — shared by `displaySize` and `rasterize` so the two
    /// cannot disagree about which rectangle a page shows.
    private static func displayGeometry(
        of bytes: Data,
        sourcePageIndex: Int
    ) throws -> (page: CGPDFPage, geometry: PDFSource.DisplayGeometry) {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let document = CGPDFDocument(provider)
        else {
            throw PDFRasterizeError.notAPDF
        }

        let count = document.numberOfPages
        guard (0..<count).contains(sourcePageIndex) else {
            throw PDFRasterizeError.pageOutOfRange(index: sourcePageIndex, pageCount: count)
        }
        guard let page = document.page(at: sourcePageIndex + 1),
              let geometry = PDFSource.displayGeometry(of: page)
        else {
            throw PDFRasterizeError.unreadableSourcePage(index: sourcePageIndex)
        }
        return (page, geometry)
    }

    /// Pixels for one source page, or a sub-rect of it.
    ///
    /// `async` and `nonisolated` for the same load-bearing reason
    /// `PDFSource.pages` is: a nonisolated async function runs on the generic
    /// executor, never the caller's actor, so rasterizing a dense vector page
    /// cannot land on the main thread from the canvas runtime
    /// (`Docs/Contract.md` — Performance names PDF work on main specifically).
    ///
    /// - `sourcePageIndex` is zero-based, matching `PDFLayerRef`.
    /// - `pixelsPerPagePoint` is the level of detail, in the same unit
    ///   `StaticLayerRequest` states it.
    /// - `subRect`, when present, is a region of the **displayed** page —
    ///   origin top-left, y down, in the display's own points, the convention
    ///   every page-space value in this project uses — and must lie within
    ///   the page. `nil` renders the whole page.
    ///
    /// The raster is opaque and starts white: a PDF page has no background of
    /// its own, and transparent content over garbage is a wrong picture.
    ///
    /// Coordinates, stated once because this function is where three
    /// conventions meet: PDF user space is y-up from the bottom-left; the
    /// sub-rect arrives y-down from the top-left; the bitmap context is y-up.
    /// The y-flip therefore happens **exactly once** — converting the
    /// sub-rect's top-left origin into the context's bottom-left one — and
    /// everything after it composes rotation and box origin in y-up space.
    static func rasterize(
        _ bytes: Data,
        sourcePageIndex: Int,
        pixelsPerPagePoint: Double,
        subRect: CGRect? = nil
    ) async throws -> CGImage {
        precondition(
            pixelsPerPagePoint.isFinite && pixelsPerPagePoint > 0,
            "a raster at \(pixelsPerPagePoint) pixels per page point is not a level of detail"
        )

        let (page, geometry) = try displayGeometry(of: bytes, sourcePageIndex: sourcePageIndex)

        let pageRect = CGRect(x: 0, y: 0, width: geometry.displayWidth, height: geometry.displayHeight)
        let rect = subRect ?? pageRect
        // A hairline of tolerance, because the caller's rect is arithmetic
        // over floats; a rect genuinely past the edge still refuses.
        guard rect.width > 0, rect.height > 0,
              pageRect.insetBy(dx: -0.001, dy: -0.001).contains(rect)
        else {
            throw PDFRasterizeError.rasterOutsidePage(index: sourcePageIndex)
        }

        let widthPixels = Int((rect.width * pixelsPerPagePoint).rounded())
        let heightPixels = Int((rect.height * pixelsPerPagePoint).rounded())
        guard widthPixels > 0, heightPixels > 0,
              // The same pixel layout the static composite uses, and the same
              // opacity argument: the surface above is transparent, so this
              // texture being opaque is what holds the overdraw at 2x.
              let context = CGContext(
                  data: nil,
                  width: widthPixels,
                  height: heightPixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else {
            throw PDFRasterizeError.rasterUnavailable(widthPixels: widthPixels, heightPixels: heightPixels)
        }

        // The page itself: white behind whatever the content paints, because
        // PDF content has no background and an unpainted region is page, not
        // absence.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: widthPixels, height: heightPixels))
        context.interpolationQuality = .high

        // Points, not pixels, from here on.
        context.scaleBy(x: pixelsPerPagePoint, y: pixelsPerPagePoint)

        // The one y-flip: the sub-rect's top-left origin becomes the context's
        // bottom-left one. In y-up display coordinates the rect's bottom edge
        // sits at (displayHeight - rect.maxY).
        context.translateBy(x: -rect.minX, y: -(pageRect.height - rect.maxY))

        // Rotation, in y-up display space, mapping the page's own box to the
        // displayed rectangle. `/Rotate` is clockwise on screen; in y-up
        // mathematics clockwise is a negative angle. Each case moves the
        // rotated box back into the first quadrant, then the final translate
        // cancels the box's own origin — the non-zero CropBox origin case.
        switch geometry.rotationDegrees {
        case 90:
            context.translateBy(x: 0, y: pageRect.height)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: pageRect.width, y: pageRect.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: pageRect.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -geometry.box.minX, y: -geometry.box.minY)

        // Content outside the CropBox needs no explicit clip: everything the
        // raster covers is inside the box by construction, and content beyond
        // it maps beyond the bitmap's own edge.
        context.drawPDFPage(page)

        guard let image = context.makeImage() else {
            throw PDFRasterizeError.rasterUnavailable(widthPixels: widthPixels, heightPixels: heightPixels)
        }
        return image
    }
}
