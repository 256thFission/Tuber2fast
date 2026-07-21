import AuthenticationServices
import SafariServices
import SwiftUI
import UIKit

/// Frosted question panel for the active Agentic Layer. Its hierarchy is derived
/// directly from persisted spatial Pins, so the tree and page never diverge.
struct AgentSidebarView: View {
    @ObservedObject var vm: NotebookViewModel
    @Binding var selectedParentThreadID: UUID?
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
    var isFullChatTab = false
    var onClose: () -> Void
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
    private var sidebarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))
            ScrollView { content.padding(16) }
        }
        .frame(width: isFullChatTab ? nil : 340)
        .frame(maxWidth: isFullChatTab ? .infinity : nil)
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
            guard vm.canAnalyzeCurrentPage else { return }
            guard !isTemporarySignInRequired else {
                onEditProviderAccess()
                return
            }
            if let selectedParentThreadID {
                vm.analyzeCurrentPage(
                    question: prompt.isEmpty ? nil : prompt,
                    parentThreadID: selectedParentThreadID
                )
            } else {
                vm.placeGuidancePins(question: prompt.isEmpty ? nil : prompt)
            }
        } label: {
            Label(analyzeTitle, systemImage: "mappin.and.ellipse")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.isAnalyzing || !vm.canAnalyzeCurrentPage)
        .accessibilityHint(
            isTemporarySignInRequired
                ? "Opens OpenAI sign-in."
                : (!vm.canAnalyzeCurrentPage ? "Add ink or an image to analyze." : "")
        )
        .padding(.top, 4)

        if !isProviderConfigured {
            Button { onEditProviderAccess() } label: {
                Text(providerConfigurationPrompt)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .accessibilityLabel("Agent provider access")
            .accessibilityValue(providerAccessValue)
            .accessibilityHint("Configure a provider for live analysis")
            .accessibilityIdentifier("assistant-provider-access")
        }

        if vm.isAnalyzing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Placing guidance Pins…").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { vm.cancelAnalysis() }
            }
            .padding(.top, 12)
        }

        if let error = vm.agentError {
            VStack(alignment: .leading, spacing: 5) {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Retry") { vm.retryLastAnalysis() }
                    .font(.caption.weight(.semibold))
            }
            .padding(.top, 8)
        }

        if treeItems.isEmpty && !vm.isAnalyzing {
            emptyState.padding(.top, 20)
        } else {
            conversationTree.padding(.top, 16)
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
