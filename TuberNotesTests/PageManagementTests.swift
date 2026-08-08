import Foundation
import Testing
@testable import TuberCanvas
@testable import TuberModel
@testable import TuberNotes
@testable import TuberStore
import UIKit

/// Inserting, deleting, reordering, and duplicating pages — the operations
/// that made page *identity* load-bearing, and the gate that serializes them.
@Suite("Page management")
@MainActor
struct PageManagementTests {
    // MARK: - Delete: which page you are left standing on

    @Test("The last page of a document cannot be deleted")
    func deletingTheOnlyPageIsRefused() async throws {
        let scratch = try TestScratch("pages")
        let session = scratch.pageSession()
        await session.start()

        await #expect(throws: PageEditError.lastPage) {
            try await session.deletePage(session.currentPageID)
        }

        // "A document always has at least one page" (`Contract.md` — Durable
        // form). Refused at intake, and still true on disk afterwards.
        #expect(session.pageCount == 1)
        let saved = try await scratch.freshStore().load()
        #expect(saved?.pageIDs.count == 1)
    }

    @Test("Deleting the visible page lands you on the one that slides under it")
    func deletingTheCurrentPageStepsOntoItsSuccessor() async throws {
        let world = try await threePages()
        let pages = world.pageIDs
        turn(world.session, to: 1)

        try await world.session.deletePage(pages[1])

        #expect(world.session.pageCount == 2)
        #expect(world.session.currentPageID == pages[2], "the successor slides under the finger")
    }

    @Test("Deleting the last page steps back onto its predecessor")
    func deletingTheLastPageStepsBack() async throws {
        let world = try await threePages()
        let pages = world.pageIDs
        turn(world.session, to: 2)

        try await world.session.deletePage(pages[2])

        #expect(world.session.pageCount == 2)
        #expect(world.session.currentPageID == pages[1], "there is nothing after it to step onto")
    }

    @Test("Deleting a page ahead of you leaves you on the same page")
    func deletingAnEarlierPageKeepsYouWhereYouAre() async throws {
        let world = try await threePages()
        let pages = world.pageIDs
        turn(world.session, to: 2)

        try await world.session.deletePage(pages[0])

        // The *page* is preserved, not its number: it is page 2 of 2 now.
        #expect(world.session.currentPageID == pages[2])
        #expect(world.session.pageIDForTesting(at: 1) == pages[2])
    }

    // MARK: - Delete: what reaches disk

    @Test("A deleted page leaves the index and its survivors reload exactly")
    func deleteIsDurableAndSurvivorsRoundTrip() async throws {
        let world = try await threePages()
        let pages = world.pageIDs

        try await world.session.deletePage(pages[0])

        let reloaded = try #require(await world.scratch.freshStore().load())
        #expect(reloaded.pageIDs == [pages[1], pages[2]])
        #expect(!FileManager.default.fileExists(atPath: world.scratch.pageURL(pages[0]).path))
        // The survivors are byte-exact, not merely present.
        for pageID in [pages[1], pages[2]] {
            let survivor = try await world.scratch.freshStore().loadPage(pageID)
            #expect(survivor.staticLayers.count == 1)
        }
    }

    @Test("Deleting a page reclaims its files root to leaf: page, layers, asset")
    func deleteReclaimsRootToLeaf() async throws {
        let world = try await threePages()
        let doomed = world.pageIDs[1]
        let layer = try #require(world.scratch.layersOnDisk(ofPage: doomed).first)
        let assetID = try ImageLayerRef(payload: layer.payload).assetID
        #expect(
            FileManager.default.fileExists(
                atPath: world.scratch.assetURL(assetID, "heic").path
            )
        )

        try await world.session.deletePage(doomed)

        // The order is the whole of this test. Reclaiming leaves-first
        // reclaims **nothing**: while the page file survives it still names
        // every layer, so the layer scan keeps them all, and the asset scan
        // then finds those surviving layer files and keeps their assets too.
        #expect(!FileManager.default.fileExists(atPath: world.scratch.pageURL(doomed).path))
        #expect(!FileManager.default.fileExists(atPath: world.scratch.layerURL(layer.layerID).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: world.scratch.assetURL(assetID, "heic").path
            )
        )
    }

    @Test("An asset another page still references survives deleting one of them")
    func sharedAssetSurvivesDeletingOnePage() async throws {
        let world = try await threePages()
        let doomed = world.pageIDs[1]
        let keeper = world.pageIDs[2]
        let doomedAsset = try ImageLayerRef(
            payload: try #require(world.scratch.layersOnDisk(ofPage: doomed).first).payload
        ).assetID
        let keeperAsset = try ImageLayerRef(
            payload: try #require(world.scratch.layersOnDisk(ofPage: keeper).first).payload
        ).assetID
        #expect(doomedAsset != keeperAsset, "each import writes its own asset")

        try await world.session.deletePage(doomed)

        // Reclamation asks the disk, and the disk still holds the keeper's
        // layer file naming its own asset. The scan is per asset, so the
        // survivor is untouched by its neighbour's deletion.
        #expect(
            FileManager.default.fileExists(
                atPath: world.scratch.assetURL(keeperAsset, "heic").path
            )
        )
        #expect(try await world.scratch.freshStore().loadPage(keeper).staticLayers.count == 1)
    }

    @Test("Deleting a page nobody wrote on asks nothing of disk")
    func deletingATrailingUnwrittenPageTouchesNothing() async throws {
        let scratch = try TestScratch("pages")
        let counting = CountingReclaimStore(scratch.freshStore())
        let session = EditorSession(store: counting, debounce: .milliseconds(20))
        await session.start()
        host(session)
        let first = session.currentPageID
        pullPastTheEnd(session)
        let appended = session.currentPageID
        #expect(appended != first)
        await counting.resetCounts()

        try await session.deletePage(appended)

        // The index never named it and no file was ever written for it, so
        // there is nothing to reclaim and nothing that could be an orphan.
        // Asking anyway would be three directory scans for a page that never
        // reached disk.
        #expect(await counting.pageDeletes == 0)
        #expect(await counting.layerDeletes == 0)
        #expect(await counting.assetDeletes == 0)
        #expect(session.currentPageID == first)
    }

    @Test("Reclamation is skipped while any page holds an unsaved layer list")
    func reclamationIsSkippedUnderAnUnsavedLayerList() async throws {
        let scratch = try TestScratch("pages")
        let refusing = RefusingStore(scratch.freshStore())
        let session = EditorSession(store: refusing, debounce: .milliseconds(20))
        await session.start()
        host(session)

        pullPastTheEnd(session)
        let doomed = session.currentPageID
        let doomedLayer = try await session.importImage(
            Data([0x05]), format: .heic, sourceWidth: 100, sourceHeight: 100, onPage: doomed
        )

        // A page whose layer list exists only in memory: the store refuses its
        // page write for good, so nothing about it ever reaches disk.
        pullPastTheEnd(session)
        let stranded = session.currentPageID
        await refusing.refuse(stranded)
        try await session.importImage(
            Data([0x06]), format: .heic, sourceWidth: 100, sourceHeight: 100, onPage: stranded
        )

        try await session.deletePage(doomed)

        // The scans answer from disk and are blind to a list that never
        // landed, so reclaiming on its behalf could destroy a write-once asset
        // a surviving page still needs. Skipping costs an orphan, which
        // *Durable form* rules inert.
        #expect(FileManager.default.fileExists(atPath: scratch.layerURL(doomedLayer).path))
        #expect(session.pageCount == 2)
    }

    // MARK: - The structural gate

    @Test("Two page edits issued at once each remove the page they named")
    func concurrentDeletesEachTakeTheirOwnPage() async throws {
        let world = try await threePages()
        let session = world.session
        let pages = world.pageIDs

        // Issued in the same turn of the main actor, so both see the same
        // world before either has mutated it. The failure this refuses is
        // positional: an operation that resolved its page to an index before
        // suspending removes whatever slid into that index while it waited.
        //
        // It does **not** distinguish the structural tail from the drain loop
        // in `quiesceSaves` — deleting two pages commutes, so both orders end
        // here. See `inStructuralGate`, which says so.
        let first = Task { try await session.deletePage(pages[0]) }
        let second = Task { try await session.deletePage(pages[1]) }
        try await first.value
        try await second.value

        #expect(session.pageCount == 1)
        #expect(session.pageIDForTesting(at: 0) == pages[2])
    }

    @Test("A page edit waits out the save in flight rather than mutating under it")
    func deleteWaitsForTheSaveInFlight() async throws {
        let scratch = try TestScratch("pages")
        let held = HeldSaveStore(scratch.freshStore())
        let session = EditorSession(store: held, debounce: .milliseconds(10))
        await session.start()
        host(session)
        pullPastTheEnd(session)
        let doomed = session.currentPageID
        try await session.importImage(
            Data([0x07]), format: .heic, sourceWidth: 100, sourceHeight: 100, onPage: doomed
        )

        // A save is captured and cannot return.
        await held.hold()
        pullPastTheEnd(session)
        let third = session.currentPageID
        let importing = Task {
            try await session.importImage(
                Data([0x08]), format: .heic, sourceWidth: 100, sourceHeight: 100, onPage: third
            )
        }
        try await Task.sleep(for: .milliseconds(30))

        let deletion = Task { try await session.deletePage(doomed) }
        try await Task.sleep(for: .milliseconds(20))
        // The gate is holding it behind the save: the page is still here.
        #expect(session.pageCount == 3)

        await held.release()
        _ = try await importing.value
        try await deletion.value

        #expect(session.pageCount == 2)
        // The capture that was in flight acknowledged pages that all still
        // existed when it began. Nothing trapped, which is the point: the gate
        // makes a capture meeting a missing page unreachable rather than
        // something the save path has to tolerate.
        #expect(session.lastSaveError == nil)
    }

    @Test("A page edit that arrives after close mutates nothing")
    func aPageEditAfterCloseIsRefused() async throws {
        let world = try await threePages()
        let doomed = world.pageIDs[1]
        #expect(await world.session.close() == .clean)

        await #expect(throws: PageEditError.sessionNotReady) {
            try await world.session.deletePage(doomed)
        }
        #expect(world.session.pageCount == 3)
    }

    @Test("A page deleted around a layer delete's save does not trap")
    func deletingAPageUnderALayerDeleteIsSurvivable() async throws {
        let scratch = try TestScratch("pages")
        let held = HeldSaveStore(scratch.freshStore())
        let session = EditorSession(store: held, debounce: .milliseconds(10))
        await session.start()
        host(session)
        pullPastTheEnd(session)
        let doomed = session.currentPageID
        let layerID = try await session.importImage(
            Data([0x09]), format: .heic, sourceWidth: 100, sourceHeight: 100, onPage: doomed
        )

        await held.hold()
        let layerDelete = Task { try await session.deleteLayer(layerID, fromPage: doomed) }
        // Far enough for the layer delete to reach the save it awaits.
        try await Task.sleep(for: .milliseconds(30))
        let pageDelete = Task { try await session.deletePage(doomed) }
        await held.release()

        // Which of the two resumes first is not pinned here and does not need
        // to be — **neither order may trap**. `deleteLayer` re-resolves its
        // page after the await; if the page delete won, the page took its
        // layers with it and there is nothing left to reclaim or to tell the
        // runtime, so it returns rather than trapping on a missing page.
        try await layerDelete.value
        try await pageDelete.value
        #expect(session.pageCount == 1)
    }

    // MARK: - Helpers

    /// A three-page document, every page written on, and the scratch that owns
    /// its directory — returned together because the scratch's `deinit` removes
    /// the directory, so a test that dropped it would delete the document it is
    /// asserting about.
    private struct World {
        let scratch: TestScratch
        let session: EditorSession
        let pageIDs: [UUID]
    }

    private func threePages() async throws -> World {
        let scratch = try TestScratch("pages")
        let session = scratch.pageSession()
        await session.start()
        host(session)

        var pageIDs = [session.currentPageID]
        // An import on each, so every page is a real page of the document
        // rather than part of the withheld trailing run.
        try await session.importImage(
            Data([0x01]), format: .heic, sourceWidth: 100, sourceHeight: 100,
            onPage: pageIDs[0]
        )
        for _ in 0..<2 {
            pullPastTheEnd(session)
            let appended = session.currentPageID
            try await session.importImage(
                Data([0x01]), format: .heic, sourceWidth: 100, sourceHeight: 100,
                onPage: appended
            )
            pageIDs.append(appended)
        }
        return World(scratch: scratch, session: session, pageIDs: pageIDs)
    }

    /// Lays the runtime out, which is what builds page canvases and gives the
    /// scroll view a width for the gestures below to work in.
    private func host(_ session: EditorSession) {
        let root = session.pages.view!
        if root.frame.isEmpty {
            root.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        }
        root.layoutIfNeeded()
    }

    /// Drives the append gesture: a deliberate pull past the last page.
    private func pullPastTheEnd(_ session: EditorSession) {
        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(
            x: scroll.bounds.width * (CGFloat(session.pageCount) - 0.5),
            y: 0
        )
        session.pages.scrollViewDidEndDragging(scroll, willDecelerate: false)
        session.pages.view.layoutIfNeeded()
    }

    /// Turns to a page the way a settled scroll does, without a gesture.
    private func turn(_ session: EditorSession, to page: Int) {
        let scroll = session.pages.scrollView
        scroll.contentOffset = CGPoint(x: scroll.bounds.width * CGFloat(page), y: 0)
        session.pages.scrollViewDidEndDecelerating(scroll)
        session.pages.view.layoutIfNeeded()
    }
}

