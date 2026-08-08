import Foundation
@testable import TuberModel
@testable import TuberNotes
@testable import TuberStore

/// A real store with one difference: its `save` can be held open.
///
/// This is what the `DocumentStoring` seam is for, and it retires the worst of
/// the `…ForTesting` backdoors. `EditorSession` used to carry a
/// `serializationDelayForTesting` that `performOneSave` *awaited* — a
/// production save path with a test-only suspension point in it, shipped in
/// every configuration. What those tests wanted was never a delay; it was a
/// save that is genuinely in flight while they look at the session. A store
/// that does not return gives them exactly that, from outside the session, and
/// gives it indefinitely: the old form raced the 200 ms it slept against
/// however long the assertions took.
///
/// Everything else forwards untouched, so what is under test is the real
/// store's behaviour — including its failures. A test that wants a save to
/// fail still breaks the directory; this only decides *when* the store is
/// asked.
final class HeldSaveStore: DocumentStoring {
    private let underlying: DocumentStore
    private let gate = Gate()

    init(_ underlying: DocumentStore) {
        self.underlying = underlying
    }

    /// Every `save` from now on waits until `release()`.
    func hold() async {
        await gate.close()
    }

    /// Lets the held save proceed, and every later save go straight through.
    func release() async {
        await gate.open()
    }

    func save(index: DocumentIndex, pages: [PageWrite]) async throws {
        await gate.wait()
        try await underlying.save(index: index, pages: pages)
    }

    func load() async throws -> DocumentIndex? {
        try await underlying.load()
    }

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
    func deleteLayerFileIfUnreferenced(layerID: UUID) async throws -> Bool {
        try await underlying.deleteLayerFileIfUnreferenced(layerID: layerID)
    }

    @discardableResult
    func deleteAssetIfUnreferenced(assetID: UUID, format: AssetFormat) async throws -> Bool {
        try await underlying.deleteAssetIfUnreferenced(assetID: assetID, format: format)
    }

    private actor Gate {
        private var isOpen = true
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func close() { isOpen = false }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
