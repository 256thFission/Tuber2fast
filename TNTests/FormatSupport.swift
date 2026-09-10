import Foundation
import Testing
@testable import TNFormat
@testable import TNModel

/// A scratch directory per test, deleted when the value goes away.
final class Scratch: Sendable {
    let root: URL

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tn-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var packageURL: URL { root.appendingPathComponent("Scratch.tubernotes", isDirectory: true) }

    func copyPackage(to name: String) throws -> URL {
        let destination = root.appendingPathComponent("\(name).tubernotes", isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: packageURL, to: destination)
        return destination
    }

    func backdate(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }
}

enum Fixture {
    static func archive(_ seed: UInt8, count: Int = 2048) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: Int($0) &* 7 &+ Int(seed)) })
    }

    static func index(pages: Int, notebookID: NotebookID = NotebookID()) -> NotebookIndex {
        NotebookIndex(
            notebookID: notebookID,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            pages: (0..<pages).map { _ in PageRecord(id: PageID(), geometry: .letter, paper: .lined) }
        )
    }

    static func imageLayer(asset: AssetRef = AssetRef(id: AssetID(), format: .heic)) -> Layer {
        Layer(
            id: LayerID(),
            transform: .placing(sourceWidth: 300, sourceHeight: 200, at: (10, 20), scale: 1),
            payload: .image(ImageLayer(asset: asset, naturalSize: PixelSize(width: 300, height: 200)))
        )
    }

    static func pdfLayer(asset: AssetRef = AssetRef(id: AssetID(), format: .pdf)) -> Layer {
        Layer(
            id: LayerID(),
            transform: .placing(sourceWidth: 612, sourceHeight: 792, at: (0, 0), scale: 1),
            payload: .pdf(PDFLayer(asset: asset, sourcePageIndex: 0, sourceExtent: SourceExtent(x: 0, y: 0, width: 612, height: 792, rotation: 0)))
        )
    }

    static func textLayer() -> Layer {
        Layer(
            id: LayerID(),
            transform: .identity,
            payload: .text(TextLayer(
                rect: PageRect(x: 30, y: 30, width: 300, height: 80),
                runs: [TextRun(string: "Hello, "), TextRun(string: "world", bold: true, color: "#1971C2FF")],
                alignment: .leading))
        )
    }

    static func linkLayer(to page: PageID) -> Layer {
        Layer(
            id: LayerID(),
            transform: .identity,
            payload: .link(LinkLayer(rect: PageRect(x: 40, y: 40, width: 160, height: 44), style: .button, target: .internalPage(page)))
        )
    }

    /// A three-page notebook: page 0 with ink, page 1 with an image layer and
    /// ink, page 2 blank. Returns the store and the index it committed.
    static func populated(at url: URL, fileSystem: any PackageFileSystem = PosixFileSystem()) async throws -> (PackageStore, NotebookIndex, Layer) {
        let index = index(pages: 3)
        let store = try await PackageStore.create(root: url, index: index, fileSystem: fileSystem)
        let layer = imageLayer()
        try await store.writeAsset(archive(9, count: 512), layer.payload.asset!)
        let ids = index.pageIDs
        let batch = SaveBatch(index: index, indexChanged: false, pages: [
            PageWrite(file: PageFile(pageID: ids[0], hasInk: true, inkIndex: 0, layers: []), ink: .archive(archive(1)), layerFiles: []),
            PageWrite(file: PageFile(pageID: ids[1], hasInk: true, inkIndex: 1, layers: [layer.id]), ink: .archive(archive(2)), layerFiles: [layer]),
        ])
        let report = try await store.save(batch)
        try #require(report.refusals.isEmpty)
        return (store, index, layer)
    }
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
