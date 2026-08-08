import Observation
import TuberStore
import UIKit

/// Scene-lifecycle glue for the spike.
///
/// The editor remains the owner of save state. This object only obtains the
/// UIKit execution lease early, coalesces repeated inactive/background
/// notifications, and releases the lease when the flush resolves or expires.
@MainActor
@Observable
final class EditorLifecycle {
    let session: EditorSession

    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    /// Increments per departure. A flush ends the lease only if it is still
    /// the latest one, so an earlier flush finishing cannot hand the lease
    /// back underneath a later departure's flush that is still writing.
    @ObservationIgnored private var flushGeneration = 0

    init(session: EditorSession) {
        self.session = session
    }

    static func makeDefault() -> EditorLifecycle {
        EditorLifecycle(
            session: EditorSession(
                store: DocumentStore(directoryURL: DocumentStore.defaultDirectoryURL())
            )
        )
    }

    /// Called on `.inactive`, before suspension is imminent. UIKit recommends
    /// acquiring the assertion before entering the background rather than
    /// waiting until the application is already there.
    ///
    /// Every departure gets a flush, chained after any still running. The old
    /// `flushTask == nil` guard coalesced the repeated inactive/background
    /// notifications of one departure, but it also skipped the flush for a
    /// genuinely later departure that arrived while the first was still
    /// writing — ink drawn between the two was left to no one. A duplicate
    /// notification now costs one extra pass that finds nothing dirty and
    /// returns, which is the cheap direction to be wrong in.
    func sceneWillResignActive() {
        beginBackgroundTaskIfNeeded()

        flushGeneration += 1
        let generation = flushGeneration
        let previous = flushTask
        flushTask = Task { [weak self] in
            guard let self else { return }
            await previous?.value
            await session.flushForBackground()
            // Only the latest flush resolves the lease (`Contract.md` —
            // Lifecycle: held until no write is outstanding).
            if generation == flushGeneration {
                flushTask = nil
                endBackgroundTask()
            }
        }
    }

    func sceneDidBecomeActive() {
        session.resumeForForeground()
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Persist active canvas"
        ) { [weak self] in
            // Expiration ends only the UIKit lease. The save task remains
            // registered until it actually resolves, preventing a second scene
            // notification from launching a duplicate flush.
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
