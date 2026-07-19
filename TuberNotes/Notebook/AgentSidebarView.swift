import SwiftUI

/// Toggleable frosted assistant panel. Analyzes either the whole page or the
/// lassoed region, with an optional prompt ("talk about this molecule").
struct AgentSidebarView: View {
    @ObservedObject var vm: NotebookViewModel
    @AppStorage("tuber.openaiKey") private var apiKey = ""
    @State private var showKeyField = false
    @State private var prompt = ""
    var onClose: () -> Void

    private var hasSelection: Bool { vm.lassoRect != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))
            ScrollView { content.padding(16) }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24, style: .continuous))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 26, x: -8, y: 0)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("assistant-sidebar")
    }

    private var header: some View {
        HStack {
            Label("Assistant", systemImage: "sparkles").font(.headline)
            Spacer()
            Button { showKeyField.toggle() } label: { Image(systemName: "key") }
                .accessibilityLabel("API key")
            Button { onClose() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Close assistant")
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        selectionChip

        TextField("Ask about it… (optional)", text: $prompt, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))

        Button {
            vm.analyzeCurrentPage(apiKey: apiKey, question: prompt.isEmpty ? nil : prompt)
        } label: {
            Label(analyzeTitle, systemImage: hasSelection ? "lasso" : "eye")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.isAnalyzing)
        .padding(.top, 4)

        if apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Demo mode — add an OpenAI key for real analysis.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }

        if showKeyField {
            VStack(alignment: .leading, spacing: 6) {
                SecureField("OpenAI API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Stored on-device only. For a shipped app, proxy through your own server.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }

        if vm.isAnalyzing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking at your page…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 12)
        }

        if let error = vm.agentError {
            Text(error).font(.caption).foregroundStyle(.red).padding(.top, 8)
        }

        if vm.observations.isEmpty && !vm.isAnalyzing {
            emptyState.padding(.top, 20)
        } else {
            ForEach(vm.observations) { observation in
                ObservationCard(observation: observation).padding(.top, 12)
            }
            if !vm.observations.isEmpty {
                Button("Clear results", role: .destructive) { vm.clearObservations() }
                    .font(.caption).padding(.top, 8)
            }
        }
    }

    private var analyzeTitle: String {
        if vm.isAnalyzing { return "Analyzing…" }
        return hasSelection ? "Analyze selection" : "Analyze page"
    }

    @ViewBuilder
    private var selectionChip: some View {
        if hasSelection {
            HStack(spacing: 8) {
                Image(systemName: "lasso").font(.caption)
                Text("Region selected").font(.caption.weight(.medium))
                Spacer()
                Button { vm.clearLasso() } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear selection")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4)))
            .padding(.bottom, 4)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "scribble.variable").font(.title2).foregroundStyle(.secondary)
            Text("Tap the **lasso** tool, loop around something (a molecule, a diagram), then ask about it here. Or analyze the whole page.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct ObservationCard: View {
    let observation: AgentObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = observation.thumbnail {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
            }
            Text(observation.summary).font(.subheadline)
            if !observation.items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(observation.items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(.secondary).frame(width: 4, height: 4)
                            Text(item)
                        }
                        .font(.caption)
                    }
                }
            }
            Text(observation.date, style: .time)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
    }
}
