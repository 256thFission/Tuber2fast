import SwiftUI

@main
struct TuberNotesApp: App {
    @Environment(\.scenePhase) private var scenePhase

    /// One session for the life of the app. `@State` keeps it across body
    /// re-evaluations, so the canvas it owns is created exactly once.
    @State private var session = EditorSession(store: DocumentStore(fileURL: documentURL()))

    init() {
        CanvasLog.installCrashDiagnostics()
        CanvasLog.event(CanvasLog.lifecycle, "lifecycle", "app launched")
    }

    var body: some Scene {
        WindowGroup {
            RootCanvasView(session: session)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                Task { await session.flushForBackground() }
            case .active:
                session.resumeForForeground()
            @unknown default:
                break
            }
        }
    }

    /// A failure here means the app cannot address its own container. Falling
    /// back to a temporary file would silently discard the user's work on every
    /// launch, so it fails loudly instead.
    private static func documentURL() -> URL {
        do {
            return try DocumentStore.defaultFileURL()
        } catch {
            fatalError("Application Support is unavailable: \(error)")
        }
    }
}
