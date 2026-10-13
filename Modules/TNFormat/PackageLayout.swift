import Foundation
import TNModel

/// Where every file in a `.tubernotes` package lives. Pure path arithmetic.
package struct PackageLayout: Sendable, Equatable {
    package let root: URL

    package init(root: URL) { self.root = root }

    package static let packageExtension = "tubernotes"

    package var indexURL: URL { root.appendingPathComponent("notebook.json") }
    package var viewURL: URL { root.appendingPathComponent("view.json") }
    package var pagesDirectory: URL { root.appendingPathComponent("pages", isDirectory: true) }
    package var inkDirectory: URL { root.appendingPathComponent("ink", isDirectory: true) }
    package var layersDirectory: URL { root.appendingPathComponent("layers", isDirectory: true) }
    package var assetsDirectory: URL { root.appendingPathComponent("assets", isDirectory: true) }

    package func pageURL(_ page: PageID) -> URL {
        pagesDirectory.appendingPathComponent("\(page.raw.uuidString).json")
    }
    package func inkURL(_ page: PageID) -> URL {
        inkDirectory.appendingPathComponent("\(page.raw.uuidString).tnink")
    }
    package func layerURL(_ layer: LayerID) -> URL {
        layersDirectory.appendingPathComponent("\(layer.raw.uuidString).json")
    }
    package func assetURL(_ asset: AssetRef) -> URL {
        assetsDirectory.appendingPathComponent(asset.fileName)
    }

    package var directories: [URL] { [root, pagesDirectory, inkDirectory, layersDirectory, assetsDirectory] }
}
