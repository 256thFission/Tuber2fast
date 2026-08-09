import Foundation

/// One page's identity and its geometry — the index's record of a page, and
/// **the durable home of per-page geometry**.
///
/// ## Why here rather than in the page file
///
/// The page file is the obvious home and it is the wrong one, for a reason that
/// only shows up in the paging arithmetic. `PagedCanvasController` sizes its
/// scroll content and places every slot before any page outside the live window
/// has been read; page files are read lazily, one at a time, because reading
/// them all is the whole-document read this format exists to avoid. Geometry in
/// the page file leaves exactly two options, and both are worse than one small
/// record per page in a file that is already read whole:
///
/// - read every page file at open, so opening a notebook scales with its total
///   size — the thing `Durable form` is built to prevent; or
/// - lay pages out at a guessed size and re-lay them as their files arrive,
///   which moves the content offset of every later page under the user's
///   finger, mid-scroll. A page turn's landing offset would depend on what had
///   finished loading.
///
/// It costs nothing in writes, either: geometry is immutable after page
/// creation, and creating a page already rewrites the index because page order
/// changed. There is no save that writes geometry and would not have written
/// the index anyway.
///
/// It also keeps the no-duplication rule true. Geometry lives here and nowhere
/// else; a page file still holds only its own ID and its layer list.
package struct PageRecord: Codable, Sendable, Equatable {
    package let id: UUID
    package let geometry: PageGeometry

    // Spelled out because a memberwise initializer is `internal` however
    // visible its type is.
    package init(id: UUID, geometry: PageGeometry) {
        self.id = id
        self.geometry = geometry
    }
}

