import SwiftUI

/// Toggleable right-hand sidebar. Captures the current page (with whatever you've
/// circled) and asks the assistant to describe what it sees.
struct AgentSidebarView: View {
    @ObservedObject var vm: NotebookViewModel
    @AppStorage("tuber.openaiKey") private var apiKey = ""
    @State private var showKeyField = false
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(16) }
        }
        .frame(width: 330)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
        }
        .accessibilityIdentifier("assistant-sidebar")
    }

    private var header: some View {
        HStack {
            Label("Assistant", systemImage: "sparkles")
                .font(.headline)
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
        Button {
            vm.analyzeCurrentPage(apiKey: apiKey)
        } label: {
            Label(vm.isAnalyzing ? "Analyzing…" : "Analyze this page", systemImage: "eye")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.isAnalyzing)

        if apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Demo mode — add an OpenAI key for real analysis.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }

        if showKeyField {
            VStack(alignment: .leading, spacing: 6) {
                SecureField("OpenAI API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Stored on-device only. For a shipped app, proxy through your own server instead.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.top, 8)
        }

        if vm.observations.isEmpty && !vm.isAnalyzing {
            emptyState.padding(.top, 20)
        } else {
            ForEach(vm.observations) { observation in
                ObservationCard(observation: observation).padding(.top, 12)
            }
            if !vm.observations.isEmpty {
                Button("Clear", role: .destructive) { vm.clearObservations() }
                    .font(.caption)
                    .padding(.top, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "scribble.variable").font(.title2).foregroundStyle(.secondary)
            Text("Circle or draw something on the page, then tap **Analyze this page**. I'll describe what I see.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ObservationCard: View {
    let observation: AgentObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = observation.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1)))
            }
            Text(observation.summary).font(.subheadline)
            if !observation.items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(observation.items, id: \.self) { item in
                        Label(item, systemImage: "circle.fill")
                            .labelStyle(BulletLabelStyle())
                            .font(.caption)
                    }
                }
            }
            Text(observation.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(.secondary).frame(width: 4, height: 4)
            configuration.title
        }
    }
}
