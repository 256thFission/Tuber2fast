import SwiftUI

#if DEBUG
struct AgentRequestBanner: View {
    @ObservedObject var session: AgentInteractionSession

    var body: some View {
        if let request = session.activeRequest {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(session.bannerTitle, systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(request.status.rawValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Text(session.bannerPrompt)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let statusMessage = session.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if request.status == .awaitingHuman {
                    TextField("Optional note for the agent", text: $session.draftNotes)
                        .textFieldStyle(.roundedBorder)
                }

                if request.kind == .review {
                    HStack(spacing: 8) {
                        verdictButton("Looks good", verdict: .looksGood)
                        verdictButton("Needs work", verdict: .needsWork)
                        verdictButton("Blocked", verdict: .blocked)
                    }
                }

                if request.kind == .penFixture && session.hasPendingPenCapture {
                    HStack(spacing: 8) {
                        Button("Use Capture") { session.confirmPenCapture() }
                            .buttonStyle(.borderedProminent)
                        Button("Reset") { session.resetScenario() }
                            .buttonStyle(.bordered)
                    }
                } else if request.status == .awaitingHuman {
                    Button("Reset Scenario") { session.resetScenario() }
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.semibold))
                }

                if request.status != .awaitingHuman {
                    Button("Dismiss") { session.dismissCompleted() }
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(borderColor(for: request.status), lineWidth: 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .accessibilityIdentifier("agent-request-banner")
        }
    }

    private func verdictButton(_ title: String, verdict: AgentInteractionRequest.Verdict) -> some View {
        Button(title) { session.submitVerdict(verdict) }
            .buttonStyle(.bordered)
            .font(.caption.weight(.semibold))
    }

    private func borderColor(for status: AgentInteractionRequest.Status) -> Color {
        switch status {
        case .awaitingHuman: .orange.opacity(0.7)
        case .recorded, .answered: .green.opacity(0.7)
        case .cancelled: .secondary.opacity(0.4)
        }
    }
}
#endif
