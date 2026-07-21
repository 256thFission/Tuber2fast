import AuthenticationServices
import SafariServices
import SwiftUI
import UIKit

/// Frosted question panel for the active Agentic Layer. Each spatial Pin owns
/// one conversation; message-level branches never create additional Pins.
struct AgentSidebarView: View {
    @ObservedObject var vm: NotebookViewModel
    @Binding var selectedParentThreadID: UUID?
    @Binding var selectedMessageID: UUID?
    @Binding var forkedFromMessageID: UUID?
#if DEBUG
    @AppStorage(AgentProviderAccess.credentialStorageKey) private var credential = ""
    @AppStorage(AgentProviderAccess.providerStorageKey) private var providerRaw = AgentProvider.openAI.rawValue
#endif
    @AppStorage(AgentProviderAccess.modelStorageKey) private var model = ""
#if DEBUG
    @AppStorage(AgentAccessMethod.storageKey) private var accessMethodRaw = AgentAccessMethod.apiKey.rawValue
#endif
    @ObservedObject private var openAILogin = OpenAICodexLoginSession.shared
    @State private var prompt = ""
    @State private var expandedRootIDs: Set<UUID> = []
    var isFullChatTab = false
    var onClose: () -> Void
    var onOpenFullChat: () -> Void = {}
    var onAgentNavigationRequest: ((AgentNavigationRequest) -> Void)? = nil
    var onEditProviderAccess: () -> Void

    private var hasSelection: Bool { vm.lassoRect != nil }
    private var provider: AgentProvider {
#if DEBUG
        AgentProvider(rawValue: providerRaw) ?? .openAI
#else
        .openAI
#endif
    }
    private var providerAccess: AgentProviderAccess? {
#if DEBUG
        AgentProviderAccess(provider: provider, credential: credential, model: model)
#else
        nil
#endif
    }
    private var isProviderConfigured: Bool {
        if isTemporaryAccessSelected { return isTemporarySessionSignedIn }
#if DEBUG
        return providerAccess != nil
#else
        return false
#endif
    }
    private var isTemporaryAccessSelected: Bool {
#if DEBUG
        provider == .openAI
            && AgentAccessMethod(rawValue: accessMethodRaw) == .chatGPTTemporary
#else
        true
#endif
    }
    private var isTemporarySessionSignedIn: Bool {
        guard case .signedIn = openAILogin.phase else { return false }
        return true
    }
    private var isTemporarySignInRequired: Bool {
        isTemporaryAccessSelected && !isTemporarySessionSignedIn
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
    private var selectedMessagePreview: String? {
        guard let selectedParent else { return nil }
        let messageID = forkedFromMessageID ?? selectedMessageID
            ?? selectedParent.conversationMessages?.last?.id ?? selectedParent.threadID
        if messageID == selectedParent.threadID {
            return previewText(selectedParent.body, limit: 90)
        }
        return selectedParent.conversationMessages?
            .first(where: { $0.id == messageID })
            .map { previewText($0.body, limit: 90) }
    }
    private var sidebarShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

    var body: some View {
        Group {
            if isFullChatTab {
                fullChatBody
            } else {
                sidebarBody
            }
        }
        // Pin Chat is always a narrow, non-modal sidebar. Keeping this width
        // independent of transcript mode prevents conversation from becoming
        // a page-blocking surface.
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
                  let annotation = activeLayer?.conversations.first(where: { $0.threadID == threadID })
            else { return }
            selectedParentThreadID = threadID
        }
        .onChange(of: vm.newestAgentMessageID) { _, messageID in
            guard let messageID else { return }
            selectedMessageID = messageID
            forkedFromMessageID = nil
        }
    }

    private var sidebarBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    selectionChip

