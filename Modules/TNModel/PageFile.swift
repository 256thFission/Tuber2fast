import Foundation

/// `pages/<PageID>.json`: the page's layer stack, bottom to top. The ink is
/// drawn above all of it.
///
/// `hasInk` records whether the page has ever committed ink, so a missing
/// container is a fault rather than a blank.
package struct PageFile: Codable, Sendable, Equatable {
    package let pageID: PageID
    package let hasInk: Bool
    package let layers: [LayerID]

    package init(pageID: PageID, hasInk: Bool, layers: [LayerID]) {
        self.pageID = pageID
        self.hasInk = hasInk
        self.layers = layers
    }

    package static func empty(pageID: PageID) -> PageFile {
        PageFile(pageID: pageID, hasInk: false, layers: [])
    }

    package func validated(expecting expected: PageID) throws(PageFault) -> PageFile {
        guard pageID == expected else { throw .pageIDMismatch(expected: expected, found: pageID) }
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
    case duplicateLayerID(LayerID)
    case missingInk
    case inkContainerInvalid(InkContainerFault)
    /// The container was sound and PencilKit refused its archive.
    case inkArchiveUndecodable(String)
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
