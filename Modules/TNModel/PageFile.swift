import Foundation

/// `pages/<PageID>.json`: the page's layer stack and where its ink sits.
///
/// `hasInk` records whether the page has ever committed ink, so a missing
/// container is a fault rather than a blank. `inkIndex` is the ink's
/// position in the bottom-to-top stack, `0...layers.count`.
package struct PageFile: Codable, Sendable, Equatable {
    package let pageID: PageID
    package let hasInk: Bool
    package let inkIndex: Int
    package let layers: [LayerID]

    package init(pageID: PageID, hasInk: Bool, inkIndex: Int, layers: [LayerID]) {
        self.pageID = pageID
        self.hasInk = hasInk
        self.inkIndex = inkIndex
        self.layers = layers
    }

    package static func empty(pageID: PageID) -> PageFile {
        PageFile(pageID: pageID, hasInk: false, inkIndex: 0, layers: [])
    }

    package func validated(expecting expected: PageID) throws(PageFault) -> PageFile {
        guard pageID == expected else { throw .pageIDMismatch(expected: expected, found: pageID) }
        guard inkIndex >= 0, inkIndex <= layers.count else { throw .invalidInkIndex(inkIndex) }
        var seen = Set<LayerID>()
        for layer in layers where !seen.insert(layer).inserted {
            throw .duplicateLayerID(layer)
        }
        return self
    }
}

/// Every reason a page is a placeholder. A page may carry several.
package enum PageFault: Error, Sendable, Equatable {
    case missingPageFile
    case pageFileUnreadable(String)
    case pageIDMismatch(expected: PageID, found: PageID)
    case invalidInkIndex(Int)
    case duplicateLayerID(LayerID)
    case missingInk
    case inkContainerInvalid(InkContainerFault)
    /// The container was sound and PencilKit refused its archive.
    case inkArchiveUndecodable(String)
    case unknownPaper(String)
    /// The paper names an asset that is not in the package.
    case paperAssetMissing(String)
    case layerRefused(LayerFault)
}

/// Why an ink container was refused.
package enum InkContainerFault: Error, Sendable, Equatable {
    case tooShort
    case badMagic
    case unsupportedVersion(UInt32)
    case notebookIDMismatch
    case pageIDMismatch
    case lengthMismatch(declared: UInt64, actual: Int)
    case checksumMismatch
}
