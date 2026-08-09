import CoreGraphics
import Foundation
@testable import TuberModel
@testable import TuberNotes
@testable import TuberStore
import UIKit

/// A unique document directory per test, removed when the test ends.
///
/// One writer for what "a scratch document" means. Twelve near-copies of this
/// class existed across eleven suites, each with its own directory prefix, its
/// own idea of whether to clean up (seven did not), and its own subset of the
/// same helpers — which is what a suite writes when the thing under test can
/// only ever be handed a real file system. The seam is `DocumentStoring`; this
/// is the one temp directory the suites that genuinely want files share.
///
/// A class, not a struct, because assertion closures capture it and because
/// `deinit` is the cleanup: a test that fails partway still removes its
/// directory.
///
/// Per-suite helpers stay in their suites, as private extensions on this type.
/// What is here is what more than one suite needs: the layout, a store over
/// it, raw writes that bypass the store, and the timestamp handling that
/// "only what changed was written" is asserted with.
final class TestScratch {
    let root: URL

    /// Stable for the life of the scratch: two `index(...)` calls describe the
    /// same document, which is what makes "the index was not rewritten" mean
    /// anything.
    let documentID = UUID()
    let defaultPageID = UUID()

    var documentURL: URL { root.appendingPathComponent("JustACanvas.tubernotes") }
    var indexURL: URL { documentURL.appendingPathComponent("document.plist") }
    var pagesURL: URL { documentURL.appendingPathComponent("pages") }
    var layersURL: URL { documentURL.appendingPathComponent("layers") }
    var assetsURL: URL { documentURL.appendingPathComponent("assets") }

    func pageURL(_ pageID: UUID) -> URL {
        pagesURL.appendingPathComponent("\(pageID.uuidString).plist")
    }

    func layerURL(_ layerID: UUID) -> URL {
        layersURL.appendingPathComponent("\(layerID.uuidString).plist")
    }

    func assetURL(_ assetID: UUID, _ ext: String) -> URL {
        assetsURL.appendingPathComponent("\(assetID.uuidString).\(ext)")
    }

    /// The store the suites that only need one share. Suites asserting about
    /// bytes on disk want `freshStore()` instead.
    let store: DocumentStore

