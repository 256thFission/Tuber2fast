import SwiftUI
import TuberCore

@main
struct TuberNotesApp: App {
    init() {
        CanvasLog.installCrashDiagnostics()
        CanvasLog.event(.lifecycle, "app launched")
    }

    var body: some Scene {
        WindowGroup {
            EditorSceneView()
        }
    }
}

/// Owns the editor lifecycle at the scene boundary rather than in the `App`
/// value. The spike is explicitly single-scene in `project.yml` because its
/// fixed document has no same-document commit coordinator; the despiking design
/// removes that temporary restriction.
private struct EditorSceneView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var lifecycle = EditorLifecycle.makeDefault()

    var body: some View {
        RootCanvasView(session: lifecycle.session)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background, .inactive:
                    lifecycle.sceneWillResignActive()
                case .active:
                    lifecycle.sceneDidBecomeActive()
                @unknown default:
                    break
                }
            }
    }
}
