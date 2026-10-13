import Foundation
import Observation
// A cover is a `CGImage`, and `TNLibrary` may not import CoreGraphics:
// PencilKit brings it, as it does for `TNNotebook`'s thumbnails.
import PencilKit
import TNCore
import TNFormat
import TNModel
import TNNotebook
import TNRender

package enum CheckoutOutcome: Sendable {
    case opened(Notebook)
    case alreadyOpen(NotebookID)
    case failed(LibraryError)
}

/// The library on the main actor: the checkout ledger, the identity index,
/// and every mutation gated by the ledger. All I/O is `LibraryStore`'s.
///
/// One `Notebook` per package. A checkout claims its entry before its first
/// await, so a second tap during the open waits on that open's task and
/// reports what it reported rather than making a second writer
/// (`Docs/Contract.md`, Library).
@MainActor @Observable
package final class Library {
    private enum Checkout {
        case opening(Task<CheckoutOutcome, Never>)
        case open(notebook: Notebook)
    }

    @ObservationIgnored package let store: LibraryStore
    @ObservationIgnored private var checkouts: [String: Checkout] = [:]
    /// The paths a rename, a move, a trash or a duplicate is in flight on,
    /// once per mutation, and the checkouts waiting for one to end.
    @ObservationIgnored private var mutating: [String] = []
    @ObservationIgnored private var waitingForMutation: [CheckedContinuation<Void, Never>] = []
    package private(set) var identities = IdentityIndex()

    /// Cache: covers by path and package modification time. Owner: this
    /// object. Bound: `coverCacheBound` bytes, evicting oldest first.
    /// Evictor: `BoundedCache.insert`, on insert, and `purge()` on memory
    /// pressure from the app.
    @ObservationIgnored
    private var covers = BoundedCache<CoverKey, CGImage>(
        bound: Library.coverCacheBound, cost: { $0.bytesPerRow * $0.height }
    )

    package static let coverCacheBound = 32 * 1024 * 1024

    package init(store: LibraryStore) {
        self.store = store
    }

    // MARK: The ledger

    /// Open or still opening.
    package func isCheckedOut(_ relativePath: String) -> Bool { checkouts[relativePath] != nil }

    /// True when the path is checked out or is a folder holding one.
    package func isLocked(_ relativePath: String) -> Bool { openPath(under: relativePath) != nil }

    /// The path checked out at `relativePath` or below it, or nil. A
    /// checkout still opening counts: the path is held from the tap on.
    private func openPath(under relativePath: String) -> String? {
        if isCheckedOut(relativePath) { return relativePath }
        guard !relativePath.isEmpty else { return nil }
        let prefix = relativePath + "/"
        return checkouts.keys.first { $0.hasPrefix(prefix) }
    }

    private func notebook(at relativePath: String) -> Notebook? {
        if case .open(let notebook) = checkouts[relativePath] { notebook } else { nil }
    }

    package func checkout(_ relativePath: String, schedule: SaveSchedule = SaveSchedule()) async -> CheckoutOutcome {
        while mutating.contains(where: { relativePath == $0 || relativePath.hasPrefix($0 + "/") }) {
            await withCheckedContinuation { waitingForMutation.append($0) }
        }
        switch checkouts[relativePath] {
        case .open(let notebook):
            return .alreadyOpen(notebook.notebookID)
        case .opening(let first):
            let outcome = await first.value
            if case .opened(let notebook) = outcome { return .alreadyOpen(notebook.notebookID) }
            return outcome
        case nil:
            let opening = Task { await openPackage(at: relativePath, schedule: schedule) }
            checkouts[relativePath] = .opening(opening)
            return await opening.value
        }
    }

    /// The opening entry's task. The collision refusal writes nothing, so it
    /// comes before the ladder, which writes. The entry settles as the task
    /// ends, in the same turn as the identity check against the open ones.
    private func openPackage(at relativePath: String, schedule: SaveSchedule) async -> CheckoutOutcome {
        var opened: Notebook?
        defer { checkouts[relativePath] = opened.map { .open(notebook: $0) } }
        if identities.collisions[relativePath] != nil { return .failed(.identityCollision(relativePath)) }
        do { try await store.upgradePackage(at: relativePath) } catch { return .failed(error) }
        let packageStore = PackageStore(root: store.url(of: relativePath), fileSystem: store.fileSystem)
        let notebook: Notebook
        do { notebook = try await Notebook.open(store: packageStore, schedule: schedule) } catch { return .failed(.format(error)) }
        // Tabs are keyed by identity. The index may predate this package,
        // so the ledger is asked too; the refused notebook was only read.
        if checkouts.keys.contains(where: { self.notebook(at: $0)?.notebookID == notebook.notebookID }) {
            return .failed(.identityCollision(relativePath))
        }
        opened = notebook
        return .opened(notebook)
    }

    /// The checkout of a closed notebook ends. The close was decided by the
    /// editor's `close`, whose outcome the caller acted on; a notebook still
    /// open here would be dropped with its unsaved pages.
    package func release(_ relativePath: String) {
        guard let notebook = notebook(at: relativePath) else { return }
        TNPrecondition.require(notebook.isClosed, "\(relativePath) was released while still open")
        checkouts[relativePath] = nil
    }

    /// The notebook's saves stop, then its checkout ends; the unsaved pages
    /// are abandoned on purpose.
    package func discard(_ relativePath: String) async {
        guard let notebook = notebook(at: relativePath) else { return }
        await notebook.discard()
        checkouts[relativePath] = nil
    }

    /// Sweeps every open package through its notebook's own store, keeping
    /// what that notebook can still restore: the one production caller of
    /// `compact()` (`Docs/Contract.md`, Lifecycle). One still opening is
    /// passed over, with no notebook yet to say what it can restore. The
    /// keep-set is read as each sweep begins, because the person can be
    /// editing again between one package and the next. A sweep that throws
    /// is logged and left for the next one; nothing the person asked for
    /// failed.
    @discardableResult
    package func compactOpenPackages() async -> [NotebookID: CompactReport] {
        var reports: [NotebookID: CompactReport] = [:]
        for path in Array(checkouts.keys) {
            guard let notebook = notebook(at: path) else { continue }
            do throws(FormatFault) {
                let report = try await notebook.store.compact(now: Date(), keeping: notebook.assetsInUse)
                TNLog.event(.library, "compact \(notebook.notebookID) removed \(report.removed.count) kept \(report.kept)")
                reports[notebook.notebookID] = report
            } catch {
                // An I/O fault's description names the package's path.
                let reason = switch error {
                case .io(let failure): "\(failure.operation.rawValue) \(failure.code)"
                default: error.description
                }
                TNLog.event(.library, "compact \(notebook.notebookID) refused: \(reason)")
            }
        }
        return reports
    }

    // MARK: The identity index

    package func refreshIdentities() async throws(LibraryError) {
        identities = try await store.scanIdentities()
    }

    // MARK: Mutations, gated

    /// Names the open notebook, not the argument: a folder above an open
    /// notebook refuses with that notebook's name, which is the thing the
    /// reader has to close (`Docs/Contract.md`, Library).
    private func requireUnlocked(_ relativePath: String) throws(LibraryError) {
        if let open = openPath(under: relativePath) {
            throw .notebookIsOpen(name: LibraryStore.displayName(ofPath: open))
        }
    }

    /// A mutation holds its path from before its first await until the store
    /// returns, so a checkout of it, or of anything under it, waits rather
    /// than opening a package the mutation is about to move.
    private func beginMutation(at relativePath: String) throws(LibraryError) {
        try requireUnlocked(relativePath)
        mutating.append(relativePath)
    }

    private func endMutation(at relativePath: String) {
        guard let held = mutating.firstIndex(of: relativePath) else {
            TNPrecondition.fail("\(relativePath) ended a mutation it never began")
        }
        mutating.remove(at: held)
        let waiting = waitingForMutation
        waitingForMutation = []
        for checkout in waiting { checkout.resume() }
    }

    package func rename(at relativePath: String, to newName: String) async throws(LibraryError) -> LibraryItem {
        try beginMutation(at: relativePath)
        defer { endMutation(at: relativePath) }
        return try await store.rename(at: relativePath, to: newName)
    }

    package func move(at relativePath: String, toFolder folder: String) async throws(LibraryError) -> LibraryItem {
        try beginMutation(at: relativePath)
        defer { endMutation(at: relativePath) }
        return try await store.move(at: relativePath, toFolder: folder)
    }

    package func trash(at relativePath: String) async throws(LibraryError) -> TrashEntry {
        try beginMutation(at: relativePath)
        defer { endMutation(at: relativePath) }
        return try await store.trash(at: relativePath)
    }

    package func duplicateNotebook(at relativePath: String) async throws(LibraryError) -> LibraryItem {
        try beginMutation(at: relativePath)
        defer { endMutation(at: relativePath) }
        return try await store.duplicateNotebook(at: relativePath)
    }

    // MARK: Covers

    /// A notebook's first page, small. An open notebook answers from custody,
    /// so the browser shows the stroke that has not been saved yet; a closed
    /// one is read by the store and rendered through a `Renderer` over its own
    /// package, so asset paper draws.
    ///
    /// A throwaway renderer per closed cover costs one asset decode, which is
    /// what an open notebook's first render costs. A `Notebook` is a checkout,
    /// and there is one per package, so a cover cannot open one.
    package func cover(of item: LibraryItem) async -> CGImage? {
        guard item.kind == .notebook else { return nil }
        if let notebook = notebook(at: item.relativePath) {
            guard let first = notebook.pageIDs.first else { return nil }
            return await notebook.thumbnail(of: first)
        }
        // The listing already carries the modification time, so a hit costs
        // no read; a miss reads the first page and re-keys on what it found.
        let listedKey = CoverKey(path: item.relativePath, version: CoverSource.version(at: item.modifiedAt))
        if let cached = covers[listedKey] { return cached }
        guard let source = try? await store.coverSource(of: item.relativePath) else { return nil }
        let key = CoverKey(path: item.relativePath, version: source.version)
        if let cached = covers[key] { return cached }
        if Task.isCancelled { return nil }
        guard case .ready(let content) = await Notebook.decode(source.bytes) else { return nil }
        if Task.isCancelled { return nil }
        let renderer = Renderer(assets: PackageStore(root: store.url(of: item.relativePath), fileSystem: store.fileSystem))
        let image = await renderer.thumbnail(
            ThumbnailKey(page: source.pageID, version: source.version),
            geometry: source.geometry, paper: source.paper,
            layers: content.layers, ink: content.ink
        )
        guard let image else { return nil }
        covers.insert(image, for: key)
        return image
    }

    package func purge() {
        covers.removeAll()
    }
}

/// A cover is the picture of one package at one modification time.
package struct CoverKey: Hashable, Sendable {
    package let path: String
    package let version: UInt64
}
