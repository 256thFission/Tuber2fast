import Foundation

/// One page's record in the index: identity, geometry, paper. Geometry is
/// chosen at creation and changes only with asset paper on an empty page;
/// paper may change, and the change rewrites the index.
package struct PageRecord: Codable, Sendable, Equatable, Identifiable {
    package let id: PageID
    package let width: Double
    package let height: Double
    package let paper: PaperKind

    package init(id: PageID, geometry: PageGeometry, paper: Paper) {
        self.id = id
        self.width = geometry.width
        self.height = geometry.height
        self.paper = .known(paper)
    }

    package init(id: PageID, width: Double, height: Double, paper: PaperKind) {
        self.id = id
        self.width = width
        self.height = height
        self.paper = paper
    }

    package var geometry: PageGeometry { PageGeometry(width: width, height: height) }

    package func with(paper: Paper, geometry: PageGeometry) -> PageRecord {
        PageRecord(id: id, geometry: geometry, paper: paper)
    }

    /// The asset this record's paper names, if it names one.
    package var paperAsset: AssetRef? { paper.paper?.asset }
}

/// The index: the commit point when it changes. Holds identity, creation
/// time, and the ordered page records. No ink, no current page, no zoom
/// cap: those live in the ink containers, `view.json`, and code.
package struct NotebookIndex: Codable, Sendable, Equatable {
    package let formatVersion: UInt32
    package let notebookID: NotebookID
    package let createdAt: Date
    package let pages: [PageRecord]

    package static let currentFormatVersion: UInt32 = 2

    package init(notebookID: NotebookID, createdAt: Date, pages: [PageRecord]) {
        self.formatVersion = Self.currentFormatVersion
        self.notebookID = notebookID
        self.createdAt = createdAt
        self.pages = pages
    }

    /// The decoder's form: the version as found, so a newer file refuses by
    /// number in `validated()` rather than as a decode failure.
    package init(formatVersion: UInt32, notebookID: NotebookID, createdAt: Date, pages: [PageRecord]) {
        self.formatVersion = formatVersion
        self.notebookID = notebookID
        self.createdAt = createdAt
        self.pages = pages
    }

    package var pageIDs: [PageID] { pages.map(\.id) }

    package func record(of page: PageID) -> PageRecord? {
        pages.first { $0.id == page }
    }

    /// A one-page notebook, US Letter and blank paper unless told otherwise.
    package static func new(
        notebookID: NotebookID, firstPage: PageID, createdAt: Date,
        geometry: PageGeometry = .letter, paper: DrawnPaper = .blank
    ) -> NotebookIndex {
        NotebookIndex(
            notebookID: notebookID,
            createdAt: createdAt,
            pages: [PageRecord(id: firstPage, geometry: geometry, paper: .drawn(paper))]
        )
    }

    package func withPages(_ pages: [PageRecord]) -> NotebookIndex {
        NotebookIndex(formatVersion: formatVersion, notebookID: notebookID, createdAt: createdAt, pages: pages)
    }

    package func withNotebookID(_ notebookID: NotebookID) -> NotebookIndex {
        NotebookIndex(formatVersion: formatVersion, notebookID: notebookID, createdAt: createdAt, pages: pages)
    }

    /// Notebook-scope rules, refused by name. Page-scope faults (unknown
    /// paper) are not thrown here; `pageFaults` reports them.
    package func validated() throws(NotebookIndexFault) -> NotebookIndex {
        guard formatVersion == Self.currentFormatVersion else {
            throw .unsupportedFormatVersion(formatVersion)
        }
        guard !pages.isEmpty else { throw .noPages }
        var seen = Set<PageID>()
        for page in pages {
            guard seen.insert(page.id).inserted else { throw .duplicatePageID(page.id) }
            guard page.geometry.isWithinBounds else {
                throw .geometryOutOfBounds(page.id, width: page.width, height: page.height)
            }
        }
        return self
    }

    /// Faults the index states about individual pages.
    package var pageFaults: [PageID: PageFault] {
        var faults: [PageID: PageFault] = [:]
        for page in pages {
            if case .unknown(let name) = page.paper { faults[page.id] = .unknownPaper(name) }
        }
        return faults
    }
}

package enum NotebookIndexFault: Error, Sendable, Equatable {
    case unsupportedFormatVersion(UInt32)
    case noPages
    case duplicatePageID(PageID)
    case geometryOutOfBounds(PageID, width: Double, height: Double)
}

/// `view.json`: disposable. Missing or invalid means the first page.
package struct ViewState: Codable, Sendable, Equatable {
    package let currentPageID: PageID
    package init(currentPageID: PageID) { self.currentPageID = currentPageID }
}