private extension TestScratch {
    @MainActor
    func pageSession(debounce: Duration = .milliseconds(20)) -> EditorSession {
        EditorSession(store: freshStore(), debounce: debounce)
    }
}

/// A store that counts the reclamation calls made through it, so "nothing was
/// asked of disk" is a positive observation rather than an absence.
final class CountingReclaimStore: DocumentStoring {
    private let underlying: DocumentStore
    private let counts = Counts()

    init(_ underlying: DocumentStore) {
        self.underlying = underlying
    }

    var pageDeletes: Int { get async { await counts.pageDeletes } }
    var layerDeletes: Int { get async { await counts.layerDeletes } }
    var assetDeletes: Int { get async { await counts.assetDeletes } }

    func resetCounts() async { await counts.reset() }

    func load() async throws -> DocumentIndex? { try await underlying.load() }

    func loadPage(_ pageID: UUID) async throws -> LoadedPage {
        try await underlying.loadPage(pageID)
    }

    func save(index: DocumentIndex, pages: [PageWrite]) async throws {
        try await underlying.save(index: index, pages: pages)
    }

    func writeAsset(_ bytes: Data, assetID: UUID, format: AssetFormat) async throws {
        try await underlying.writeAsset(bytes, assetID: assetID, format: format)
    }

    func loadAsset(assetID: UUID, format: AssetFormat) async throws -> Data {
        try await underlying.loadAsset(assetID: assetID, format: format)
    }

