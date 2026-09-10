import Foundation
import Observation
import TNCore
import TNFormat
import TNModel
import TNNotebook

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

    package init(store: LibraryStore) {
        self.store = store
    }

    // MARK: The ledger

    package func isCheckedOut(_ relativePath: String) -> Bool {
        openNotebooks[relativePath] != nil || reservations.contains(relativePath)
    }

    /// True when the path is checked out or is a folder holding one.
    package func isLocked(_ relativePath: String) -> Bool {
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        return isCheckedOut(relativePath)
            || openNotebooks.keys.contains { $0.hasPrefix(prefix) && !prefix.isEmpty }
            || reservations.contains { $0.hasPrefix(prefix) && !prefix.isEmpty }
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
        reservations.insert(relativePath)
        defer { reservations.remove(relativePath) }
        let packageStore = PackageStore(root: store.url(of: relativePath))
        do {
            let notebook = try await Notebook.open(store: packageStore, schedule: schedule)
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

    private func requireUnlocked(_ relativePath: String) throws(LibraryError) {
        if isLocked(relativePath) {
            throw .notebookIsOpen(name: (relativePath as NSString).lastPathComponent)
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
}
