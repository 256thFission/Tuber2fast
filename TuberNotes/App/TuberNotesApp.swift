import SwiftUI

@main
struct TuberNotesApp: App {
    init() {
        #if DEBUG
        FeedbackThreadStore.resetIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(scenario: DevelopmentScenario.current)
        }
    }
}
