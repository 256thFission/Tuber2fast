import SwiftUI

@main
struct TuberNotesApp: App {
    @StateObject private var notebookStore = NotebookStore.shared
    @AppStorage("tuber.appearance") private var appearanceRaw = AppAppearance.system.rawValue

    init() {
        #if DEBUG
        FeedbackThreadStore.resetIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            rootContent
                .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        }
    }

    @ViewBuilder
    private var rootContent: some View {
#if DEBUG
        // Preserve the agent testing harness: when launched with a scenario /
        // fixture env var or `--scenario`, keep showing the existing RootView.
        if DevelopmentScenario.isAgentHarnessActive {
            RootView(scenario: DevelopmentScenario.current)
        } else {
            LibraryView(store: notebookStore)
        }
#else
        LibraryView(store: notebookStore)
#endif
    }
}

#if DEBUG
extension DevelopmentScenario {
    /// True when the app was launched by the agent testing harness.
    static var isAgentHarnessActive: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["TUBER_SCENARIO"] != nil { return true }
        if env["TUBER_RECORD_PEN_FIXTURE"] != nil { return true }
        if env["TUBER_PEN_FIXTURE"] != nil { return true }
        if ProcessInfo.processInfo.arguments.contains("--scenario") { return true }
        return false
    }
}
#endif
