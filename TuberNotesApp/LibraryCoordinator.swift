import Foundation
import Observation
import TuberCore
import TuberStore

/// The one owner of "which document is open" (`Docs/Forks/Library/02-proposal.md`
/// §2 — Ownership: `AppRoot`'s row) and of the open/close transitions between
/// the browser and the editor. The browser and the editor are never on screen
/// together, which is what makes "the library never mutates a package that is
/// open" a property of the object graph rather than a discipline.
///
/// Scene-phase events route to whichever lifecycles exist — the open one, and
/// a retained draining one — exactly as `EditorSceneView` routed them to its
/// single lifecycle. With no document open there is nothing to flush: library
/// writes are synchronous with their user action, never debounced.
@MainActor
@Observable
final class LibraryCoordinator {
    /// The open document: its lifecycle (which owns the session), where it
    /// lives in the library, and what to call it.
    struct OpenDocument {
        let lifecycle: EditorLifecycle
        let itemPath: String
        let displayName: String
    }

    /// A session that closed `.dirty` and is retained off-screen while its
    /// own retry machinery drains it (`Docs/Contract.proposed.md` L4:
    /// releasing a dirty session is never an outcome). While one exists,
    /// opening any document is refused — a second session over the drain
    /// would be a second writer racing the first's last save.
    struct DrainingSession {
        let lifecycle: EditorLifecycle
        let displayName: String
        var message: String
    }

    /// The sole writer of the library tree. Owned here so the browser, the
    /// popovers, and the sheets all speak to one store over one root.
    let library: LibraryStore

    /// The browser's one thumbnail cache, owned beside the library it renders
    /// from so it survives open/close transitions of the browser view. The
    /// cache's owner/bound/eviction are stated at its declaration, in
    /// `LibraryThumbnailStore`.
    let thumbnails = LibraryThumbnailStore()

    private(set) var openDocument: OpenDocument?
    private(set) var draining: DrainingSession?

    /// Bumped whenever a transition may have changed the tree underneath the
    /// browser — a close (its saves moved mtimes), a notebook created, a
    /// drain completed. Folder views re-list on it, so the browser always
    /// shows what the store last proved rather than a stale listing.
    private(set) var libraryGeneration = 0

    /// True from Back until `close()` returns — the Back affordance disables
    /// itself so a second tap cannot race the one teardown.
    private(set) var isClosing = false

    init(library: LibraryStore = LibraryStore(rootURL: LibraryStore.defaultRootURL())) {
        self.library = library
    }

    /// Opening is refused while a dirty session drains: the browser's cells
    /// say why through the drain banner, and the guard here is the backstop.
    var canOpenDocuments: Bool { draining == nil && openDocument == nil }

    /// Opens an existing package from the browser. `.openExisting` is the
    /// whole point: a library-enumerated package whose index is gone is a
    /// damaged document and the session refuses it (`03-review.md` B2) —
    /// the create branch survives only on `createAndOpenNotebook`.
    func openDocument(at itemPath: String, named displayName: String) {
        guard canOpenDocuments else {
            CanvasLog.event(.lifecycle, "open of \(itemPath) refused: a session is draining or open")
            return
        }
        let session = EditorSession(
            store: DocumentStore(directoryURL: library.documentURL(forItemAt: itemPath)),
            intent: .openExisting
        )
        openDocument = OpenDocument(
            lifecycle: EditorLifecycle(session: session),
            itemPath: itemPath,
            displayName: displayName
        )
        CanvasLog.event(.lifecycle, "library opened \(itemPath)")
    }

    /// The New Notebook path: the store reserves the directory first, then the
    /// session opens it with `.createIfAbsent` — the one intent that may
    /// create, because this path created the directory and nothing else has
    /// ever named it.
    func createAndOpenNotebook(named name: String, in folderPath: String) async throws {
        guard canOpenDocuments else {
            CanvasLog.event(.lifecycle, "new notebook refused: a session is draining or open")
            return
        }
        let item = try await library.createDocumentDirectory(named: name, in: folderPath)
        libraryGeneration += 1
        let session = EditorSession(
            store: DocumentStore(directoryURL: library.documentURL(forItemAt: item.id)),
            intent: .createIfAbsent
        )
        openDocument = OpenDocument(
            lifecycle: EditorLifecycle(session: session),
            itemPath: item.id,
            displayName: item.name
        )
        CanvasLog.event(.lifecycle, "library created and opened \(item.id)")
    }

    /// Back. On `.clean` the lifecycle is released and the browser returns.
    /// On `.dirty` the browser returns too, but the lifecycle is retained
    /// off-screen and keeps draining — the `save.error` banner surfaces it
    /// and `retryDrain()` is the banner's Retry.
    func closeOpenDocument() async {
        guard let open = openDocument, !isClosing else { return }
        isClosing = true
        let outcome = await open.lifecycle.session.close()
        isClosing = false
        switch outcome {
        case .clean:
            openDocument = nil
        case .dirty(let message):
            draining = DrainingSession(
                lifecycle: open.lifecycle,
                displayName: open.displayName,
                message: message
            )
            openDocument = nil
            CanvasLog.event(.lifecycle, "close left \(open.itemPath) dirty; retained to drain")
        }
        libraryGeneration += 1
    }

    /// A mutation outside the coordinator's own transitions changed the tree
    /// under the browser — a Trash-screen recover or empty landing while the
    /// browser is still on screen. Folder views re-list on the bump, exactly
    /// as they do after a close.
    func noteLibraryMutated() {
        libraryGeneration += 1
    }

    /// The drain banner's Retry: `close()` is idempotent and re-checks
    /// dirtiness, so calling it again is the re-attempt — no timer here,
    /// the session's own backoff machinery owns the schedule.
    func retryDrain() async {
        guard let draining else { return }
        switch await draining.lifecycle.session.close() {
        case .clean:
            self.draining = nil
            libraryGeneration += 1
            CanvasLog.event(.lifecycle, "drained session released clean")
        case .dirty(let message):
            self.draining?.message = message
        }
    }

    // MARK: - Scene phase

    func sceneWillResignActive() {
        openDocument?.lifecycle.sceneWillResignActive()
        draining?.lifecycle.sceneWillResignActive()
    }

    func sceneDidBecomeActive() {
        openDocument?.lifecycle.sceneDidBecomeActive()
        draining?.lifecycle.sceneDidBecomeActive()
    }

    #if DEBUG
    /// Lets a test hand in a session built over its own scratch store, so the
    /// dirty-close/drain machine is testable without hosting a canvas over
    /// the production root.
    func installOpenDocumentForTesting(
        lifecycle: EditorLifecycle,
        itemPath: String,
        displayName: String
    ) {
        openDocument = OpenDocument(
            lifecycle: lifecycle,
            itemPath: itemPath,
            displayName: displayName
        )
    }
    #endif
}
