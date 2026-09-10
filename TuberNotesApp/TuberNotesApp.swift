import SwiftUI

/// One window. The workspace is the app's single durable owner: the library,
/// the open tabs, and the background-execution lease.
@main
struct TuberNotesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspace = Workspace()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(workspace)
                .onChange(of: scenePhase) { _, phase in
                    workspace.scenePhaseChanged(phase)
                }
        }
    }
}
