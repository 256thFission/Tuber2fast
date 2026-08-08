import Foundation
import PencilKit
import Testing
@testable import TuberModel
@testable import TuberNotes
@testable import TuberStore
import UIKit

/// The library thumbnail pipeline, end to end over real packages: ink saved
/// through a real `DocumentStore` comes back as pixels, a blank page comes
/// back as paper, a corrupt package comes back as a cached refusal, the byte
/// bound evicts, and a save's new `modifiedAt` is a new key.
///
/// Decided here and stated (the proposal left it open): **a blank document
/// yields the paper render** — a real image, not nil — so a blank cell
/// settles instead of re-requesting its placeholder forever.
@Suite("Library thumbnails")
@MainActor
struct LibraryThumbnailTests {

    @Test("A saved document with real ink renders pixels the blank paper does not")
    func inkRendersDifferentlyFromBlankPaper() async throws {
        let inked = try TestScratch("thumb-ink")
        try await saveDrawing(Self.oneStroke(), in: inked)
        let blank = try TestScratch("thumb-blank")
        try await saveDrawing(PKDrawing(), in: blank)

        let store = LibraryThumbnailStore()
        let inkImage = try #require(await rendered(store, path: "a", url: inked.documentURL))
        let paperImage = try #require(await rendered(store, path: "b", url: blank.documentURL))

        // Same canonical geometry, so the images are the same size and a
        // byte-level difference is a pixel-level difference: the ink is there.
        #expect(inkImage.size == paperImage.size)
        #expect(inkImage.pngData() != paperImage.pngData())
    }

    @Test("A blank document yields the paper render, and two blanks agree")
    func blankDocumentYieldsThePaperRender() async throws {
        let first = try TestScratch("thumb-blank-1")
        try await saveDrawing(PKDrawing(), in: first)
        let second = try TestScratch("thumb-blank-2")
        try await saveDrawing(PKDrawing(), in: second)

        let store = LibraryThumbnailStore()
        let one = try #require(await rendered(store, path: "a", url: first.documentURL))
        let two = try #require(await rendered(store, path: "b", url: second.documentURL))

        // The paper render is deterministic: no ink, one fill color, one
        // geometry — so two blank documents are pixel-identical.
        #expect(one.pngData() == two.pngData())
    }

    @Test("A corrupt package yields a cached refusal, not a throw")
    func corruptPackageIsARefusalEntry() async throws {
        let scratch = try TestScratch("thumb-corrupt")
        // Bytes no property-list decoder will accept, where the index lives.
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: scratch.indexURL)

        let store = LibraryThumbnailStore()
        let key = LibraryThumbnailStore.Key(path: "corrupt", modifiedAt: TestScratch.frozen)
        await store.renderIfNeeded(for: key, documentURL: scratch.documentURL)

        guard case .refused = store.cached(for: key) else {
            Issue.record("a corrupt package cached \(String(describing: store.cached(for: key))), expected .refused")
            return
        }
    }

    @Test("The byte bound evicts least-recently-rendered entries")
    func byteBoundEvicts() async throws {
        let first = try TestScratch("thumb-evict-1")
        try await saveDrawing(PKDrawing(), in: first)
        let second = try TestScratch("thumb-evict-2")
        try await saveDrawing(PKDrawing(), in: second)

        // One canonical-page thumbnail is 320×414 px × 4 ≈ 530 KB, so a
        // 600 KB bound holds exactly one: the second install evicts the first.
        let store = LibraryThumbnailStore(byteBound: 600_000)
        let keyA = LibraryThumbnailStore.Key(path: "a", modifiedAt: TestScratch.frozen)
        let keyB = LibraryThumbnailStore.Key(path: "b", modifiedAt: TestScratch.frozen)
        await store.renderIfNeeded(for: keyA, documentURL: first.documentURL)
        await store.renderIfNeeded(for: keyB, documentURL: second.documentURL)

        #expect(store.cached(for: keyA) == nil, "the oldest entry should have been evicted")
        #expect(store.cached(for: keyB) != nil, "the newest entry must survive its own install")
    }

    @Test("A save's new modifiedAt is a new key, and the new key re-renders")
    func modifiedAtChangeRerenders() async throws {
        let scratch = try TestScratch("thumb-rerender")
        try await saveDrawing(PKDrawing(), in: scratch)

        let store = LibraryThumbnailStore()
        let before = LibraryThumbnailStore.Key(
            path: "doc",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let blankImage = try #require(await renderedKey(store, key: before, url: scratch.documentURL))

        // The save that changes the listing's modifiedAt.
        try await saveDrawing(Self.oneStroke(), in: scratch)
        let after = LibraryThumbnailStore.Key(
            path: "doc",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        // A distinct key: nothing cached under it yet, so it renders fresh —
        // and the fresh render carries the new ink.
        #expect(store.cached(for: after) == nil)
        let inkImage = try #require(await renderedKey(store, key: after, url: scratch.documentURL))
        #expect(inkImage.pngData() != blankImage.pngData())
    }

    // MARK: - Helpers

    /// Saves `drawing` as the scratch document's one page, through the real
    /// store — the same bytes a session's save would produce.
    private func saveDrawing(_ drawing: PKDrawing, in scratch: TestScratch) async throws {
        let envelope = LayerEnvelope(
            layerID: UUID(),
            kind: .ink,
            payload: drawing.dataRepresentation(),
            pageSpaceTransform: .identity
        )
        try await scratch.store.save(
            index: scratch.index(),
            pages: [PageWrite(pageID: scratch.defaultPageID, layers: [envelope])]
        )
    }

    private func rendered(
        _ store: LibraryThumbnailStore,
        path: String,
        url: URL
    ) async -> UIImage? {
        await renderedKey(
            store,
            key: LibraryThumbnailStore.Key(path: path, modifiedAt: TestScratch.frozen),
            url: url
        )
    }

    private func renderedKey(
        _ store: LibraryThumbnailStore,
        key: LibraryThumbnailStore.Key,
        url: URL
    ) async -> UIImage? {
        await store.renderIfNeeded(for: key, documentURL: url)
        if case .image(let image)? = store.cached(for: key) { return image }
        return nil
    }

    /// One black pen stroke across the page — enough ink that its pixels
    /// cannot hide in the paper.
    private static func oneStroke() -> PKDrawing {
        let start = PKStrokePoint(
            location: CGPoint(x: 100, y: 100),
            timeOffset: 0,
            size: CGSize(width: 12, height: 12),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
        let end = PKStrokePoint(
            location: CGPoint(x: 500, y: 680),
            timeOffset: 0.1,
            size: CGSize(width: 12, height: 12),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
        return PKDrawing(strokes: [
            PKStroke(
                ink: PKInk(.pen, color: .black),
                path: PKStrokePath(
                    controlPoints: [start, end],
                    creationDate: Date(timeIntervalSince1970: 0)
                )
            )
        ])
    }
}