    /// `label` names the directory so a leaked one says which suite leaked it.
    /// It is legibility only — `deinit` removes the directory either way.
    init(_ label: String = "scratch") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tubernotes-\(label)-\(UUID().uuidString)")
        store = DocumentStore(directoryURL: root.appendingPathComponent("JustACanvas.tubernotes"))
        try createDirectories()
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: root)
        } catch CocoaError.fileNoSuchFile {
            // A test that deliberately destroyed its own directory — the save
            // failure paths do — has nothing left to remove.
        } catch {
            // Cleanup, not an assertion: a leaked temp directory is the
            // simulator's problem and failing here would blame the wrong test.
        }
    }

    func createDirectories() throws {
        for directory in [pagesURL, layersURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// A fresh store each time, deliberately: it defeats the store's in-memory
    /// record of the last index it read or wrote, so assertions about what is
    /// on disk are about disk.
    func freshStore() -> DocumentStore {
        DocumentStore(directoryURL: documentURL)
    }

    func index(
        pageIDs: [UUID]? = nil,
        currentPageIndex: Int = 0,
        geometry: PageGeometry = .canonical
    ) -> DocumentIndex {
        DocumentIndex(
            formatVersion: DocumentIndex.currentFormatVersion,
            documentID: documentID,
            pages: (pageIDs ?? [defaultPageID]).map { PageRecord(id: $0, geometry: geometry) },
            currentPageIndex: currentPageIndex
        )
    }

    // MARK: - Raw writes, bypassing the store

    static func binaryEncoder() -> PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }

    /// Writes a page and its layers directly — the only way to put on disk
    /// what the store refuses to write.
    func writePage(_ pageID: UUID, layers: [LayerEnvelope]) throws {
        for layer in layers { try writeLayerFile(layer) }
        try writePageFileOnly(pageID, layerIDs: layers.map(\.layerID))
    }

    func writePageFileOnly(_ pageID: UUID, layerIDs: [UUID]) throws {
        let page = PageFile(pageID: pageID, layerIDs: layerIDs)
        try Self.binaryEncoder().encode(page).write(to: pageURL(pageID), options: .atomic)
    }

    func writeLayerFile(_ layer: LayerEnvelope, under name: UUID? = nil) throws {
        try Self.binaryEncoder().encode(layer).write(
            to: layerURL(name ?? layer.layerID),
            options: .atomic
        )
    }

    func writeIndexFile(_ index: DocumentIndex) throws {
        try Self.binaryEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    /// One page's layer envelopes as they are on disk, read the way the store
    /// reads them: the page file names the layers and each is its own file.
    func layersOnDisk(ofPage pageID: UUID) throws -> [LayerEnvelope] {
        let page = try PropertyListDecoder().decode(
            PageFile.self,
            from: Data(contentsOf: pageURL(pageID))
        )
        return try page.layerIDs.map { layerID in
            try PropertyListDecoder().decode(
                LayerEnvelope.self,
                from: Data(contentsOf: layerURL(layerID))
            )
        }
    }

    /// What the index file actually says, so "written forward" is an assertion
    /// about bytes rather than about a decoded value.
    func rawIndexKeys() throws -> Set<String> {
        let raw = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: indexURL),
            options: [],
            format: nil
        ) as? [String: Any]
        return Set((raw ?? [:]).keys)
    }

    // MARK: - What was written, and what was left alone

    /// The timestamp `freezeTimestamps` stamps on every existing file.
    ///
    /// Far enough in the past that no write can produce it by accident, and
    /// exact, so `== frozen` means *this file was not touched* rather than
    /// *this file was touched within the resolution of a clock*.
    static let frozen = Date(timeIntervalSinceReferenceDate: 0)

    /// Stamps every file in the document with `frozen`, so the next save's
    /// footprint is exactly the set of files whose modification date changed.
    ///
    /// This replaces sleeping past the filesystem's timestamp resolution.
    /// Nine tests used to wait 1.1 s of real time between two saves and then
    /// compare dates; under load the wait was the assertion's only margin, and
    /// those were the suite's flakes. Backdating removes the margin instead of
    /// widening it: an unwanted rewrite cannot hide inside a resolution it is
    /// twenty-five years away from.
    func freezeTimestamps() throws {
        for url in try everyFile() {
            try FileManager.default.setAttributes(
                [.modificationDate: Self.frozen],
                ofItemAtPath: url.path
            )
        }
    }

    /// Every regular file in the document directory.
    func everyFile() throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: documentURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        return try walker.compactMap { entry in
            guard let url = entry as? URL else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                ? url
                : nil
        }
    }

    /// Every file written or rewritten since `freezeTimestamps`, repo-relative
    /// to the document directory — so a failure names the files rather than
    /// only their count.
    func filesWrittenSinceFreeze() throws -> Set<String> {
        var written: Set<String> = []
        for url in try everyFile() where try modificationDate(of: url) != Self.frozen {
            written.insert(
                url.path.replacingOccurrences(of: documentURL.path + "/", with: "")
            )
        }
        return written
    }

    /// Every file in the document package, by path relative to it, with enough
    /// to notice any rewrite: when it was last written and what it contains.
    ///
    /// Content as well as mtime deliberately. An mtime comparison alone would
    /// miss a rewrite that landed inside the filesystem's timestamp
    /// resolution, and a content comparison alone would miss a rewrite of
    /// identical bytes — which is still the whole-file write this format
    /// exists to avoid. Together, neither kind of rewrite can hide. Taken
    /// after `freezeTimestamps`, the mtime half needs no waiting either.
    func snapshot() throws -> [String: FileState] {
        var out: [String: FileState] = [:]
        let base = documentURL.standardizedFileURL.path
        for url in try everyFile() {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            out[path] = FileState(
                modified: try modificationDate(of: url),
                bytes: try Data(contentsOf: url)
            )
        }
        return out
    }

    struct FileState: Equatable {
        let modified: Date?
        let bytes: Data
    }

    func modificationDate(of url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = values.contentModificationDate else {
            throw CocoaError(.fileReadUnknown)
        }
        return date
    }

    func modificationDate(ofPage pageID: UUID) throws -> Date {
        try modificationDate(of: pageURL(pageID))
    }

    func modificationDateOfIndex() throws -> Date {
        try modificationDate(of: indexURL)
    }

    /// When a page's ink last reached disk. Since the layer split that is the
    /// ink layer's own file, not the page file — a page whose ink changes but
    /// whose layer list does not never rewrites its page file at all.
    func inkWrittenAt(ofPage pageID: UUID) throws -> Date? {
        let page = try PropertyListDecoder().decode(
            PageFile.self,
            from: Data(contentsOf: pageURL(pageID))
        )
        guard let inkLayerID = page.layerIDs.last else { return nil }
        return try modificationDate(of: layerURL(inkLayerID))
    }

    /// When anything durable was last written, or `nil` if nothing has been
    /// yet.
    ///
    /// Timing tests poll this rather than `store.load()`: decoding a megabyte
    /// of property list on every poll would cost more than the intervals being
    /// measured and would show up inside them.
    ///
    /// It watches `layers/` as well as `pages/`, and that is not belt and
    /// braces — since the layer split an ordinary ink save writes **only** a
    /// layer file, so a probe that watched page files alone would see nothing
    /// land and wait forever.
    var savedAt: Date? {
        ((try? everyFile()) ?? []).compactMap { try? modificationDate(of: $0) }.max()
    }

    // MARK: - Fixtures

    static func solidHEIC(width: Int, height: Int, color: CGColor) -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            preconditionFailure("could not build a \(width)x\(height) context")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            preconditionFailure("the context yielded no image")
        }
        guard let encoded = ImageImportPreparation.heicEncoded(image) else {
            preconditionFailure("HEIC encoding failed")
        }
        return encoded
    }

    static func solidHEIC(width: Int, height: Int, color: UIColor) -> Data {
        solidHEIC(width: width, height: height, color: color.cgColor)
    }

    /// Writes an image asset and returns the layer envelope naming it.
    func imageLayer(
        color: CGColor,
        size: Int = 64,
        transform: PageSpaceTransform,
        store: (any DocumentStoring)? = nil
    ) async throws -> LayerEnvelope {
        let assetID = UUID()
        try await (store ?? self.store).writeAsset(
            Self.solidHEIC(width: size, height: size, color: color),
            assetID: assetID,
            format: .heic
        )
        return try LayerEnvelope.image(
            layerID: UUID(),
            ref: ImageLayerRef(assetID: assetID, format: .heic),
            pageSpaceTransform: transform
        )
    }

    func imageLayer(
        color: UIColor,
        size: Int = 64,
        transform: PageSpaceTransform,
        store: (any DocumentStoring)? = nil
    ) async throws -> LayerEnvelope {
        try await imageLayer(color: color.cgColor, size: size, transform: transform, store: store)
    }

    /// Writes PDF bytes as an asset and returns the pdf layer naming it.
    func pdfLayer(
        bytes: Data,
        sourcePageIndex: Int = 0,
        transform: PageSpaceTransform,
        store: (any DocumentStoring)? = nil
    ) async throws -> LayerEnvelope {
        let assetID = UUID()
        try await (store ?? self.store).writeAsset(bytes, assetID: assetID, format: .pdf)
        return try LayerEnvelope.pdf(
            layerID: UUID(),
            ref: PDFLayerRef(assetID: assetID, sourcePageIndex: sourcePageIndex),
            pageSpaceTransform: transform
        )
    }
}