/// The index of a document (`Contract.md` — Durable form).
///
/// It holds page identity, page order, per-page geometry, and the document's
/// zoom cap — and no ink. Ink lives in a layer file named by one `PageFile` per
/// page, so a save can rewrite one page's ink without touching the other pages,
/// that page's other layers, or this index.
///
/// Nothing here is duplicated in a page file. A value stored in two places is a
/// value that can disagree with itself, and the disagreement would only surface
/// on a document the user could no longer open.
///
/// One form is read and the same one is written; `formatVersion` exists so that
/// an index written by a *newer* build refuses to open by name rather than
/// decoding into something plausible.
package struct DocumentIndex: Codable, Sendable, Equatable {
    package let formatVersion: UInt32
    package let documentID: UUID
    /// The document's pages, in order, each with its own geometry.
    package let pages: [PageRecord]
    package let currentPageIndex: Int

    /// The absolute zoom cap, in page points per pixel — the fewest page points
    /// one device pixel may represent, anywhere in this document.
    ///
    /// **A durable document constant, deliberately, and not a global** (A9).
    /// The cap used to be `fitWidth × 8`: a function of the viewport, so it
    /// changed with the device, the rotation, and Split View. Anything durable
    /// derived from a moving ceiling is unsound — "pixels beyond the ceiling are
    /// unreachable forever" is false if the ceiling moves — and the lens
    /// arithmetic wants a bounded detail level anyway. Storing it per document
    /// rather than reading the application's constant is what makes that
    /// promise survive a later change to the constant: a document keeps the
    /// ceiling it was written under.
    package let zoomCapPagePointsPerPixel: Double

    /// The one index form this build reads and writes. Its only job is to
    /// refuse a file written by a newer build, so the count starts where a
    /// count starts.
    package static let currentFormatVersion: UInt32 = 1

    /// **1/20 of a page point per pixel** — twenty device pixels per page point
    /// at the deepest zoom this application allows.
    ///
    /// The number is not free: `PKCanvasView` silently refuses a
    /// `maximumZoomScale` above 10 (see `PageProjection.runtimeMaximumZoomScale`,
    /// which records the measurement), so at the display scale of 2 that every
    /// shipping iPad has, twenty pixels per page point *is* the deepest zoom the
    /// framework will give. A deeper cap would be a durable promise the runtime
    /// cannot keep, and `PageCanvasController` fails loud rather than quietly
    /// delivering less.
    ///
    /// Nothing loses zoom by the change. `fitWidth × 8` exceeds 10 whenever
    /// fit-width exceeds 1.25 — every iPad in portrait — so those devices were
    /// already sitting on the framework's clamp at exactly this detail. The
    /// smallest iPad in portrait fell just short of it (fit-width ≈ 1.22, so
    /// ≈ 9.7), and now reaches the same ceiling as the largest. At a display
    /// scale of 3 the same cap asks for 6.67, comfortably inside the clamp and
    /// the same pixel-level detail — which is the property pinning it buys.
    ///
    /// Whether it *feels* right at the extremes is a maintainer's verdict on a
    /// physical iPad; what is settled here is that it does not move.
    package static let canonicalZoomCapPagePointsPerPixel: Double = 1.0 / 20.0

    package init(
        formatVersion: UInt32,
        documentID: UUID,
        pages: [PageRecord],
        currentPageIndex: Int,
        zoomCapPagePointsPerPixel: Double = DocumentIndex.canonicalZoomCapPagePointsPerPixel
    ) {
        self.formatVersion = formatVersion
        self.documentID = documentID
        self.pages = pages
        self.currentPageIndex = currentPageIndex
        self.zoomCapPagePointsPerPixel = zoomCapPagePointsPerPixel
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case documentID
        case pages
        case currentPageIndex
        case zoomCapPagePointsPerPixel
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let onDisk = try container.decode(UInt32.self, forKey: .formatVersion)
        let documentID = try container.decode(UUID.self, forKey: .documentID)
        let currentPageIndex = try container.decode(Int.self, forKey: .currentPageIndex)

        // A version this build does not write decodes as far as it can and is
        // refused by `validated()`, which names the number it found. Refusing
        // inside `init(from:)` would report a decode failure instead, which
        // reads as a corrupt file rather than as a newer one — which is why
        // the two fields a newer form need not carry are optional here and
        // nowhere else.
        self.init(
            formatVersion: onDisk,
            documentID: documentID,
            pages: try container.decodeIfPresent([PageRecord].self, forKey: .pages) ?? [],
            currentPageIndex: currentPageIndex,
            zoomCapPagePointsPerPixel: try container.decodeIfPresent(
                Double.self,
                forKey: .zoomCapPagePointsPerPixel
            ) ?? Self.canonicalZoomCapPagePointsPerPixel
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(pages, forKey: .pages)
        try container.encode(currentPageIndex, forKey: .currentPageIndex)
        try container.encode(zoomCapPagePointsPerPixel, forKey: .zoomCapPagePointsPerPixel)
    }
}

package enum DocumentIndexError: Error, Equatable {
    case unsupportedFormatVersion(UInt32)
    case invalidGeometry(pageID: UUID, width: Double, height: Double)
    case invalidZoomCap(Double)
    case noPages
    case duplicatePageID(UUID)
    case currentPageOutOfRange(index: Int, pageCount: Int)
    case missingPageFile(UUID)
    case pageIDMismatch(expected: UUID, found: UUID)
}

extension DocumentIndex {
    /// The document's pages, by identity, in order. Computed rather than
    /// stored, because a second list of the same IDs is a list that can
    /// disagree with the first.
    package var pageIDs: [UUID] { pages.map(\.id) }

    package func geometry(ofPageAt index: Int) -> PageGeometry? {
        guard pages.indices.contains(index) else { return nil }
        return pages[index].geometry
    }

    /// What a page's canvas is built with: its own geometry, and the document's
    /// zoom cap.
    package func projection(ofPageAt index: Int) -> PageProjection? {
        guard let geometry = geometry(ofPageAt: index) else { return nil }
        return PageProjection(
            geometry: geometry,
            zoomCapPagePointsPerPixel: zoomCapPagePointsPerPixel
        )
    }

    /// Every field the contract constrains, checked in one place.
    package func validated() throws -> DocumentIndex {
        guard formatVersion == Self.currentFormatVersion else {
            throw DocumentIndexError.unsupportedFormatVersion(formatVersion)
        }
        // Finite page points greater than zero, per page. `pageWidth <
        // pageHeight` is gone with phase 3b — landscape sources exist — and so
        // is equality with the canonical page: an imported page's geometry is
        // its source's, and rejecting it here is how phase 3a came to
        // letterbox a landscape worksheet into a portrait page.
        for page in pages where !page.geometry.isValid {
            throw DocumentIndexError.invalidGeometry(
                pageID: page.id,
                width: page.geometry.width,
                height: page.geometry.height
            )
        }
        // Rejected rather than clamped, at both ends. A cap that cannot resolve
        // a single page point at maximum zoom is not a document anyone can
        // write in, and a non-positive or infinite one is not a limit at all.
        // A cap *finer* than the canvas runtime will deliver is worse than
        // either: the document would promise a detail level `PKCanvasView`
        // silently refuses, and every consumer of "pixels beyond the ceiling
        // are unreachable" would be reasoning about a ceiling that does not
        // exist. It is refused here, at load, so it surfaces as a document that
        // will not open rather than as a canvas that quietly gives less.
        guard zoomCapPagePointsPerPixel.isFinite,
              zoomCapPagePointsPerPixel >= PageProjection.finestReachablePagePointsPerPixel,
              zoomCapPagePointsPerPixel <= 1
        else {
            throw DocumentIndexError.invalidZoomCap(zoomCapPagePointsPerPixel)
        }
        guard !pages.isEmpty else { throw DocumentIndexError.noPages }

        var seen = Set<UUID>()
        for page in pages where !seen.insert(page.id).inserted {
            throw DocumentIndexError.duplicatePageID(page.id)
        }

        // Rejected rather than clamped, for the reason an unreachable page
        // height was: silently correcting a value hides whatever wrote it.
        guard pages.indices.contains(currentPageIndex) else {
            throw DocumentIndexError.currentPageOutOfRange(
                index: currentPageIndex,
                pageCount: pages.count
            )
        }
        return self
    }

    /// A one-page document at the canonical geometry.
    package static func newDocument(documentID: UUID, pageID: UUID) -> DocumentIndex {
        DocumentIndex(
            formatVersion: Self.currentFormatVersion,
            documentID: documentID,
            pages: [PageRecord(id: pageID, geometry: .canonical)],
            currentPageIndex: 0
        )
    }

    package func withPages(_ pages: [PageRecord], currentPageIndex: Int) -> DocumentIndex {
        DocumentIndex(
            formatVersion: formatVersion,
            documentID: documentID,
            pages: pages,
            currentPageIndex: currentPageIndex,
            zoomCapPagePointsPerPixel: zoomCapPagePointsPerPixel
        )
    }
}
