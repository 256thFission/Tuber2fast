import SwiftUI

@main
struct TuberNotesApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(scenario: DevelopmentScenario.current)
        }
    }
}

