import Foundation

/// The index of a format version 2 document (`Contract.md` — Durable form).
///
/// It holds page identity, order, and geometry — and no ink. Ink lives in one
/// `PageFile` per page, so a save can rewrite one page without touching the
/// others.
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

/// One page's durable contents: an ordered list of layer envelopes, inlined
/// in the page file (per-layer files are phase 3 of
/// `Docs/Forks/CanvasFeatureComplete.md`, not this one).
///
/// `pageID` is repeated here only so that a page file read from disk can be
/// checked against the name it was filed under; it is the one deliberate
/// exception to the no-duplication rule above, and it exists to catch a
/// mixed-up or truncated directory rather than to be read as authority.
struct PageFile: Codable, Sendable, Equatable {
    let pageID: UUID
    let layers: [LayerEnvelope]

    init(pageID: UUID, layers: [LayerEnvelope]) {
        self.pageID = pageID
        self.layers = layers
    }

    private enum CodingKeys: String, CodingKey {
        case pageID
        case layers
        /// The pre-layer form: bare drawing bytes. Read-only — decoding
        /// accepts it, encoding never writes it, so an existing document
        /// migrates page by page as pages are next saved (write-forward),
        /// never eagerly.
        case drawingData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageID = try container.decode(UUID.self, forKey: .pageID)
        if let envelopes = try container.decodeIfPresent([LayerEnvelope].self, forKey: .layers) {
            layers = envelopes
        } else {
            // A pre-layer page file is a one-ink-layer page. The layer's
            // identity is minted at read time and becomes durable only when
            // the page is next written in layered form; until then the file
            // on disk is untouched.
            let drawingData = try container.decode(Data.self, forKey: .drawingData)
            layers = [
                LayerEnvelope(
                    layerID: UUID(),
                    kind: .ink,
                    payload: drawingData,
                    pageSpaceTransform: .identity
                )
            ]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageID, forKey: .pageID)
        try container.encode(layers, forKey: .layers)
    }
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
