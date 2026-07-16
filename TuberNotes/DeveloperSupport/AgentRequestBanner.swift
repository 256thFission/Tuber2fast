import SwiftUI

#if DEBUG
struct AgentRequestBanner: View {
    @ObservedObject var session: AgentInteractionSession
    @State private var isCollapsed = false
    @State private var settledOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        if let request = session.activeRequest, request.kind == .penFixture {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(session.bannerTitle, systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(request.status.rawValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button {
                        withAnimation(.snappy) { isCollapsed.toggle() }
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCollapsed ? "Expand review request" : "Collapse review request")
                }

                if !isCollapsed {
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
            }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(borderColor(for: request.status), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .offset(
                x: settledOffset.width + dragOffset.width,
                y: settledOffset.height + dragOffset.height
            )
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        settledOffset.width += value.translation.width
                        settledOffset.height += value.translation.height
                    }
            )
            .accessibilityIdentifier("agent-request-banner")
            .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
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