    @discardableResult
    func deletePageFileIfUnreferenced(pageID: UUID) async throws -> Bool {
        await counts.countPage()
        return try await underlying.deletePageFileIfUnreferenced(pageID: pageID)
    }

    @discardableResult
    func deleteLayerFileIfUnreferenced(layerID: UUID) async throws -> Bool {
        await counts.countLayer()
        return try await underlying.deleteLayerFileIfUnreferenced(layerID: layerID)
    }

    @discardableResult
    func deleteAssetIfUnreferenced(assetID: UUID, format: AssetFormat) async throws -> Bool {
        await counts.countAsset()
        return try await underlying.deleteAssetIfUnreferenced(assetID: assetID, format: format)
    }

    private actor Counts {
        var pageDeletes = 0
        var layerDeletes = 0
        var assetDeletes = 0

        func countPage() { pageDeletes += 1 }
        func countLayer() { layerDeletes += 1 }
        func countAsset() { assetDeletes += 1 }
        func reset() {
            pageDeletes = 0
            layerDeletes = 0
            assetDeletes = 0
        }
    }
}

/// A store that permanently refuses one page's writes, writing every other
/// page — the store's own per-page refusal, which is how a page comes to hold
/// a layer list that exists only in memory while the rest of the document
/// saves normally.
final class RefusingStore: DocumentStoring {
    private let underlying: DocumentStore
    private let refused = Refused()

