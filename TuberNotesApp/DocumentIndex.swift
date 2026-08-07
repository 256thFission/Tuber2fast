import Foundation

/// The index of a format version 2 document (`Contract.md` — Durable form).
///
/// It holds page identity, order, and geometry — and no ink. Ink lives in a
/// layer file named by one `PageFile` per page, so a save can rewrite one
/// page's ink without touching the other pages, that page's other layers, or
/// this index.
///
/// Nothing here is duplicated in a page file. A value stored in two places is a
/// value that can disagree with itself, and the disagreement would only surface
/// on a document the user could no longer open.
struct DocumentIndex: Codable, Sendable, Equatable {
    let formatVersion: UInt32
    let documentID: UUID
    let pageWidth: Double
    let pageHeight: Double
    let pageIDs: [UUID]
    let currentPageIndex: Int

    static let currentFormatVersion: UInt32 = 2
}

enum DocumentIndexError: Error, Equatable {
    case unsupportedFormatVersion(UInt32)
    case invalidGeometry(width: Double, height: Double)
    case noPages
    case duplicatePageID(UUID)
    case currentPageOutOfRange(index: Int, pageCount: Int)
    case missingPageFile(UUID)
    case pageIDMismatch(expected: UUID, found: UUID)
}

extension DocumentIndex {
    /// Every field the contract constrains, checked in one place.
    func validated() throws -> DocumentIndex {
        guard formatVersion == Self.currentFormatVersion else {
            throw DocumentIndexError.unsupportedFormatVersion(formatVersion)
        }
        guard pageWidth.isFinite,
              pageWidth == PageGeometry.width,
              PageGeometry.isValidHeight(pageHeight),
              pageWidth < pageHeight
        else {
            throw DocumentIndexError.invalidGeometry(width: pageWidth, height: pageHeight)
        }
        guard !pageIDs.isEmpty else { throw DocumentIndexError.noPages }

        var seen = Set<UUID>()
        for id in pageIDs where !seen.insert(id).inserted {
            throw DocumentIndexError.duplicatePageID(id)
        }

        // Rejected rather than clamped, for the reason an unreachable page
        // height was: silently correcting a value hides whatever wrote it.
        guard pageIDs.indices.contains(currentPageIndex) else {
            throw DocumentIndexError.currentPageOutOfRange(
                index: currentPageIndex,
                pageCount: pageIDs.count
            )
        }
        return self
    }

    /// A one-page document at the canonical geometry.
    static func newDocument(documentID: UUID, pageID: UUID) -> DocumentIndex {
        DocumentIndex(
            formatVersion: Self.currentFormatVersion,
            documentID: documentID,
            pageWidth: PageGeometry.width,
            pageHeight: PageGeometry.height,
            pageIDs: [pageID],
            currentPageIndex: 0
        )
    }

    func withPages(_ pageIDs: [UUID], currentPageIndex: Int) -> DocumentIndex {
        DocumentIndex(
            formatVersion: formatVersion,
            documentID: documentID,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            pageIDs: pageIDs,
            currentPageIndex: currentPageIndex
        )
    }
}
