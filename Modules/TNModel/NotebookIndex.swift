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

/// One marked page and what it is called. Presence is the mark: there is no
/// `bookmarked: false`. `title` may be empty, a mark nobody named; the
/// outline then shows that page's number, computed from the order.
package struct PageBookmark: Codable, Sendable, Equatable {
    package let page: PageID
    package let title: String

    package init(page: PageID, title: String) {
        self.page = page
        self.title = title
    }
}

/// The index: the commit point when it changes. Holds identity, creation
/// time, the ordered page records, and which pages are marked. No ink, no
/// current page, no zoom cap: those live in the ink containers, `view.json`,
/// and code.
package struct NotebookIndex: Codable, Sendable, Equatable {
    package let formatVersion: UInt32
    package let notebookID: NotebookID
    package let createdAt: Date
    package let pages: [PageRecord]
    /// Order here is insertion order and means nothing: the outline reads
    /// `pages` and picks out the marked ones, so it comes out in page order
    /// without this list being kept in it.
    package let bookmarks: [PageBookmark]

    package static let currentFormatVersion: UInt32 = 4

    package init(notebookID: NotebookID, createdAt: Date, pages: [PageRecord], bookmarks: [PageBookmark]) {
        self.formatVersion = Self.currentFormatVersion
        self.notebookID = notebookID
        self.createdAt = createdAt
        self.pages = pages
        self.bookmarks = bookmarks
    }

    /// The decoder's form: the version as found, so a newer file refuses by
    /// number in `validated()` rather than as a decode failure.
    package init(
        formatVersion: UInt32, notebookID: NotebookID, createdAt: Date,
        pages: [PageRecord], bookmarks: [PageBookmark]
    ) {
        self.formatVersion = formatVersion
        self.notebookID = notebookID
        self.createdAt = createdAt
        self.pages = pages
        self.bookmarks = bookmarks
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
            pages: [PageRecord(id: firstPage, geometry: geometry, paper: .drawn(paper))],
            bookmarks: []
        )
    }

    /// The page list, and only the marks that name a page still in it.
    ///
    /// The filter is load-bearing, not tidiness. Publish 3 of a save writes
    /// `intended.withPages(present)` when a page failed to stage, so without
    /// it one page that fails to stage while holding a mark writes an index
    /// this build's own `validated()` refuses, and the notebook never opens
    /// again — where the contract's *Refuse at the narrowest scope* says a
    /// missing page file refuses that page only. With the filter here,
    /// deleting a page needs no filter of its own either.
    package func withPages(_ pages: [PageRecord]) -> NotebookIndex {
        let kept = Set(pages.map(\.id))
        return NotebookIndex(
            formatVersion: formatVersion, notebookID: notebookID, createdAt: createdAt,
            pages: pages, bookmarks: bookmarks.filter { kept.contains($0.page) }
        )
    }

    package func withBookmarks(_ bookmarks: [PageBookmark]) -> NotebookIndex {
        NotebookIndex(
            formatVersion: formatVersion, notebookID: notebookID, createdAt: createdAt,
            pages: pages, bookmarks: bookmarks
        )
    }

    /// A duplicate keeps its outline: the copy has the same pages under the
    /// same identities, so the marks that name them still name pages.
    package func withNotebookID(_ notebookID: NotebookID) -> NotebookIndex {
        NotebookIndex(
            formatVersion: formatVersion, notebookID: notebookID, createdAt: createdAt,
            pages: pages, bookmarks: bookmarks
        )
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
        // A mark is a page's, so a mark that names no page and two marks for
        // one page are both invalid states, and an invalid index refuses the
        // notebook — the narrowest scope an index fault has.
        var marked = Set<PageID>()
        for bookmark in bookmarks {
            guard seen.contains(bookmark.page) else { throw .bookmarkedPageMissing(bookmark.page) }
            guard marked.insert(bookmark.page).inserted else { throw .duplicateBookmark(bookmark.page) }
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
    case bookmarkedPageMissing(PageID)
    case duplicateBookmark(PageID)
}

/// `view.json`: disposable. Missing or invalid means the first page.
package struct ViewState: Codable, Sendable, Equatable {
    package let currentPageID: PageID
    package init(currentPageID: PageID) { self.currentPageID = currentPageID }
}
