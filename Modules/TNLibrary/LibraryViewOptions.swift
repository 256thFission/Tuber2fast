import Foundation
import TNModel

package enum LibrarySortKey: String, Codable, CaseIterable, Sendable {
    case dateCreated, lastModified, name, type

    /// Dates newest first; names and kinds A to Z.
    package var defaultAscending: Bool {
        switch self {
        case .dateCreated, .lastModified: false
        case .name, .type: true
        }
    }
}

package enum LibraryLayout: String, Codable, Sendable {
    case grid, list
}

/// What the New notebook sheet opens on: the size and paper last created
/// here.
///
/// A `PageGeometry` rather than a catalogue name, because the catalogue —
/// `PageSize` — lives in `TNEditor`, which the library does not import, and
/// `PageSize.matching(_:)` recovers the name at the sheet from the two
/// numbers.
package struct NotebookSetup: Codable, Equatable, Sendable {
    package let geometry: PageGeometry
    package let paper: DrawnPaper

    package init(geometry: PageGeometry, paper: DrawnPaper) {
        self.geometry = geometry
        self.paper = paper
    }
}

/// How every listing is shown. One global setting, not one per folder.
package struct LibraryViewOptions: Codable, Equatable, Sendable {
    package var layout = LibraryLayout.grid
    package var sortKey = LibrarySortKey.lastModified
    package var ascending = false
    /// nil until a notebook has been created on this device, which is what
    /// makes the sheet's built-in default the one it opens on the first time.
    package var newNotebook: NotebookSetup?

    package init(
        layout: LibraryLayout = .grid,
        sortKey: LibrarySortKey = .lastModified,
        ascending: Bool = false,
        newNotebook: NotebookSetup? = nil
    ) {
        self.layout = layout
        self.sortKey = sortKey
        self.ascending = ascending
        self.newNotebook = newNotebook
    }

    /// The active key flips its direction; a new key takes its own default.
    package func tapping(_ key: LibrarySortKey) -> LibraryViewOptions {
        var next = self
        if key == sortKey {
            next.ascending.toggle()
        } else {
            next.sortKey = key
            next.ascending = key.defaultAscending
        }
        return next
    }

    /// Folders and notebooks interleave under every key except `.type`,
    /// which puts folders first whichever way it runs and orders names
    /// within each kind. A name compare breaks every other tie, so the order
    /// is stable across reloads.
    package func sorted(_ items: [LibraryItem]) -> [LibraryItem] {
        items.sorted { a, b in
            let byKey: ComparisonResult
            switch sortKey {
            case .dateCreated: byKey = compare(a.createdAt, b.createdAt)
            case .lastModified: byKey = compare(a.modifiedAt, b.modifiedAt)
            case .name: byKey = a.name.localizedStandardCompare(b.name)
            case .type:
                if a.kind != b.kind { return a.kind == .folder }
                byKey = a.name.localizedStandardCompare(b.name)
            }
            if byKey != .orderedSame { return ascending ? byKey == .orderedAscending : byKey == .orderedDescending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}

/// Where the options are kept between launches. The app's store is
/// `UserDefaults`; a test's is memory.
package protocol LibraryViewOptionsStore: Sendable {
    func load() -> LibraryViewOptions?
    func save(_ options: LibraryViewOptions)
}
