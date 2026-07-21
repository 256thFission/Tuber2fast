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
    @State private var expandedRootIDs: Set<UUID> = []
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
        // Opaque near-black base beneath the frost so page content never
        // shows through the panel, matching the menu backdrops.
        .background(sidebarShape.fill(Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.92)))
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
            if let selectedParent {
                threadView(for: selectedParent).padding(.top, 16)
            }
            conversationTree.padding(.top, 16)
        }
    }

    // MARK: Thread view

    /// The full conversation thread for the selected node: every exchange from
    /// its root down to the node, rendered chat-style, plus its child branches.
    private func threadView(for annotation: PageAnnotation) -> some View {
        let conversations = activeLayer?.conversations ?? []
        let chain = AgentConversationTreeBuilder.chain(to: annotation, in: conversations)
        let children = conversations.filter { $0.parentThreadID == annotation.threadID }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Thread", systemImage: "text.bubble")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(chain.count) exchange\(chain.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(chain) { message in
                threadMessage(message, isFocused: message.id == annotation.id)
            }

            if !children.isEmpty {
                Text("Branches from here")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(children) { child in
                    Button {
                        selectedParentThreadID = child.threadID
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.indigo)
                            Text(child.teaser)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("thread-branch-\(child.id.uuidString)")
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.indigo.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-thread-view")
    }

    /// One exchange in a thread: the prompt (teaser) as the user's bubble and
    /// the answer (body) as the agent's reply beneath it.
    private func threadMessage(_ annotation: PageAnnotation, isFocused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 24)
                Text(annotation.teaser)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.indigo.opacity(isFocused ? 0.85 : 0.45), in: RoundedRectangle(cornerRadius: 11))
                    .foregroundStyle(.white)
            }
            HStack {
                Text(annotation.body)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(isFocused ? nil : 3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                Spacer(minLength: 24)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(annotation.teaser). \(annotation.body)")
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
        let groups = AgentConversationTreeBuilder.rootGroups(from: activeLayer?.conversations ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Conversations", systemImage: "list.bullet.indent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(groups.count) root\(groups.count == 1 ? "" : "s") · \(treeItems.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ForEach(groups) { group in
                rootGroupView(group)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-conversation-tree")
    }

    /// One conversation root and its branch subtree, collapsible. Roots that
    /// contain the current selection stay expanded so the selected node is
    /// always visible.
    private func rootGroupView(_ group: AgentConversationRootGroup) -> some View {
        let containsSelection = selectedParentThreadID.map { id in
            group.items.contains { $0.annotation.threadID == id }
        } ?? false
        let isExpanded = expandedRootIDs.contains(group.id) || containsSelection
        let branchCount = group.items.count - 1
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    if isExpanded {
                        expandedRootIDs.remove(group.id)
                        // A collapsed root can't keep the selection pinned open;
                        // clear it so the disclosure actually closes.
                        if containsSelection { selectedParentThreadID = nil }
                    } else {
                        expandedRootIDs.insert(group.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.indigo)
                    Text(group.root.teaser)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if branchCount > 0 {
                        Text("\(branchCount)")
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.10), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Conversation root: \(group.root.teaser)")
            .accessibilityValue(isExpanded ? "Expanded, \(branchCount) branches" : "Collapsed, \(branchCount) branches")
            .accessibilityIdentifier("agent-root-\(group.root.id.uuidString)")

            if isExpanded {
                ForEach(group.items) { item in
                    conversationNode(item)
                }
                .transition(.opacity)
            }
        }
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

/// A conversation root and its full subtree in display order (root first).
private struct AgentConversationRootGroup: Identifiable {
    let root: PageAnnotation
    let items: [AgentConversationTreeItem]

    var id: UUID { root.id }
}

private enum AgentConversationTreeBuilder {
    /// Depth-first subtree per root, cycle-safe. Each group's `items` starts
    /// with the root itself, matching the flat `items(from:)` ordering.
    static func rootGroups(from annotations: [PageAnnotation]) -> [AgentConversationRootGroup] {
        let knownThreads = Set(annotations.map(\.threadID))
        let roots = annotations.filter { annotation in
            guard let parent = annotation.parentThreadID else { return true }
            return !knownThreads.contains(parent)
        }
        var visited = Set<UUID>()
        var groups: [AgentConversationRootGroup] = []

        func subtree(_ annotation: PageAnnotation, depth: Int, into items: inout [AgentConversationTreeItem]) {
            guard visited.insert(annotation.id).inserted else { return }
            let children = annotations.filter { $0.parentThreadID == annotation.threadID }
            items.append(AgentConversationTreeItem(
                annotation: annotation,
                depth: depth,
                childCount: children.count
            ))
            for child in children {
                subtree(child, depth: depth + 1, into: &items)
            }
        }

        for root in roots {
            var items: [AgentConversationTreeItem] = []
            subtree(root, depth: 0, into: &items)
            if !items.isEmpty {
                groups.append(AgentConversationRootGroup(root: root, items: items))
            }
        }
        // Orphaned cycles still surface, each as its own group.
        for orphanedCycle in annotations where !visited.contains(orphanedCycle.id) {
            var items: [AgentConversationTreeItem] = []
            subtree(orphanedCycle, depth: 0, into: &items)
            if !items.isEmpty {
                groups.append(AgentConversationRootGroup(root: orphanedCycle, items: items))
            }
        }
        return groups
    }

    /// The ancestor chain from the root down to (and including) `annotation`,
    /// cycle-safe: walking stops if a parent link loops.
    static func chain(to annotation: PageAnnotation, in annotations: [PageAnnotation]) -> [PageAnnotation] {
        var chain: [PageAnnotation] = [annotation]
        var visited: Set<UUID> = [annotation.id]
        var current = annotation
        while let parentThreadID = current.parentThreadID,
              let parent = annotations.first(where: { $0.threadID == parentThreadID }),
              visited.insert(parent.id).inserted {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

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