                    Button {
                        selectedParentThreadID = nil
                        selectedMessageID = nil
                        forkedFromMessageID = nil
                        onOpenFullChat()
                    } label: {
                        Label("Start a conversation", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canAnalyzeCurrentPage)
                    .accessibilityHint("Opens Pin Chat for the current page")

                    compactAnalysisState

                    if treeItems.isEmpty && !vm.isAnalyzing {
                        emptyState.padding(.top, 8)
                    } else {
                        conversationTree
                    }
                }
                .padding(16)
            }
        }
    }

    private var fullChatBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            fullChatHeader
            Divider().overlay(.white.opacity(0.1))
            fullChatTranscript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PinChatComposer(
                text: $prompt,
                continuationLabel: selectedMessagePreview,
                isForking: forkedFromMessageID != nil,
                isSending: vm.isAnalyzing,
                canSend: vm.canAnalyzeCurrentPage,
                failureMessage: vm.agentError,
                onSend: submitPrompt,
                onCancel: vm.cancelAnalysis,
                onRetry: vm.retryLastAnalysis,
                onCancelFork: { forkedFromMessageID = nil }
            )
        }
    }

    private var fullChatHeader: some View {
        let pageNumber = selectedParent.flatMap { annotation in
            vm.notebook.pages.firstIndex { $0.id == annotation.pageID }.map { $0 + 1 }
        } ?? (vm.currentIndex + 1)
        let branchCount = selectedParent.map { PinMessageThreadBuilder.branchCount(for: $0) } ?? 0
        return VStack(spacing: 0) {
            PinChatContextHeader(
                layerName: activeLayer?.name ?? "Agentic Layer",
                pageLabel: "Page \(pageNumber)",
                pinContext: selectedParent.map { previewText($0.teaser, limit: 100) },
                branchCount: branchCount,
                onClose: onClose
            )
            HStack(spacing: 8) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(OpenAICodexConstants.supportedModels, id: \.self) { choice in
                        Button {
                            model = choice
                        } label: {
                            if choice == selectedModel {
                                Label(choice, systemImage: "checkmark")
                            } else {
                                Text(choice)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(selectedModel)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption.weight(.semibold))
                }
                .disabled(vm.isAnalyzing)
                .accessibilityLabel("Chat model")
                .accessibilityValue(selectedModel)
                .accessibilityIdentifier("sidebar-model-selector")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(.white.opacity(0.035))
        }
    }

    private var selectedModel: String {
        OpenAICodexConstants.supportedModels.contains(model)
            ? model
            : OpenAICodexConstants.defaultModel
    }

    private var fullChatTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let selectedParent {
                        ForEach(PinMessageThreadBuilder.items(for: selectedParent)) { message in
                            PinChatTurnView(
                                userPrompt: message.userPrompt,
                                assistantMarkdown: message.body,
                                isFocused: message.id == selectedMessageID,
                                groundedCitation: message.groundedCitation,
                                onOpenCitation: message.groundedCitation.flatMap(citationHandler)
                            )
                            .id(message.id)
                            .overlay(alignment: .bottomTrailing) {
                                Button {
                                    selectedMessageID = message.id
                                    forkedFromMessageID = message.id
                                } label: {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.caption.weight(.semibold))
                                        .padding(7)
                                }
                                .buttonStyle(.plain)
                                .disabled(vm.isAnalyzing)
                                .accessibilityLabel("Fork from this agent message")
                                .accessibilityHint("Starts a message branch within this Pin")
                                .accessibilityIdentifier("pin-chat-fork-\(message.id.uuidString)")
                            }
                            .padding(.leading, CGFloat(min(message.depth, 6)) * 14)
                        }

                        if let pendingQuestion = vm.pendingAnalysisQuestion,
                           vm.pendingAnalysisParentThreadID == selectedParent.threadID {
                            PinChatPendingTurnView(
                                userPrompt: pendingQuestion,
                                toolStatus: vm.activeToolInvocation?.userVisibleStatus
                            )
                                .id("pending-analysis")
                        }

                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.title2)
                                .foregroundStyle(.indigo)
                            Text("Start a Pin Chat")
                                .font(.headline)
                            Text("Ask about the current page. The response will stay attached to this page as a Pin.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)

                        if let pendingQuestion = vm.pendingAnalysisQuestion,
                           vm.pendingAnalysisParentThreadID == nil {
                            PinChatPendingTurnView(
                                userPrompt: pendingQuestion,
                                toolStatus: vm.activeToolInvocation?.userVisibleStatus
                            )
                                .id("pending-analysis")
                        }
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .onAppear { scrollToFocused(using: proxy) }
            .onChange(of: selectedParentThreadID) { _, _ in scrollToFocused(using: proxy) }
            .onChange(of: selectedMessageID) { _, _ in scrollToFocused(using: proxy) }
            .onChange(of: vm.newestAgentThreadID) { _, _ in scrollToFocused(using: proxy) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label(isFullChatTab ? "Pin Chat" : "Agentic Layer", systemImage: isFullChatTab ? "bubble.left.and.bubble.right.fill" : "sparkles")
                    .font(.headline)
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

    private func citationHandler(
        for citation: GroundedCitation
    ) -> ((GroundedCitation) -> Void)? {
        let request = vm.agentNavigationRequest(for: citation)
        guard Self.canOpenCitation(
            request: request,
            hasNavigationHandler: onAgentNavigationRequest != nil
        ), let onAgentNavigationRequest else { return nil }
        return { tappedCitation in
            // Re-resolve at the user action so a deleted or changed textbook
            // cannot emit a stale route after the chip rendered.
            guard let request = vm.agentNavigationRequest(for: tappedCitation) else { return }
            onAgentNavigationRequest(request)
        }
    }

    static func canOpenCitation(
        request: AgentNavigationRequest?,
        hasNavigationHandler: Bool
    ) -> Bool {
        hasNavigationHandler && request != nil
    }

    @ViewBuilder
    private var compactAnalysisState: some View {
        if vm.isAnalyzing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Assistant is responding…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { vm.cancelAnalysis() }
                    .font(.caption.weight(.semibold))
            }
        } else if let error = vm.agentError {
            VStack(alignment: .leading, spacing: 6) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Open Pin Chat to retry") { onOpenFullChat() }
                    .font(.caption.weight(.semibold))
            }
        }

        if !isProviderConfigured {
            Button { onEditProviderAccess() } label: {
                Text(providerConfigurationPrompt).font(.caption)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Agent provider access")
            .accessibilityValue(providerAccessValue)
            .accessibilityHint("Configure a provider for live analysis")
            .accessibilityIdentifier("assistant-provider-access")
        }
    }

    private func submitPrompt() {
        guard vm.canAnalyzeCurrentPage, !vm.isAnalyzing else { return }
        guard !isTemporarySignInRequired else {
            onEditProviderAccess()
            return
        }
        let submitted = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        let parent = selectedParentThreadID
        let messageID = forkedFromMessageID ?? selectedMessageID
            ?? selectedParent?.conversationMessages?.last?.id ?? selectedParent?.threadID
        vm.analyzeCurrentPage(
            question: submitted,
            parentThreadID: parent,
            parentMessageID: messageID,
            createsFork: forkedFromMessageID != nil
        )
        forkedFromMessageID = nil
        prompt = ""
    }

    private func previewText(_ source: String, limit: Int = 240) -> String {
        MarkdownTextProjection.plainText(from: source, limit: limit)
    }

    private func branchAlternatives(for annotation: PageAnnotation) -> [PageAnnotation] {
        let conversations = activeLayer?.conversations ?? []
        var result: [PageAnnotation] = []
        var seen = Set<UUID>()
        if let parentThreadID = annotation.parentThreadID {
            for sibling in conversations where sibling.parentThreadID == parentThreadID
                && sibling.id != annotation.id
                && seen.insert(sibling.id).inserted {
                result.append(sibling)
            }
        }
        for child in conversations where child.parentThreadID == annotation.threadID
            && seen.insert(child.id).inserted {
            result.append(child)
        }
        return result
    }

    private func branchRow(for annotation: PageAnnotation) -> some View {
        let pageNumber = vm.notebook.pages.firstIndex { $0.id == annotation.pageID }.map { $0 + 1 }
        let descendants = AgentConversationTreeBuilder.descendantCount(
            of: annotation,
            in: activeLayer?.conversations ?? []
        )
        return PinChatBranchRow(
            promptPreview: annotation.userPrompt.map { previewText($0, limit: 100) }
                ?? previewText(annotation.teaser, limit: 100),
            responsePreview: previewText(annotation.body, limit: 180),
            pageLabel: pageNumber.map { "Page \($0)" },
            descendantCount: descendants,
            isSelected: annotation.threadID == selectedParentThreadID,
            onSelect: {
                selectedParentThreadID = annotation.threadID
            }
        )
    }

    private func scrollToFocused(using proxy: ScrollViewProxy) {
        guard let focusedID = selectedMessageID ?? selectedParentThreadID else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(focusedID, anchor: .top)
            }
        }
    }

    private var analyzeTitle: String {
        if vm.isAnalyzing { return "Placing Pins…" }
        if selectedParent != nil { return "Send to full chat" }
        return hasSelection ? "Place guidance Pins" : "Guide this page"
    }

    private var providerConfigurationPrompt: String {
        if isTemporaryAccessSelected {
            return "Sign in required — tap to connect OpenAI for this app run"
        }
        return "Configure an agent provider to place guidance Pins"
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
                    selectedMessageID = nil
                    forkedFromMessageID = nil
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
                    Text(previewText(group.root.teaser, limit: 100))
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
            .accessibilityLabel("Conversation root: \(previewText(group.root.teaser, limit: 160))")
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
            selectedParentThreadID = item.annotation.threadID
            selectedMessageID = item.annotation.conversationMessages?.last?.id ?? item.annotation.threadID
            forkedFromMessageID = nil
            onOpenFullChat()
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
                    Text(item.annotation.userPrompt.map { previewText($0, limit: 120) }
                        ?? previewText(item.annotation.teaser, limit: 120))
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text(previewText(item.annotation.body, limit: 180))
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
        .accessibilityLabel(item.annotation.userPrompt.map { previewText($0, limit: 160) }
            ?? previewText(item.annotation.teaser, limit: 160))
        .accessibilityValue("\(pageAccessibilityValue)depth \(item.depth), \(item.childCount) replies")
        .accessibilityHint("Continues this conversation from this response")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("agent-conversation-node-\(item.annotation.id.uuidString)")
    }

    private func validateSelectedParent() {
        guard let selectedParentThreadID else {
            selectedMessageID = nil
            forkedFromMessageID = nil
            return
        }
        guard let pin = activeLayer?.conversations.first(where: { $0.threadID == selectedParentThreadID }) else {
            self.selectedParentThreadID = nil
            selectedMessageID = nil
            forkedFromMessageID = nil
            return
        }
        let messageIDs = Set((pin.conversationMessages ?? []).map(\.id)).union([pin.threadID])
        if selectedMessageID.map(messageIDs.contains) != true {
            selectedMessageID = pin.conversationMessages?.last?.id ?? pin.threadID
        }
        if forkedFromMessageID.map(messageIDs.contains) == false {
            forkedFromMessageID = nil
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

private struct PinMessageThreadItem: Identifiable {
    let id: UUID
    let userPrompt: String?
    let body: String
    let depth: Int
    let groundedCitation: GroundedCitation?
}

private enum PinMessageThreadBuilder {
    static func items(for pin: PageAnnotation) -> [PinMessageThreadItem] {
        let messages = pin.conversationMessages ?? []
        var visited = Set<UUID>()
        var result: [PinMessageThreadItem] = []

        func appendMessage(_ message: PinConversationMessage, depth: Int) {
            guard visited.insert(message.id).inserted else { return }
            result.append(PinMessageThreadItem(
                id: message.id,
                userPrompt: message.userPrompt,
                body: message.body,
                depth: depth,
                groundedCitation: message.groundedCitation
            ))
            for child in messages where child.parentMessageID == message.id {
                appendMessage(child, depth: depth + 1)
            }
        }

        visited.insert(pin.threadID)
        result.append(PinMessageThreadItem(
            id: pin.threadID,
            userPrompt: pin.userPrompt,
            body: pin.body,
            depth: 0,
            groundedCitation: pin.groundedCitation
        ))
        for child in messages where child.parentMessageID == pin.threadID {
            appendMessage(child, depth: 1)
        }
        for orphan in messages where !visited.contains(orphan.id) {
            appendMessage(orphan, depth: 0)
        }
        return result
    }

    static func branchCount(for pin: PageAnnotation) -> Int {
        let messages = pin.conversationMessages ?? []
        let counts = Dictionary(grouping: messages, by: \.parentMessageID).mapValues(\.count)
        return counts.values.reduce(0) { $0 + max(0, $1 - 1) }
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

    static func descendantCount(of annotation: PageAnnotation, in annotations: [PageAnnotation]) -> Int {
        var count = 0
        var pending = annotations.filter { $0.parentThreadID == annotation.threadID }
        var visited: Set<UUID> = [annotation.id]
        while let next = pending.popLast() {
            guard visited.insert(next.id).inserted else { continue }
            count += 1
            pending.append(contentsOf: annotations.filter { $0.parentThreadID == next.threadID })
        }
        return count
    }
}

/// Centered frosted popup for provider access. Rendered over the whole editor
/// so it sits in the middle of the screen.
struct AgentProviderAccessPopup: View {
#if DEBUG
    @AppStorage(AgentProviderAccess.credentialStorageKey) private var credential = ""
#endif
    @AppStorage(AgentProviderAccess.providerStorageKey) private var storedProviderRaw = AgentProvider.openAI.rawValue
    @AppStorage(AgentProviderAccess.modelStorageKey) private var storedModel = ""
    @AppStorage(AgentAccessMethod.storageKey) private var storedAccessMethodRaw = AgentAccessMethod.apiKey.rawValue
    @ObservedObject private var openAILogin = OpenAICodexLoginSession.shared
#if DEBUG
    @State private var draftCredential = ""
    @State private var draftProviderRaw = AgentProvider.openAI.rawValue
#endif
    @State private var draftModel = ""
    @State private var embeddedBrowser: OpenAIEmbeddedBrowserItem?
    @StateObject private var ephemeralAuthentication = OpenAIEphemeralAuthenticationPresenter()
    @State private var shouldPresentFreshSignIn = false
#if DEBUG
    @State private var draftAccessMethodRaw = AgentAccessMethod.apiKey.rawValue
#endif
    var onClose: () -> Void

#if DEBUG
    private var trimmedDraftCredential: String {
        draftCredential.trimmingCharacters(in: .whitespacesAndNewlines)
    }
#endif
    private var provider: AgentProvider {
#if DEBUG
        AgentProvider(rawValue: draftProviderRaw) ?? .openAI
#else
        .openAI
#endif
    }
    private var modelLabel: String {
        let trimmedModel = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedModel.isEmpty ? "Default (\(routeDefaultModel))" : trimmedModel
    }
    private var accessMethod: AgentAccessMethod {
#if DEBUG
        AgentAccessMethod(rawValue: draftAccessMethodRaw) ?? .apiKey
#else
        .chatGPTTemporary
#endif
    }

    private var routeDefaultModel: String {
        if provider == .openAI, accessMethod == .chatGPTTemporary {
            return OpenAICodexConstants.defaultModel
        }
        return provider.defaultModel
    }

    private var routeModels: [String] {
        if provider == .openAI, accessMethod == .chatGPTTemporary {
            return OpenAICodexConstants.supportedModels
        }
        return provider.knownModels
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

                    if provider == .openAI {
                        Picker("OpenAI access", selection: $draftAccessMethodRaw) {
                            Text("ChatGPT sign-in").tag(AgentAccessMethod.chatGPTTemporary.rawValue)
                            Text("API key").tag(AgentAccessMethod.apiKey.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: draftAccessMethodRaw) { _, _ in
                            // Models are route-specific. The saved API key remains intact.
                            draftModel = ""
                        }
                        .accessibilityIdentifier("openai-access-method-picker")
                    }
#endif

#if DEBUG
                    if provider == .openAI, accessMethod == .chatGPTTemporary {
                        temporaryOpenAIAccess
                    } else {
                        Text(provider == .rightCode
                             ? "Paste locally supplied right.codes access for notebook analysis and Pin conversations."
                             : "Paste a locally supplied OpenAI API key for notebook analysis and Pin conversations.")
                            .font(.footnote).foregroundStyle(.secondary)

                        SecureField(provider == .rightCode ? "right.codes access…" : "sk-…", text: $draftCredential)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14)))
                            .accessibilityLabel("\(provider.label) access credential")
                            .accessibilityHint("Stored locally for notebook analysis and Pin conversations")
                            .accessibilityIdentifier("agent-provider-credential")
                    }
#else
                    temporaryOpenAIAccess
#endif

                    HStack {
                        Text("Model").font(.subheadline)
                        Spacer()
                        Menu {
                            Button("Default (\(routeDefaultModel))") { draftModel = "" }
                            Divider()
                            ForEach(routeModels, id: \.self) { knownModel in
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

                    Text("This temporary OpenAI sign-in analyzes a lasso and places guidance Pins on the original page.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack {
#if DEBUG
                        if (provider == .rightCode || accessMethod == .apiKey), !credential.isEmpty {
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
                            if provider == .rightCode || accessMethod == .apiKey {
                                credential = trimmedDraftCredential
                            }
                            if provider == .openAI {
                                storedAccessMethodRaw = draftAccessMethodRaw
                            }
                            onClose()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            (provider == .rightCode || accessMethod == .apiKey)
                            && trimmedDraftCredential.isEmpty
                        )
                        .accessibilityIdentifier("agent-provider-save")
#else
                        Spacer()
                        Button("Cancel") { onClose() }
                            .keyboardShortcut(.cancelAction)
                        Button("Save") {
                            storedProviderRaw = AgentProvider.openAI.rawValue
                            storedAccessMethodRaw = AgentAccessMethod.chatGPTTemporary.rawValue
                            storedModel = draftModel
                            onClose()
                        }
                            .buttonStyle(.borderedProminent)
#endif
                    }
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
#if DEBUG
            draftCredential = credential
            draftProviderRaw = storedProviderRaw
            draftAccessMethodRaw = storedAccessMethodRaw
#endif
            draftModel = storedModel
            if provider == .openAI,
               accessMethod == .chatGPTTemporary,
               !draftModel.isEmpty,
               !OpenAICodexConstants.supportedModels.contains(draftModel) {
                draftModel = ""
            }
        }
        .onChange(of: openAILogin.phase) { _, phase in
            switch phase {
            case .exchanging, .refreshing, .signedIn, .failed, .signedOut:
                shouldPresentFreshSignIn = false
                embeddedBrowser = nil
                ephemeralAuthentication.cancel()
            case let .awaitingUser(code, verificationURL),
                 let .polling(code, verificationURL):
                if shouldPresentFreshSignIn {
                    presentFreshSignIn(code: code, verificationURL: verificationURL)
                }
            case .requestingCode:
                break
            }
        }
        .sheet(item: $embeddedBrowser) { item in
            OpenAIEmbeddedSignInSheet(item: item) {
                embeddedBrowser = nil
            }
        }
        .onDisappear {
            shouldPresentFreshSignIn = false
            ephemeralAuthentication.cancel()
        }
        .accessibilityIdentifier("agent-provider-popup")
    }

    @ViewBuilder
    private var temporaryOpenAIAccess: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Temporary OpenAI sign-in")
                .font(.subheadline.weight(.semibold))
            Text("Authorize once to use ChatGPT-backed OpenAI access. TuberNotes keeps reusable session access in this iPad's Keychain and refreshes short-lived access automatically; sign-in returns only if OpenAI rejects the refresh. Saved API keys are never used for this access method.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            switch openAILogin.phase {
            case .signedOut:
                Button("Sign in with OpenAI") {
                    startFreshSignIn()
                }
                .buttonStyle(.borderedProminent)

            case .requestingCode:
                loginProgress("Preparing sign-in…")
                Button("Cancel sign-in") {
                    openAILogin.cancel()
                }

            case let .awaitingUser(code, verificationURL):
                deviceAuthorization(code: code, verificationURL: verificationURL, isChecking: false)

            case let .polling(code, verificationURL):
                deviceAuthorization(code: code, verificationURL: verificationURL, isChecking: true)

            case .exchanging:
                loginProgress("Finishing sign-in…")
                Button("Cancel sign-in") {
                    openAILogin.cancel()
                }

            case .refreshing:
                loginProgress("Refreshing OpenAI session…")

            case .signedIn:
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text("Sign out clears TuberNotes' in-memory access and its saved Keychain refresh credential. It does not revoke the browser-authorized grant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Sign out", role: .destructive) {
                    openAILogin.signOut()
                }

            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                if openAILogin.canResumeCachedSession {
                    Button("Retry saved session") {
                        Task { await openAILogin.resumeCachedSession() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Sign in again") {
                        startFreshSignIn()
                    }
                } else {
                    Button("Sign in again") {
                        startFreshSignIn()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text("Temporary convenience only; this is not the production TuberNotes gateway or a promise of third-party OpenAI support.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
    }

    private func loginProgress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func deviceAuthorization(
        code: String,
        verificationURL: URL,
        isChecking: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter this one-time code on OpenAI's sign-in page:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.title2.monospaced().weight(.bold))
                .textSelection(.enabled)
                .accessibilityLabel("OpenAI device code")
                .accessibilityValue(code)

            Button {
                presentFreshSignIn(code: code, verificationURL: verificationURL)
            } label: {
                Label("Sign in with a fresh account", systemImage: "person.2")
            }
            .buttonStyle(.borderedProminent)
            .disabled(ephemeralAuthentication.isPresenting)

            Text("Fresh sign-in copies this code and opens a private system session without existing browser cookies. Reopening it keeps this device-code request active.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("Copy code", systemImage: "doc.on.doc")
                }

                Button {
                    embeddedBrowser = OpenAIEmbeddedBrowserItem(
                        code: code,
                        verificationURL: verificationURL
                    )
                } label: {
                    Label("Use existing browser session", systemImage: "safari")
                }
            }

            HStack {
                Button(isChecking ? "Checking…" : "Check status") {
                    openAILogin.checkStatus()
                }
                .disabled(isChecking)
                Button("Cancel sign-in") {
                    openAILogin.cancel()
                }
            }
        }
    }

    private func startFreshSignIn() {
        shouldPresentFreshSignIn = true
        openAILogin.start()
    }

    private func presentFreshSignIn(code: String, verificationURL: URL) {
        shouldPresentFreshSignIn = false
        UIPasteboard.general.string = code
        ephemeralAuthentication.start(url: verificationURL)
    }
}

@MainActor
private final class OpenAIEphemeralAuthenticationPresenter: NSObject, ObservableObject,
    ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isPresenting = false

    private var session: ASWebAuthenticationSession?
    private var sessionID: UUID?

    func start(url: URL) {
        cancel()

        let id = UUID()
        sessionID = id
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                self.session = nil
                self.sessionID = nil
                self.isPresenting = false
            }
        }
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        self.session = session
        isPresenting = session.start()
        if !isPresenting {
            self.session = nil
            sessionID = nil
        }
    }

    func cancel() {
        let activeSession = session
        session = nil
        sessionID = nil
        isPresenting = false
        activeSession?.cancel()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }
}

private struct OpenAIEmbeddedBrowserItem: Identifiable {
    let id = UUID()
    let code: String
    let verificationURL: URL
}

private struct OpenAIEmbeddedSignInSheet: View {
    let item: OpenAIEmbeddedBrowserItem
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenAI sign-in")
                            .font(.headline)
                        Text("Enter this one-time code when prompted:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close", action: onClose)
                        .accessibilityHint("Closes the browser without cancelling sign-in")
                }

                Text(item.code)
                    .font(.title2.monospaced().weight(.bold))
                    .textSelection(.enabled)
                    .accessibilityLabel("OpenAI device code")
                    .accessibilityValue(item.code)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            EmbeddedSafariView(url: item.verificationURL, onClose: onClose)
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityIdentifier("openai-embedded-sign-in")
    }
}

private struct EmbeddedSafariView: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onClose()
        }
    }
}
