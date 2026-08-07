import CoreGraphics
import Foundation

/// What a source PDF says about itself: how many pages it has and how big each
/// one is. **The one place in this build that opens a PDF**, and therefore the
/// one place that decides which of a PDF page's five boxes "the page" means.
///
/// It renders nothing. Rasterizing a page — base, lens, or thumbnail — is the
/// canvas runtime's, in its own lane; this answers the questions the import
/// path asks and stops.
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
            guard let page = document.page(at: number) else {
                throw PDFSourceError.unreadableSourcePage(index: number - 1)
            }

            var box = page.getBoxRect(.cropBox)
            if box.isNull || box.isEmpty { box = page.getBoxRect(.mediaBox) }

            var width = Double(box.width)
            var height = Double(box.height)
            // A quarter turn swaps the extent. Half turns and full turns do
            // not, and the angle is a multiple of 90 in every valid PDF —
            // anything else is a page this build refuses rather than rounds.
            let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
            switch rotation {
            case 0, 180: break
            case 90, 270: swap(&width, &height)
            default: throw PDFSourceError.unreadableSourcePage(index: number - 1)
            }

            guard width.isFinite, width > 0, height.isFinite, height > 0 else {
                throw PDFSourceError.unreadableSourcePage(index: number - 1)
            }
            return PDFSourcePage(index: number - 1, width: width, height: height)
        }
    }
}
