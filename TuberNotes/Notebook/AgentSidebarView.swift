import SwiftUI

/// Frosted question panel for the active Agentic Layer. Its hierarchy is derived
/// directly from persisted spatial Pins, so the tree and page never diverge.
struct AgentSidebarView: View {
    @ObservedObject var vm: NotebookViewModel
    @Binding var selectedParentThreadID: UUID?
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
    private var activeLayer: ConversationLayer? {
        guard vm.isAgenticLayersActive else { return nil }
        return vm.notebook.agenticLayers.first {
            $0.id == vm.selectedLayerID && $0.isVisible
        }
    }
    private var treeItems: [AgentConversationTreeItem] {
        AgentConversationTreeBuilder.items(from: activeLayer?.conversations ?? [])
    }
    private var selectedParent: PageAnnotation? {
        guard let selectedParentThreadID else { return nil }
        return activeLayer?.conversations.first { $0.threadID == selectedParentThreadID }
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
        .onAppear { validateSelectedParent() }
        .onChange(of: vm.selectedLayerID) { _, _ in validateSelectedParent() }
        .onChange(of: vm.newestAgentThreadID) { _, threadID in
            guard let threadID,
                  activeLayer?.conversations.contains(where: { $0.threadID == threadID }) == true
            else { return }
            selectedParentThreadID = threadID
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Agentic Layer", systemImage: "sparkles").font(.headline)
                if let layer = vm.notebook.agenticLayers.first(where: { $0.id == vm.selectedLayerID }) {
                    Text("\(layer.name) · Active").font(.caption).foregroundStyle(.secondary)
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
        continuationContextChip

        TextField(
            selectedParent == nil ? "Ask about this page…" : "Ask a follow-up…",
            text: $prompt,
            axis: .vertical
        )
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))

        Button {
            vm.analyzeCurrentPage(
                providerAccess: providerAccess,
                question: prompt.isEmpty ? nil : prompt,
                parentThreadID: selectedParentThreadID
            )
        } label: {
            Label(analyzeTitle, systemImage: hasSelection ? "lasso" : "eye")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.isAnalyzing)
        .padding(.top, 4)

        Button { onEditProviderAccess() } label: {
            Text(providerAccessLabel)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .accessibilityLabel("Agent provider access")
        .accessibilityValue(providerAccessValue)
        .accessibilityHint(isProviderConfigured ? "Change provider or model" : "Configure a provider for live analysis")
        .accessibilityIdentifier("assistant-provider-access")

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

        if treeItems.isEmpty && !vm.isAnalyzing {
            emptyState.padding(.top, 20)
        } else {
            conversationTree.padding(.top, 16)
        }
    }

    private var analyzeTitle: String {
        if vm.isAnalyzing { return "Analyzing…" }
        if selectedParent != nil { return "Continue conversation" }
        return hasSelection ? "Analyze selection" : "Analyze page"
    }

    private var providerAccessLabel: String {
#if DEBUG
        guard providerAccess != nil else {
            return "Demo mode — tap to configure an agent provider"
        }
        return "\(providerAccessValue) — tap to change"
#else
        return "Demo mode — live provider access is unavailable in this build"
#endif
    }

    private var providerAccessValue: String {
#if DEBUG
        guard let providerAccess else { return "Demo mode" }
        return "\(providerAccess.provider.label) · \(providerAccess.model)"
#else
        return "Demo mode"
#endif
    }

    @ViewBuilder
    private var continuationContextChip: some View {
        if let selectedParent {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Continuing from")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(selectedParent.teaser)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    selectedParentThreadID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Start a new conversation root")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.indigo.opacity(0.20), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.indigo.opacity(0.45)))
            .padding(.bottom, 8)
        }
    }

    private var conversationTree: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Conversation history", systemImage: "list.bullet.indent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(treeItems.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ForEach(treeItems) { item in
                conversationNode(item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-conversation-tree")
    }

    private func conversationNode(_ item: AgentConversationTreeItem) -> some View {
        let selected = item.annotation.threadID == selectedParentThreadID
        let pageNumber = vm.notebook.pages.firstIndex { $0.id == item.annotation.pageID }.map { $0 + 1 }
        let pageAccessibilityValue = pageNumber.map { "Page \($0), " } ?? ""
        return Button {
            if let pageIndex = vm.notebook.pages.firstIndex(where: { $0.id == item.annotation.pageID }) {
                vm.go(to: pageIndex)
            }
            selectedParentThreadID = item.annotation.threadID
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if item.depth > 0 {
                    Rectangle()
                        .fill(Color.indigo.opacity(0.45))
                        .frame(width: 2)
                }
                Image(systemName: item.childCount == 0 ? "bubble.left" : "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? Color.white : Color.indigo)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.annotation.teaser)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text(item.annotation.body)
                        .font(.caption2)
                        .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                        .lineLimit(selected ? 3 : 1)
                    HStack(spacing: 5) {
                        if let pageNumber { Text("Page \(pageNumber)") }
                        if item.childCount > 0 {
                            Text("·")
                            Text("\(item.childCount) repl\(item.childCount == 1 ? "y" : "ies")")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.white.opacity(0.72) : Color.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
            }
            .padding(9)
            .background(selected ? Color.indigo : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(min(item.depth, 5)) * 14)
        .accessibilityLabel(item.annotation.teaser)
        .accessibilityValue("\(pageAccessibilityValue)depth \(item.depth), \(item.childCount) replies")
        .accessibilityHint("Continues this conversation from this response")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("agent-conversation-node-\(item.annotation.id.uuidString)")
    }

    private func validateSelectedParent() {
        guard let selectedParentThreadID else { return }
        if activeLayer?.conversations.contains(where: { $0.threadID == selectedParentThreadID }) != true {
            self.selectedParentThreadID = nil
        }
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
            Text("Ask about the page to start a conversation. Then select any Pin here—or use Continue on the page—to follow up from that response.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct AgentConversationTreeItem: Identifiable {
    let annotation: PageAnnotation
    let depth: Int
    let childCount: Int

    var id: UUID { annotation.id }
}

private enum AgentConversationTreeBuilder {
    static func items(from annotations: [PageAnnotation]) -> [AgentConversationTreeItem] {
        let knownThreads = Set(annotations.map(\.threadID))
        let roots = annotations.filter { annotation in
            guard let parent = annotation.parentThreadID else { return true }
            return !knownThreads.contains(parent)
        }
        var visited = Set<UUID>()
        var result: [AgentConversationTreeItem] = []

        func append(_ annotation: PageAnnotation, depth: Int) {
            guard visited.insert(annotation.id).inserted else { return }
            let children = annotations.filter { $0.parentThreadID == annotation.threadID }
            result.append(AgentConversationTreeItem(
                annotation: annotation,
                depth: depth,
                childCount: children.count
            ))
            for child in children {
                append(child, depth: depth + 1)
            }
        }

        for root in roots { append(root, depth: 0) }
        for orphanedCycle in annotations where !visited.contains(orphanedCycle.id) {
            append(orphanedCycle, depth: 0)
        }
        return result
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
                    .accessibilityIdentifier("agent-provider-picker")
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
                        .accessibilityLabel("\(provider.label) access credential")
                        .accessibilityHint("Stored locally for notebook analysis and Pin conversations")
                        .accessibilityIdentifier("agent-provider-credential")

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
                        .accessibilityLabel("Model")
                        .accessibilityValue(modelLabel)
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
                            .accessibilityIdentifier("agent-provider-remove")
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
                        .accessibilityIdentifier("agent-provider-save")
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
