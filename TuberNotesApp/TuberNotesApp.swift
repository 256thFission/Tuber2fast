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
            AppRoot()
        }
    }
}

/// The scene root: the library browser, or the open document full-screen —
/// never both (`02-proposal.md` §4). It owns the coordinator at the scene
/// boundary, exactly where the old editor-only root owned its lifecycle, and
/// routes scene-phase events to whichever lifecycles exist; with no document
/// open there is nothing to flush.
private struct AppRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = LibraryCoordinator()

    var body: some View {
        Group {
            if let open = coordinator.openDocument {
                EditorContainerView(open: open, coordinator: coordinator)
            } else {
                LibraryBrowserView(coordinator: coordinator)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                coordinator.sceneWillResignActive()
            case .active:
                coordinator.sceneDidBecomeActive()
            @unknown default:
                break
            }
        }
    }
}