    init(_ underlying: DocumentStore) {
        self.underlying = underlying
    }

    func refuse(_ pageID: UUID) async { await refused.add(pageID) }

    func save(index: DocumentIndex, pages: [PageWrite]) async throws {
        let doomed = await refused.ids
        let allowed = pages.filter { !doomed.contains($0.pageID) }
        let rejected = pages.filter { doomed.contains($0.pageID) }
        try await underlying.save(index: index, pages: allowed)
        guard !rejected.isEmpty else { return }
        throw PageSaveRefusal(
            refusedPages: rejected.map {
                PageRefusal(pageID: $0.pageID, reason: "refused by the test store")
            },
            indexWritten: true
        )
    }

    func load() async throws -> DocumentIndex? { try await underlying.load() }

    func loadPage(_ pageID: UUID) async throws -> LoadedPage {
        try await underlying.loadPage(pageID)
    }

    func writeAsset(_ bytes: Data, assetID: UUID, format: AssetFormat) async throws {
        try await underlying.writeAsset(bytes, assetID: assetID, format: format)
    }

    func loadAsset(assetID: UUID, format: AssetFormat) async throws -> Data {
        try await underlying.loadAsset(assetID: assetID, format: format)
    }

    @discardableResult
    func deletePageFileIfUnreferenced(pageID: UUID) async throws -> Bool {
        try await underlying.deletePageFileIfUnreferenced(pageID: pageID)
    }

    @discardableResult
    func deleteLayerFileIfUnreferenced(layerID: UUID) async throws -> Bool {
        try await underlying.deleteLayerFileIfUnreferenced(layerID: layerID)
    }

    @discardableResult
    func deleteAssetIfUnreferenced(assetID: UUID, format: AssetFormat) async throws -> Bool {
        try await underlying.deleteAssetIfUnreferenced(assetID: assetID, format: format)
    }

    private actor Refused {
        var ids: Set<UUID> = []
        func add(_ pageID: UUID) { ids.insert(pageID) }
    }
}
