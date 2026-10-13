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
/// One `Notebook` per package. The ledger reserves synchronously before the
/// asynchronous open, so two taps arriving before the first open completes
/// resolve to `.alreadyOpen` rather than a second writer. A re-entrant
/// checkout of a path this turn already holds is the programmer error.
@MainActor @Observable
package final class Library {
    @ObservationIgnored package let store: LibraryStore
    @ObservationIgnored private var openNotebooks: [String: Notebook] = [:]
    @ObservationIgnored private var reservations: Set<String> = []
    package private(set) var identities = IdentityIndex()
    package private(set) var openCount = 0

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

    package func isCheckedOut(_ relativePath: String) -> Bool {
        openNotebooks[relativePath] != nil || reservations.contains(relativePath)
    }

    /// True when the path is checked out or is a folder holding one.
    package func isLocked(_ relativePath: String) -> Bool { openPath(under: relativePath) != nil }

    /// The path checked out at `relativePath` or below it, or nil. A
    /// reservation counts: the checkout is promised before the notebook is.
    private func openPath(under relativePath: String) -> String? {
        if isCheckedOut(relativePath) { return relativePath }
        guard !relativePath.isEmpty else { return nil }
        let prefix = relativePath + "/"
        return openNotebooks.keys.first { $0.hasPrefix(prefix) }
            ?? reservations.first { $0.hasPrefix(prefix) }
    }

    package func openNotebook(at relativePath: String) -> Notebook? { openNotebooks[relativePath] }

    package func checkout(_ relativePath: String, schedule: SaveSchedule = SaveSchedule()) async -> CheckoutOutcome {
        if let open = openNotebooks[relativePath] { return .alreadyOpen(open.notebookID) }
        if reservations.contains(relativePath) {
            // A reservation with no notebook yet: the first open is in flight.
            while reservations.contains(relativePath), openNotebooks[relativePath] == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if let open = openNotebooks[relativePath] { return .alreadyOpen(open.notebookID) }
            return .failed(.itemNotFound(relativePath))
        }
        if identities.collisions[relativePath] != nil { return .failed(.identityCollision(relativePath)) }
        reservations.insert(relativePath)
        defer { reservations.remove(relativePath) }
        // Inside the reservation, so no rename, move, trash or duplicate meets
        // the package while it is swapped.
        do { try await store.upgradePackage(at: relativePath) } catch { return .failed(error) }
        let packageStore = PackageStore(root: store.url(of: relativePath), fileSystem: store.fileSystem)
        do {
            let notebook = try await Notebook.open(store: packageStore, schedule: schedule)
            // Tabs are keyed by identity. The index may predate this package,
            // so the ledger is asked too; the refused notebook was only read.
            if openNotebooks.values.contains(where: { $0.notebookID == notebook.notebookID }) {
                return .failed(.identityCollision(relativePath))
            }
            openNotebooks[relativePath] = notebook
            openCount = openNotebooks.count
            return .opened(notebook)
        } catch {
            return .failed(.format(error))
        }
    }

    /// The final pass, then the checkout ends. The outcome says what, if
    /// anything, is unsaved.
    package func release(_ relativePath: String) async -> CloseOutcome? {
        guard let notebook = openNotebooks[relativePath] else { return nil }
        let outcome = await notebook.close()
        openNotebooks[relativePath] = nil
        openCount = openNotebooks.count
        return outcome
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
            throw .notebookIsOpen(name: (open as NSString).lastPathComponent)
        }
    }

    package func rename(at relativePath: String, to newName: String) async throws(LibraryError) -> LibraryItem {
        try requireUnlocked(relativePath)
        return try await store.rename(at: relativePath, to: newName)
    }

    package func move(at relativePath: String, toFolder folder: String) async throws(LibraryError) -> LibraryItem {
        try requireUnlocked(relativePath)
        return try await store.move(at: relativePath, toFolder: folder)
    }

    package func trash(at relativePath: String) async throws(LibraryError) -> TrashEntry {
        try requireUnlocked(relativePath)
        return try await store.trash(at: relativePath)
    }

    package func duplicateNotebook(at relativePath: String) async throws(LibraryError) -> LibraryItem {
        try requireUnlocked(relativePath)
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
        if let notebook = openNotebooks[item.relativePath] {
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
