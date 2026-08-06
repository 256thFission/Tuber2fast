import Observation
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
    func sceneWillResignActive() {
        beginBackgroundTaskIfNeeded()
        guard flushTask == nil else { return }

        flushTask = Task { [weak self] in
            guard let self else { return }
            await session.flushForBackground()
            finishFlush()
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

    private func finishFlush() {
        flushTask = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
