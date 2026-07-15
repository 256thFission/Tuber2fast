import SwiftUI

struct RootView: View {
    let scenario: DevelopmentScenario
#if DEBUG
    @StateObject private var agentSession = AgentInteractionSession()
#endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
#if DEBUG
                AgentRequestBanner(session: agentSession)
#endif
                SpatialCanvasView(pins: scenario.pins, penFixture: scenario.penFixture)
#if DEBUG
                    .environmentObject(agentSession)
#endif
            }
            .navigationTitle("TuberNotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(scenario.displayName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("scenario-label")
                }
            }
        }
        .onAppear {
            print("TuberNotes scenario=\(scenario.rawValue) pins=\(scenario.pins.count)")
#if DEBUG
            agentSession.reload()
#endif
        }
    }
}
