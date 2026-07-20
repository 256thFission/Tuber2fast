import SwiftUI

/// Frosted question panel for the active Agentic Layer. Answers are persisted
/// as spatial Pins; this panel only keeps a convenient recent-answer history.
struct AgentSidebarView: View {
    @ObservedObject var vm: NotebookViewModel
    @AppStorage(AgentProviderAccess.credentialStorageKey) private var credential = ""
    @AppStorage(AgentProviderAccess.providerStorageKey) private var providerRaw = AgentProvider.openAI.rawValue
    @AppStorage(AgentProviderAccess.modelStorageKey) private var model = ""
    @State private var prompt = ""
    var onClose: () -> Void
    var onEditProviderAccess: () -> Void

    private var hasSelection: Bool { vm.lassoRect != nil }
    private var provider: AgentProvider { AgentProvider(rawValue: providerRaw) ?? .openAI }
    private var providerAccess: AgentProviderAccess? {
        AgentProviderAccess(provider: provider, credential: credential, model: model)
    }
    private var isProviderConfigured: Bool {
#if DEBUG
        providerAccess != nil
#else
        false
#endif
    }
    private var sidebarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))
            ScrollView { content.padding(16) }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial, in: sidebarShape)
        .overlay(
            sidebarShape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.12)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.4), radius: 26, x: -8, y: 0)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("assistant-sidebar")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Ask Agentic Layer", systemImage: "sparkles").font(.headline)
                if let layer = vm.notebook.agenticLayers.first(where: { $0.id == vm.selectedLayerID }) {
                    Text(layer.name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { onEditProviderAccess() } label: { Image(systemName: "key") }
                .accessibilityLabel("Agent provider settings")
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
            vm.analyzeCurrentPage(
                providerAccess: providerAccess,
                question: prompt.isEmpty ? nil : prompt
            )
        } label: {
            Label(analyzeTitle, systemImage: hasSelection ? "lasso" : "eye")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.isAnalyzing)
        .padding(.top, 4)

        if !isProviderConfigured {
            Button { onEditProviderAccess() } label: {
                Text("Demo mode — tap to configure an agent provider")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 4)
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
                Button("Clear panel history", role: .destructive) { vm.clearObservations() }
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
            Text("Select a region with the **lasso** before opening this Agentic Layer, or ask about the whole page. The answer becomes a Pin on this layer.")
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

/// Centered frosted popup for local Debug provider access. Rendered over the
/// whole editor so it sits in the middle of the screen.
struct AgentProviderAccessPopup: View {
    @AppStorage(AgentProviderAccess.credentialStorageKey) private var credential = ""
    @AppStorage(AgentProviderAccess.providerStorageKey) private var storedProviderRaw = AgentProvider.openAI.rawValue
    @AppStorage(AgentProviderAccess.modelStorageKey) private var storedModel = ""
    @State private var draftCredential = ""
    @State private var draftProviderRaw = AgentProvider.openAI.rawValue
    @State private var draftModel = ""
    var onClose: () -> Void

    private var trimmedDraftCredential: String {
        draftCredential.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var provider: AgentProvider { AgentProvider(rawValue: draftProviderRaw) ?? .openAI }
    private var modelLabel: String {
        let trimmedModel = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedModel.isEmpty ? "Default (\(provider.defaultModel))" : trimmedModel
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("Agent provider", systemImage: "key.fill").font(.headline)
                        Spacer()
                        Button { onClose() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }

#if DEBUG
                    Picker("Provider", selection: $draftProviderRaw) {
                        ForEach(AgentProvider.allCases) { provider in
                            Text(provider.label).tag(provider.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draftProviderRaw) { _, _ in
                        // Never carry one provider's credential across to another endpoint.
                        draftCredential = ""
                        draftModel = ""
                    }

                    Text(provider == .rightCode
                         ? "Paste locally supplied right.codes access for notebook analysis and Pin conversations."
                         : "Paste locally supplied OpenAI access for notebook analysis and Pin conversations.")
                        .font(.footnote).foregroundStyle(.secondary)

                    SecureField(provider == .rightCode ? "right.codes access…" : "sk-…", text: $draftCredential)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14)))

                    HStack {
                        Text("Model").font(.subheadline)
                        Spacer()
                        Menu {
                            Button("Default (\(provider.defaultModel))") { draftModel = "" }
                            Divider()
                            ForEach(provider.knownModels, id: \.self) { knownModel in
                                Button(knownModel) { draftModel = knownModel }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(modelLabel).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.caption2)
                            }
                            .frame(maxWidth: 240, alignment: .trailing)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.14)))
                        }
                        .accessibilityIdentifier("agent-model-picker")
                    }

                    Text("Refine with AI continues to use the separate TuberNotes image-refinement service.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack {
                        if !credential.isEmpty {
                            Button("Remove access", role: .destructive) {
                                credential = ""; draftCredential = ""; onClose()
                            }
                        }
                        Spacer()
                        Button("Cancel") { onClose() }
                            .keyboardShortcut(.cancelAction)
                        Button("Save") {
                            storedProviderRaw = draftProviderRaw
                            storedModel = draftModel
                            credential = trimmedDraftCredential
                            onClose()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedDraftCredential.isEmpty)
                    }
#else
                    Text("Live provider access is available only in local Debug builds. This build stays in credential-free demo mode until a distributable TuberNotes gateway is configured.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button("Done", action: onClose)
                            .buttonStyle(.borderedProminent)
                    }
#endif
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 440, maxHeight: 620)
            .frostedGlass(cornerRadius: 26)
            .padding(40)
            .environment(\.colorScheme, .dark)
        }
        .onAppear {
            draftCredential = credential
            draftProviderRaw = storedProviderRaw
            draftModel = storedModel
        }
        .accessibilityIdentifier("agent-provider-popup")
    }
}
