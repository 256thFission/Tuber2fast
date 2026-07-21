import CoreImage
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Editor for a single notebook: a GoodNotes-style vertical page (paper is drawn
/// inside the scrolling canvas), the floating menu bar, and the page navigator.
struct NotebookView: View {
    @StateObject private var vm: NotebookViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tuber.fingerDrawing") private var fingerDrawing = false
    @AppStorage("tuber.snapStraight") private var snapStraight = true
#if DEBUG
    @AppStorage(AgentProviderAccess.credentialStorageKey) private var agentCredential = ""
    @AppStorage(AgentProviderAccess.providerStorageKey) private var agentProviderRaw = AgentProvider.openAI.rawValue
    @AppStorage(AgentAccessMethod.storageKey) private var agentAccessMethodRaw = AgentAccessMethod.apiKey.rawValue
    @AppStorage(AgentProviderAccess.modelStorageKey) private var agentModel = ""
#endif
    @ObservedObject private var openAILogin = OpenAICodexLoginSession.shared
    @AppStorage("tuber.pencilDoubleTap") private var pencilDoubleTapEnabled = true
    @AppStorage("tuber.pencilSqueeze") private var pencilSqueezeEnabled = true
    @AppStorage("tuber.pencilHoverPreview") private var pencilHoverPreviewEnabled = true
    @AppStorage("tuber.notebookToolbarDock") private var toolbarDockRaw = NotebookToolbarDock.bottom.rawValue
    @State private var showPages = false
    @State private var showStrip = false
    @State private var showAgentSidebar = false
    @State private var selectedAgentParentThreadID: UUID?
    @State private var selectedAgentMessageID: UUID?
    @State private var forkedAgentMessageID: UUID?
    @State private var showProviderAccessPopup = false
    @State private var showToolbarSettings = false
    @State private var showPageSettings = false
    @State private var openProviderAccessAfterToolbarSettings = false
    @State private var isRefinementActive = false
    @State private var magicEraserPath: [PageNormalizedPoint] = []
    @State private var magicEraserSelection: SelectionArtifact?
    @State private var magicAskText = ""
    @State private var isMagicAskExpanded = false
    @State private var pendingGuidanceAfterSignIn: SelectionArtifact?
    @State private var pendingGuidanceIntent: InvestigationIntent?
    @State private var pendingMagicChatAfterSignIn: SelectionArtifact?
    @State private var sendsMagicLassoToChat = false
    @State private var isRefinementLassoActive = false
    @State private var showExportOptions = false
    @State private var showFileExporter = false
    @State private var exportContentType = UTType.pdf
    @State private var exportPageScope = ExportPageScope.entireDocument
    @State private var selectedExportPageIDs = Set<UUID>()
    @State private var pendingExportPresentation: PendingExportPresentation?
    @State private var isPageLocked = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var pendingImageImport: PendingImageImport?
    @State private var removesImportedImageBackground = false
    @State private var isPreparingImageImport = false
    @State private var imageImportTask: Task<Void, Never>?
    @State private var imageImportError: String?
    @State private var pdfTolerance = Double(NotePDFExporter.defaultTolerance)
    @State private var includePDFWorkspaceBackground = false
    @State private var exportDocument = NotebookExportDocument()
    @State private var exportError: String?
    @State private var pageViewportFrame = CGRect.zero
    @StateObject private var rippleModel = AmbientRippleModel()
    @State private var pencilPaletteAnchor: CGPoint?
    @State private var pencilPaletteMode: PencilShortcutPalette.Mode = .full
    @State private var flipOffset: CGFloat = 0
    @State private var isFlipAnimating = false
    @State private var pageContainerSize = CGSize(width: 1024, height: 1024)
    @State private var isAddPageHoldActive = false
    @State private var addPageHoldProgress: CGFloat = 0
    @State private var addPageHoldToken = UUID()
    @State private var didAddPageDuringCurrentGesture = false
    @State private var addPageHoldCompletionCount = 0
    @State private var pageContainerWidth: CGFloat = 1024
    // The zoom capsule is transient chrome: visible while a pinch is in flight
    // or briefly after any zoom change, hidden the rest of the time.
    @State private var isZoomHUDVisible = false
    @State private var isPinchZooming = false
    @State private var zoomHUDHideTask: Task<Void, Never>?
    @State private var toolbarDragOffset = CGSize.zero
    private let onAgentNavigationRequest: ((AgentNavigationRequest) -> Void)?
    private let onReturnFromAgentNavigation: (() -> Void)?

    init(
        notebook: Notebook,
        store: NotebookStore,
        initialPageIndex: Int? = nil,
        onAgentNavigationRequest: ((AgentNavigationRequest) -> Void)? = nil,
        onReturnFromAgentNavigation: (() -> Void)? = nil
    ) {
        let viewModel = NotebookViewModel(notebook: notebook, store: store)
        if let initialPageIndex, notebook.pages.indices.contains(initialPageIndex) {
            viewModel.currentIndex = initialPageIndex
            viewModel.currentDrawingLayerID = notebook.pages[initialPageIndex].drawingLayers[0].id
            viewModel.lastTemplate = notebook.pages[initialPageIndex].template
        }
        _vm = StateObject(wrappedValue: viewModel)
        self.onAgentNavigationRequest = onAgentNavigationRequest
        self.onReturnFromAgentNavigation = onReturnFromAgentNavigation
    }

    var body: some View {
        ZStack {
            AmbientBackground(
                rippleModel: rippleModel,
                isAgenticLayerActive: vm.isAgenticLayersActive
            )

            // The UIKit observer attaches passively at the window level. It
            // reports Pencil movement without becoming a hit-test target.
            AmbientTouchLayer { point in rippleModel.add(at: point) }
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Notebook geometry is invariant while assistant chrome comes and
            // goes. The sidebar overlays the trailing edge; it never reflows,
            // recenters, or rescales the page beneath the user's hand.
            VStack(spacing: 0) {
                if showStrip {
                    PageStripView(vm: vm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                pageArea
            }

            if showAgentSidebar {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    AgentSidebarView(
                        vm: vm,
                        selectedParentThreadID: $selectedAgentParentThreadID,
                        selectedMessageID: $selectedAgentMessageID,
                        forkedFromMessageID: $forkedAgentMessageID,
                        isFullChatTab: true,
                        onClose: { withAnimation { showAgentSidebar = false } },
                        onOpenFullChat: {},
                        onAgentNavigationRequest: onAgentNavigationRequest,
                        onEditProviderAccess: { withAnimation { showProviderAccessPopup = true } }
                    )
                }
                .transition(.move(edge: .trailing))
                // Stay above a right-docked writing toolbar so chat controls
                // cannot be covered; the toolbar itself does not move.
                .zIndex(7.25)
            }

            if vm.isArrangingImages {
                arrangeControls.zIndex(6)
            }

            GeometryReader { toolbarProxy in
                NotebookToolbar(
                    vm: vm,
                    undo: vm.undo,
                    isLassoActive: $vm.isLassoActive,
                    isRefinementActive: $isRefinementActive,
                    isRefinementLassoActive: $isRefinementLassoActive,
                    imagePickerItem: $pickerItem,
                    dock: toolbarDock,
                    onDockDragChanged: { toolbarDragOffset = $0 },
                    onDockDragEnded: { finishToolbarDrag($0, in: toolbarProxy.size) },
                    onAskAgent: { withAnimation { showAgentSidebar = true } },
                    onRefinementChatModeChanged: { sendsMagicLassoToChat = $0 }
                )
                .offset(toolbarDragOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: toolbarDock.alignment)
                .padding(toolbarDockPaddingEdge, 14)
            }
            .zIndex(7)

            if pencilPaletteAnchor != nil {
                pencilPaletteLayer
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .zIndex(7.5)
            }

            if showPages {
                PageFlipOverlay(vm: vm) { withAnimation { showPages = false } }
                    .transition(.opacity)
                    .zIndex(8)
            }

            if showProviderAccessPopup {
                AgentProviderAccessPopup { withAnimation { showProviderAccessPopup = false } }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10)
            }

        }
        .navigationTitle(vm.notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    vm.persistNow()
                    if let onReturnFromAgentNavigation {
                        onReturnFromAgentNavigation()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel(
                    onReturnFromAgentNavigation == nil ? "Back to notebooks" : "Back to previous notebook"
                )
                .accessibilityIdentifier(
                    onReturnFromAgentNavigation == nil ? "notebook-back" : "citation-notebook-return"
                )
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { withAnimation { showStrip.toggle() } } label: {
                    Image(systemName: showStrip ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2")
                }
                .accessibilityIdentifier("nav-page-strip")

                pageSettingsButton

                if vm.settings.showsPageLock {
                    pageLockButton
                }

                if vm.settings.showsExport {
                    exportButton
                }

                Button(action: toggleAgentSidebar) {
                    Image(systemName: showAgentSidebar ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        .foregroundStyle(showAgentSidebar ? Color.accentColor : Color.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityIdentifier("nav-chat-sidebar")
                .accessibilityLabel(showAgentSidebar ? "Close chat sidebar" : "Open chat sidebar")
                .accessibilityValue(showAgentSidebar ? "Open" : "Closed")

                toolbarSettingsButton
            }
        }
        .sheet(isPresented: $showExportOptions, onDismiss: presentPendingExport) {
            exportOptions
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPageSettings) {
            PageSettingsLightbox(
                vm: vm,
                snapStraight: $snapStraight,
                fingerDrawing: $fingerDrawing,
                isPageLocked: $isPageLocked
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $pendingImageImport) { pending in
            imageImportOptions(for: pending)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(isPreparingImageImport)
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename(
                extension: exportContentType == .pdf ? "pdf" : TuberNoteArchive.fileExtension
            ),
            onCompletion: handleExportCompletion
        )
        .alert("Export failed", isPresented: exportErrorBinding) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "The file could not be exported.")
        }
        .alert("Couldn’t import image", isPresented: imageImportErrorBinding) {
            Button("OK", role: .cancel) { imageImportError = nil }
        } message: {
            Text(imageImportError ?? "The image could not be prepared.")
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    pendingImageImport = PendingImageImport(data: data, preview: image)
                    removesImportedImageBackground = false
                } else {
                    imageImportError = "TuberNotes couldn’t read that photo."
                }
                pickerItem = nil
            }
        }
        .onChange(of: vm.isAgenticLayersActive) { _, isActive in
            guard !isActive else { return }
            if showAgentSidebar { withAnimation { showAgentSidebar = false } }
        }
        .onChange(of: vm.currentDrawingLayerID) { _, _ in
            dismissPencilPalette()
            isRefinementLassoActive = false
            if magicEraserSelection?.pageID != vm.currentPageID {
                clearMagicSelectionForPageChange()
            }
        }
        .onChange(of: vm.isLassoActive) { _, active in
            if active { dismissPencilPalette() }
        }
        .onChange(of: isRefinementActive) { _, active in
            if active {
                magicEraserPath = []
                magicEraserSelection = nil
                magicAskText = ""
                isMagicAskExpanded = false
                dismissPencilPalette()
            } else if !isRefinementLassoActive {
                sendsMagicLassoToChat = false
            }
        }
        .onChange(of: openAILogin.phase) { _, phase in
            guard case .signedIn = phase else { return }
            if let selection = pendingMagicChatAfterSignIn {
                pendingMagicChatAfterSignIn = nil
                submitMagicSelectionToChat(selection)
            } else if let selection = pendingGuidanceAfterSignIn {
                let intent = pendingGuidanceIntent
                pendingGuidanceAfterSignIn = nil
                pendingGuidanceIntent = nil
                if let intent { vm.requestIntervention(selection: selection, intent: intent) }
            }
        }
        .onChange(of: vm.newestAgentThreadID) { _, threadID in
            guard threadID != nil, !magicEraserPath.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                magicEraserPath = []
                magicEraserSelection = nil
                magicAskText = ""
                isMagicAskExpanded = false
            }
        }
        .onChange(of: vm.isArrangingImages) { _, active in
            if active { dismissPencilPalette() }
        }
        .onChange(of: vm.settings) { _, _ in vm.scheduleSave() }
        .onChange(of: vm.settings.pageScrollDirection) { _, _ in
            cancelAddPageHold()
            flipOffset = 0
        }
        .onDisappear {
            cancelAddPageHold()
            imageImportTask?.cancel()
            imageImportTask = nil
            vm.persistNow()
        }
    }

    private var pageSettingsButton: some View {
        Button { showPageSettings = true } label: {
            Image(systemName: "square.grid.2x2")
        }
        .accessibilityIdentifier("nav-template")
        .accessibilityLabel("Page settings")
        .accessibilityValue(vm.currentTemplate.label)
        .accessibilityHint("Choose a paper template and adjust drawing, lock, zoom, or image settings")
    }

    private var toolbarDock: NotebookToolbarDock {
        NotebookToolbarDock(rawValue: toolbarDockRaw) ?? .bottom
    }

    private var toolbarDockPaddingEdge: Edge.Set {
        switch toolbarDock {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    private func finishToolbarDrag(_ drag: DragGesture.Value, in containerSize: CGSize) {
        let origin: CGPoint
        switch toolbarDock {
        case .top: origin = CGPoint(x: containerSize.width / 2, y: 0)
        case .bottom: origin = CGPoint(x: containerSize.width / 2, y: containerSize.height)
        case .leading: origin = CGPoint(x: 0, y: containerSize.height / 2)
        case .trailing: origin = CGPoint(x: containerSize.width, y: containerSize.height / 2)
        }
        let predicted = CGPoint(
            x: origin.x + drag.predictedEndTranslation.width,
            y: origin.y + drag.predictedEndTranslation.height
        )
        let distances: [(NotebookToolbarDock, CGFloat)] = [
            (.top, abs(predicted.y)),
            (.bottom, abs(containerSize.height - predicted.y)),
            (.leading, abs(predicted.x)),
            (.trailing, abs(containerSize.width - predicted.x)),
        ]
        let destination = distances.min(by: { $0.1 < $1.1 })?.0 ?? .bottom
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            toolbarDragOffset = .zero
            toolbarDockRaw = destination.rawValue
        }
    }

    private func toggleAgentSidebar() {
        if showAgentSidebar {
            withAnimation { showAgentSidebar = false }
            return
        }

        if !vm.isAgenticLayersActive {
            let layers = vm.conversationLayers.layers
            if let layerID = layers.first(where: { $0.id == vm.selectedLayerID })?.id
                ?? layers.first?.id {
                vm.selectAgenticLayer(layerID)
            }
        }

        withAnimation {
            showAgentSidebar = true
        }
    }

    private var pageLockButton: some View {
        Button {
            isPageLocked.toggle()
        } label: {
            Image(systemName: isPageLocked ? "lock.fill" : "lock.open")
                .foregroundStyle(isPageLocked ? Color.accentColor : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .speed(1.4), value: isPageLocked)
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: isPageLocked)
        .accessibilityIdentifier("toolbar-page-lock")
        .accessibilityLabel(isPageLocked ? "Unlock page" : "Lock page")
        .accessibilityValue(isPageLocked ? "Locked" : "Unlocked")
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { vm.zoomOut() } label: {
                Image(systemName: "minus")
                    .frame(width: 30, height: 30)
            }
            .disabled(vm.zoomScale <= 0.5)
            .accessibilityLabel("Zoom out")
            .accessibilityIdentifier("notebook-zoom-out")

            Button { vm.resetZoom() } label: {
                VStack(spacing: 0) {
                    Text(vm.zoomLabel)
                        .font(.caption.monospacedDigit().weight(.semibold))
                    Text("Pinch to zoom · Unlocked")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 68, minHeight: 30)
            }
            .accessibilityLabel("Reset zoom")
            .accessibilityValue(vm.zoomLabel)
            .accessibilityHint("You can also pinch the unlocked page to zoom")
            .accessibilityIdentifier("notebook-zoom-reset")

            Button { vm.zoomIn() } label: {
                Image(systemName: "plus")
                    .frame(width: 30, height: 30)
            }
            .disabled(vm.zoomScale >= 5)
            .accessibilityLabel("Zoom in")
            .accessibilityIdentifier("notebook-zoom-in")
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notebook-zoom-controls")
    }

    private var exportButton: some View {
        Button {
            openExportOptions()
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityIdentifier("toolbar-export")
        .accessibilityLabel("Export note")
    }

    private var toolbarSettingsButton: some View {
        Button {
            showToolbarSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityIdentifier("toolbar-settings")
        .accessibilityLabel("Notebook controls settings")
        .popover(isPresented: $showToolbarSettings) {
            NotebookToolbarSettingsView(
                vm: vm,
                pencilDoubleTapEnabled: $pencilDoubleTapEnabled,
                pencilSqueezeEnabled: $pencilSqueezeEnabled,
                pencilHoverPreviewEnabled: $pencilHoverPreviewEnabled,
                isAnalysisAccessConfigured: isAnalysisAccessConfigured,
                analysisAccessSummary: analysisAccessSummary,
                onEditAnalysisAccess: {
                    openProviderAccessAfterToolbarSettings = true
                    showToolbarSettings = false
                },
                onDismiss: {
                    guard openProviderAccessAfterToolbarSettings else { return }
                    openProviderAccessAfterToolbarSettings = false
                    withAnimation { showProviderAccessPopup = true }
                }
            )
                .presentationCompactAdaptation(.popover)
        }
    }

    private var isAnalysisAccessConfigured: Bool {
#if DEBUG
        let provider = AgentProvider(rawValue: agentProviderRaw) ?? .openAI
        if provider == .openAI,
           AgentAccessMethod(rawValue: agentAccessMethodRaw) == .chatGPTTemporary {
            guard case .signedIn = openAILogin.phase else { return false }
            return true
        }
        return !agentCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
#else
        guard case .signedIn = openAILogin.phase else { return false }
        return true
#endif
    }

    private var analysisAccessSummary: String {
#if DEBUG
        guard let access = analysisProviderAccess else { return "Demo mode" }
        return "\(access.provider.label) · \(access.model)"
#else
        return "Demo mode"
#endif
    }

#if DEBUG
    private var analysisProviderAccess: AgentProviderAccess? {
        AgentProviderAccess(
            provider: AgentProvider(rawValue: agentProviderRaw) ?? .openAI,
            credential: agentCredential,
            model: agentModel
        )
    }
#endif

    private var arrangeControls: some View {
        VStack {
            HStack(spacing: 10) {
                Label("Move, pinch, or twist", systemImage: "hand.draw")
                    .font(.footnote.weight(.medium))
                Divider().frame(height: 18)
                Button { vm.rotateSelectedImage() } label: {
                    Label("Rotate", systemImage: "rotate.right")
                }
                .disabled(vm.selectedImageID == nil)
                .accessibilityIdentifier("rotate-selected-image")
                Button(role: .destructive) { vm.deleteSelectedImage() } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(vm.selectedImageID == nil)
                Button("Done") { withAnimation { vm.finishArrangingImages() } }
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 12)
            Spacer()
        }
    }

    private func imageImportOptions(for pending: PendingImageImport) -> some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    CheckerboardBackground()
                    Image(uiImage: pending.preview)
                        .resizable()
                        .scaledToFit()
                }
                .frame(maxWidth: .infinity, maxHeight: 230)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Toggle(isOn: $removesImportedImageBackground) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Make background transparent")
                        Text("Keeps the foreground subjects using on-device image processing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isPreparingImageImport)
                .accessibilityIdentifier("image-import-remove-background")

                Button {
                    importPendingImage(pending)
                } label: {
                    HStack {
                        if isPreparingImageImport { ProgressView() }
                        Text(isPreparingImageImport ? "Preparing…" : "Add to Page")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparingImageImport)
                .accessibilityIdentifier("image-import-confirm")
            }
            .padding(20)
            .navigationTitle("Import Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pendingImageImport = nil }
                        .disabled(isPreparingImageImport)
                }
            }
        }
    }

    private func importPendingImage(_ pending: PendingImageImport) {
        guard !isPreparingImageImport else { return }
        imageImportTask?.cancel()
        isPreparingImageImport = true
        let shouldRemoveBackground = removesImportedImageBackground
        let importID = pending.id

        imageImportTask = Task {
            defer {
                isPreparingImageImport = false
                imageImportTask = nil
            }
            do {
                let data = shouldRemoveBackground
                    ? try await ImageBackgroundRemover.removeBackground(from: pending.data)
                    : pending.data
                try Task.checkCancellation()
                guard pendingImageImport?.id == importID else { return }
                guard let image = UIImage(data: data) else {
                    throw ImageBackgroundRemovalError.unreadableResult
                }
                vm.addImage(
                    data: data,
                    aspect: image.size.width / max(image.size.height, 1)
                )
                pendingImageImport = nil
                removesImportedImageBackground = false
            } catch is CancellationError {
                return
            } catch {
                imageImportError = error.localizedDescription
            }
        }
    }

    private var exportOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Export Note")
                        .font(.headline)
                    Spacer()
                    Button {
                        dismissExportOptions()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close export options")
                    .accessibilityIdentifier("export-options-close")
                }

                Text("Pages")
                    .font(.subheadline.weight(.semibold))

                Picker("Pages", selection: exportPageScopeBinding) {
                    Text("Entire Document").tag(ExportPageScope.entireDocument)
                    Text("Choose Pages").tag(ExportPageScope.selectedPages)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("export-page-scope")

                if exportPageScope == .selectedPages {
                    exportPagePicker
                }

                Text(exportPageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("export-page-summary")

                Divider()

                Text("PDF Compression")
                    .font(.subheadline.weight(.semibold))

                Toggle("Include workspace background", isOn: $includePDFWorkspaceBackground)
                    .accessibilityIdentifier("pdf-include-workspace-background")

                Text("Adds each page’s paper template and placed images beneath the ink.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(value: $pdfTolerance, in: 0.05...2, step: 0.05) {
                    Text("Compression")
                } minimumValueLabel: {
                    Text("Low")
                } maximumValueLabel: {
                    Text("High")
                }
                .accessibilityIdentifier("pdf-compression-slider")

                Text("Maximum stroke deviation: \(pdfTolerance, specifier: "%.2f") pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    preparePDFExport()
                } label: {
                    Label("Export PDF", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(exportPages.isEmpty)
                .accessibilityIdentifier("pdf-export-confirm")

                Divider()

                Button(action: prepareSPUDExport) {
                    Label("Export SPUD", systemImage: "archivebox")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(exportPages.isEmpty)
                .accessibilityIdentifier("spud-export-confirm")
            }
            .padding(20)
        }
        .frame(width: 360)
    }

    private var exportPagePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Select pages")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("All") {
                    selectedExportPageIDs = Set(vm.notebook.pages.map(\.id))
                }
                Button("Clear") {
                    selectedExportPageIDs.removeAll()
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.notebook.pages.indices, id: \.self) { index in
                        let page = vm.notebook.pages[index]
                        let isSelected = selectedExportPageIDs.contains(page.id)
                        Button {
                            toggleExportPage(page.id)
                        } label: {
                            HStack(spacing: 5) {
                                Text("\(index + 1)")
                                    .monospacedDigit()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                }
                            }
                            .frame(minWidth: 38)
                        }
                        .buttonStyle(.bordered)
                        .tint(isSelected ? Color.indigo : Color.secondary)
                        .accessibilityLabel("Page \(index + 1)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("export-page-\(index + 1)")
                    }
                }
            }
        }
    }

    private var exportPageScopeBinding: Binding<ExportPageScope> {
        Binding(
            get: { exportPageScope },
            set: { scope in
                exportPageScope = scope
                if scope == .selectedPages, selectedExportPageIDs.isEmpty {
                    selectedExportPageIDs.insert(vm.currentPageID)
                }
            }
        )
    }

    private var exportPages: [NotebookPage] {
        switch exportPageScope {
        case .entireDocument:
            return vm.notebook.pages
        case .selectedPages:
            return vm.notebook.pages.filter { selectedExportPageIDs.contains($0.id) }
        }
    }

    private var exportPageSummary: String {
        let count = exportPages.count
        if exportPageScope == .entireDocument {
            return "All \(count) page\(count == 1 ? "" : "s") will be exported."
        }
        guard count > 0 else { return "Choose at least one page to export." }
        return "\(count) selected page\(count == 1 ? "" : "s") will be exported in notebook order."
    }

    private var exportNotebook: Notebook {
        let pages = exportPages
        guard pages.count != vm.notebook.pages.count else { return vm.notebook }
        let exportPageIDs = Set(pages.map(\.id))
        let layers = vm.notebook.agenticLayers.map { layer in
            var filtered = layer
            filtered.conversations = layer.conversations.filter {
                exportPageIDs.contains($0.pageID)
            }
            return filtered
        }
        return Notebook(
            id: vm.notebook.id,
            title: vm.notebook.title,
            cover: vm.notebook.cover,
            pages: pages,
            agenticLayers: layers,
            createdAt: vm.notebook.createdAt,
            updatedAt: vm.notebook.updatedAt,
            settings: vm.notebook.settings
        )
    }

    private func openExportOptions() {
        exportPageScope = .entireDocument
        selectedExportPageIDs.removeAll()
        includePDFWorkspaceBackground = false
        showExportOptions = true
    }

    private func toggleExportPage(_ pageID: UUID) {
        if selectedExportPageIDs.contains(pageID) {
            selectedExportPageIDs.remove(pageID)
        } else {
            selectedExportPageIDs.insert(pageID)
        }
    }

    private func preparePDFExport() {
        let pages = exportPages
        guard !pages.isEmpty else { return }
        vm.persistNow()
        let backgrounds = includePDFWorkspaceBackground
            ? pages.map { renderWorkspaceBackground(for: $0) }
            : []
        exportDocument = NotebookExportDocument(data: NotePDFExporter.makePDF(
            from: pages.map(\.drawing),
            workspaceBackgrounds: backgrounds,
            pageBounds: CGRect(origin: .zero, size: NotebookPageLayout.size),
            tolerance: CGFloat(pdfTolerance)
        ).data)
        queueExportPresentation(.pdf)
    }

    private func renderWorkspaceBackground(for page: NotebookPage) -> UIImage {
        let pageBounds = CGRect(origin: .zero, size: NotebookPageLayout.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: NotebookPageLayout.size,
            format: format
        )
        return renderer.image { rendererContext in
            let paperView = PaperSheetView(frame: pageBounds)
            paperView.template = page.template
            paperView.layer.render(in: rendererContext.cgContext)

            for placedImage in page.images {
                placedImage.draw(in: CGRect(
                    x: placedImage.rect.minX * pageBounds.width,
                    y: placedImage.rect.minY * pageBounds.height,
                    width: placedImage.rect.width * pageBounds.width,
                    height: placedImage.rect.height * pageBounds.height
                ))
            }
        }
    }

    private func prepareSPUDExport() {
        guard !exportPages.isEmpty else { return }
        vm.persistNow()
        do {
            exportDocument = NotebookExportDocument(
                data: try TuberNoteArchiveCodec.encode(notebook: exportNotebook)
            )
            queueExportPresentation(.spud)
        } catch {
            queueExportPresentation(.error(error.localizedDescription))
        }
    }

    private func queueExportPresentation(_ presentation: PendingExportPresentation) {
        pendingExportPresentation = presentation
        switch presentation {
        case .pdf:
            exportContentType = .pdf
        case .spud:
            exportContentType = .tuberNoteArchive
        case .error:
            break
        }
        showExportOptions = false
    }

    private func dismissExportOptions() {
        showExportOptions = false
    }

    private func presentPendingExport() {
        guard let presentation = pendingExportPresentation else { return }
        pendingExportPresentation = nil

        Task { @MainActor in
            // The sheet's onDismiss callback establishes the presentation order;
            // yielding once lets SwiftUI commit that dismissal before the exporter.
            await Task.yield()
            switch presentation {
            case .pdf, .spud:
                showFileExporter = true
            case .error(let message):
                exportError = message
            }
        }
    }

    private func exportFilename(extension fileExtension: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let sanitizedTitle = vm.notebook.title
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = sanitizedTitle.isEmpty ? "Untitled" : sanitizedTitle
        return "\(title).\(fileExtension)"
    }

    private func handleExportCompletion(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else {
                return
            }
            exportError = error.localizedDescription
        }
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }

    private var imageImportErrorBinding: Binding<Bool> {
        Binding(
            get: { imageImportError != nil },
            set: { if !$0 { imageImportError = nil } }
        )
    }

    // MARK: Apple Pencil shortcut palette

    private var pencilPaletteLayer: some View {
        GeometryReader { geometry in
            let globalFrame = geometry.frame(in: .global)
            let anchor = pencilPaletteAnchor ?? .zero
            let localAnchor = CGPoint(
                x: anchor.x - globalFrame.minX,
                y: anchor.y - globalFrame.minY
            )
            let paletteSize = estimatedPencilPaletteSize

            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismissPencilPalette() }

                PencilShortcutPalette(
                    vm: vm,
                    undo: vm.undo,
                    mode: pencilPaletteMode,
                    onAction: { dismissPencilPalette() }
                )
                .position(
                    clampedPalettePosition(
                        near: localAnchor,
                        size: paletteSize,
                        in: geometry.size
                    )
                )
            }
        }
        .ignoresSafeArea()
    }

    private var estimatedPencilPaletteSize: CGSize {
        let width: CGFloat = 212
        let swatchRows = max(1, Int(ceil(Double(vm.settings.favoriteColors.count) / 5)))
        let hasColors = !vm.settings.favoriteColors.isEmpty
        var height: CGFloat = 28
        if hasColors {
            height += CGFloat(swatchRows) * 30 + CGFloat(swatchRows - 1) * 10
        }
        if pencilPaletteMode == .full {
            if hasColors { height += 13 }
            height += 34 + 12
            height += 13
            height += 34
        }
        return CGSize(width: width, height: height)
    }

    private func clampedPalettePosition(
        near point: CGPoint,
        size: CGSize,
        in bounds: CGSize
    ) -> CGPoint {
        let margin: CGFloat = 12
        let tipOffset: CGFloat = 28
        var center = CGPoint(
            x: point.x + tipOffset + size.width / 2,
            y: point.y + tipOffset + size.height / 2
        )

        if center.x + size.width / 2 > bounds.width - margin {
            center.x = point.x - tipOffset - size.width / 2
        }
        if center.y + size.height / 2 > bounds.height - margin {
            center.y = point.y - tipOffset - size.height / 2
        }

        center.x = min(
            max(center.x, margin + size.width / 2),
            bounds.width - margin - size.width / 2
        )
        center.y = min(
            max(center.y, margin + size.height / 2),
            bounds.height - margin - size.height / 2
        )
        return center
    }

    private func showPencilPalette(at screenPoint: CGPoint, colorsOnly: Bool) {
        let mode: PencilShortcutPalette.Mode = colorsOnly ? .colorsOnly : .full
        withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
            if pencilPaletteAnchor != nil, pencilPaletteMode == mode {
                pencilPaletteAnchor = nil
            } else {
                pencilPaletteMode = mode
                pencilPaletteAnchor = screenPoint
            }
        }
    }

    private func dismissPencilPalette() {
        guard pencilPaletteAnchor != nil else { return }
        withAnimation(.easeOut(duration: 0.16)) { pencilPaletteAnchor = nil }
    }

    /// Shows the zoom capsule and schedules it to fade out after a short dwell.
    private func flashZoomHUD() {
        withAnimation(.easeOut(duration: 0.16)) { isZoomHUDVisible = true }
        zoomHUDHideTask?.cancel()
        zoomHUDHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { isZoomHUDVisible = false }
        }
    }

    // MARK: Interactive page turn

    private func handlePageFlipChanged(_ translation: CGFloat) {
        guard !isFlipAnimating, !didAddPageDuringCurrentGesture else { return }
        if !vm.canGoForward, translation <= -addPageHoldActivationDistance {
            beginAddPageHoldIfNeeded()
        } else {
            cancelAddPageHold()
        }

        var offset = translation
        if (offset < 0 && !vm.canGoForward) || (offset > 0 && !vm.canGoBack) {
            offset *= 0.28
        }
        flipOffset = offset
    }

    private func handlePageFlipEnded(_ translation: CGFloat, velocity: CGFloat) {
        cancelAddPageHold()
        let addedPage = didAddPageDuringCurrentGesture
        didAddPageDuringCurrentGesture = false
        guard !isFlipAnimating else { return }
        if addedPage {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.82)) {
                flipOffset = 0
            }
            return
        }
        let width = pageTurnDistance
        let threshold = width * 0.28
        let turnsForward = (translation < -threshold || velocity < -800) && vm.canGoForward
        let turnsBack = (translation > threshold || velocity > 800) && vm.canGoBack

        if turnsForward {
            completePageFlip(forward: true, width: width)
        } else if turnsBack {
            completePageFlip(forward: false, width: width)
        } else {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.82)) {
                flipOffset = 0
            }
        }
    }

    private func beginAddPageHoldIfNeeded() {
        guard !isAddPageHoldActive,
              !didAddPageDuringCurrentGesture,
              !vm.canGoForward else { return }

        let token = UUID()
        addPageHoldToken = token
        addPageHoldProgress = 0
        isAddPageHoldActive = true

        DispatchQueue.main.async {
            guard token == addPageHoldToken, isAddPageHoldActive else { return }
            withAnimation(.linear(duration: addPageHoldDuration)) {
                addPageHoldProgress = 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + addPageHoldDuration) {
            guard token == addPageHoldToken,
                  isAddPageHoldActive,
                  !didAddPageDuringCurrentGesture,
                  !vm.canGoForward else { return }
            didAddPageDuringCurrentGesture = true
            addPageHoldCompletionCount += 1
            cancelAddPageHold()
            completeAddedPageFlip(width: pageTurnDistance)
        }
    }

    private func cancelAddPageHold() {
        guard isAddPageHoldActive || addPageHoldProgress != 0 else { return }
        addPageHoldToken = UUID()
        withAnimation(.easeOut(duration: 0.12)) {
            isAddPageHoldActive = false
            addPageHoldProgress = 0
        }
    }

    private func completeAddedPageFlip(width: CGFloat) {
        isFlipAnimating = true
        withAnimation(.easeOut(duration: 0.18)) {
            flipOffset = -width
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            vm.addPage()
            flipOffset = width
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.20)) { flipOffset = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    isFlipAnimating = false
                }
            }
        }
    }

    private var addPageHoldActivationDistance: CGFloat { 72 }
    private var addPageHoldDuration: TimeInterval { 0.7 }

    private func completePageFlip(forward: Bool, width: CGFloat) {
        isFlipAnimating = true
        withAnimation(.easeOut(duration: 0.18)) {
            flipOffset = forward ? -width : width
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if forward { vm.goForward() } else { vm.goBack() }
            flipOffset = forward ? width : -width
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.20)) { flipOffset = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    isFlipAnimating = false
                }
            }
        }
    }

    private var pageTurnDistance: CGFloat {
        switch vm.settings.pageScrollDirection {
        case .horizontal:
            max(pageContainerSize.width, 320)
        case .vertical:
            max(pageContainerSize.height, 320)
        }
    }

    private var pageTurnTransition: AnyTransition {
        let distance = pageTurnDistance
        switch vm.pageTurnDirection {
        case .forward:
            return .asymmetric(
                insertion: pageTurnTransitionOffset(distance),
                removal: pageTurnTransitionOffset(-distance)
            )
        case .backward:
            return .asymmetric(
                insertion: pageTurnTransitionOffset(-distance),
                removal: pageTurnTransitionOffset(distance)
            )
        }
    }

    private func pageTurnTransitionOffset(_ distance: CGFloat) -> AnyTransition {
        switch vm.settings.pageScrollDirection {
        case .horizontal:
            .offset(x: distance, y: 0)
        case .vertical:
            .offset(x: 0, y: distance)
        }
    }

    private var pageArea: some View {
        ZStack {
            pageComposition
                .id(vm.currentPageID)
                .transition(pageTurnTransition)

            if isAddPageHoldActive {
                addPageHoldOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .sensoryFeedback(.success, trigger: addPageHoldCompletionCount)
        .accessibilityIdentifier("notebook-page-area")
    }

    @ViewBuilder
    private var addPageHoldOverlay: some View {
        switch vm.settings.pageScrollDirection {
        case .horizontal:
            HStack {
                Spacer(minLength: 0)
                AddPageHoldIndicator(progress: addPageHoldProgress)
                    .padding(.trailing, 22)
            }
        case .vertical:
            VStack {
                Spacer(minLength: 0)
                AddPageHoldIndicator(progress: addPageHoldProgress)
                    .padding(.bottom, showsWorkingToolbar ? 88 : 22)
            }
        }
    }

    private var pageComposition: some View {
        NotebookCanvas(
            pageID: vm.currentDrawingLayerID,
            drawingData: vm.currentDrawingLayer.drawingData,
            backgroundDrawingData: vm.backgroundDrawingData,
            tool: vm.tool,
            color: vm.inkUIColor,
            width: vm.activeWidth,
            template: vm.currentTemplate,
            zoomScale: vm.zoomScale,
            pageScrollDirection: vm.settings.pageScrollDirection,
            fingerDrawing: fingerDrawing,
            isLassoActive: vm.isLassoActive,
            isRefinementActive: isRefinementActive,
            lassoRect: vm.lassoRect,
            snapStraight: snapStraight,
            images: vm.currentPage.images,
            isArrangingImages: vm.isArrangingImages,
            selectedImageID: vm.selectedImageID,
            isPageLocked: isPageLocked,
            undo: vm.undo,
            pencilDoubleTapEnabled: pencilDoubleTapEnabled,
            pencilSqueezeEnabled: pencilSqueezeEnabled,
            pencilHoverPreviewEnabled: pencilHoverPreviewEnabled,
            onChange: { vm.updateCurrentDrawing($0) },
            onPencilToggleEraser: { vm.togglePencilEraser() },
            onPencilSwapTool: { vm.swapToPreviousTool() },
            onPencilShowPalette: { point, colorsOnly in
                showPencilPalette(at: point, colorsOnly: colorsOnly)
            },
            onLongPress: { withAnimation { showPages = true } },
            onZoomChanged: { vm.zoomScale = $0 },
            onZoomActivity: { zooming in
                withAnimation(.easeOut(duration: 0.16)) { isPinchZooming = zooming }
                if !zooming { flashZoomHUD() }
            },
            onLassoChanged: { vm.lassoRect = $0 },
            onImagesChanged: { vm.updateImages($0) },
            onSelectImage: { vm.selectImage($0) },
            onFlipChanged: { handlePageFlipChanged($0) },
            onFlipEnded: { handlePageFlipEnded($0, velocity: $1) },
            onPageViewportChange: { pageViewportFrame = $0 }
        )
        .id(vm.currentDrawingLayerID)
        .overlay(alignment: .topLeading) {
            ZStack {
                if !magicEraserPath.isEmpty {
                    MagicLassoOverlay(
                        enabled: false,
                        initialPath: magicEraserPath,
                        onCapturedPath: handleMagicEraserCapture
                    )
                    .allowsHitTesting(false)
                }

                if vm.isAgenticLayersActive {
                    PinOverlayView(
                        pins: vm.activeAgenticPins,
                        allowsConversationRequests: true,
                        labelBehavior: .pageAnchoredCompact,
                        onEvent: { event in
                            switch event {
                            case let .moved(annotationID, target):
                                vm.moveAgenticPin(annotationID, to: target)
                            case let .conversationRequested(annotationID):
                                guard let pin = vm.activeAgenticPins.first(where: { $0.id == annotationID }) else {
                                    return
                                }
                                selectedAgentParentThreadID = pin.threadID
                                selectedAgentMessageID = pin.conversationMessages?.last?.id ?? pin.threadID
                                forkedAgentMessageID = nil
                                withAnimation { showAgentSidebar = true }
                            case .expanded(_), .collapsed(_), .citationSelected(_, _):
                                break
                            }
                        }
                    )
                }

                if isRefinementLassoActive {
                    MagicLassoOverlay(
                        enabled: true,
                        initialPath: nil,
                        onCapturedPath: handleMagicEraserCapture
                    )
                }

                if magicEraserSelection != nil,
                   let selectionBounds = MagicLassoGeometry.pageBounds(of: magicEraserPath) {
                    GeometryReader { proxy in
                        let menuSize = magicMenuSize(
                            in: proxy.size,
                            isExpanded: isMagicAskExpanded,
                            hasStatus: vm.agentError != nil || vm.interventionNotice != nil
                        )
                        MagicEraserContextMenu(
                            askText: $magicAskText,
                            isAskExpanded: $isMagicAskExpanded,
                            isSubmitting: vm.isAnalyzing,
                            errorMessage: vm.agentError,
                            notice: vm.interventionNotice,
                            onExplain: {
                                submitMagicGuidance(.explain)
                            },
                            onCheck: {
                                submitMagicGuidance(.check)
                            },
                            onAsk: {
                                let prompt = magicAskText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !prompt.isEmpty else { return }
                                vm.analyzeCurrentPage(question: prompt, selection: magicEraserSelection)
                            },
                            onCancel: {
                                magicEraserPath = []
                                magicEraserSelection = nil
                                magicAskText = ""
                                isMagicAskExpanded = false
                                vm.agentError = nil
                                vm.interventionNotice = nil
                                pendingGuidanceAfterSignIn = nil
                                pendingGuidanceIntent = nil
                            }
                        )
                        .frame(width: menuSize.width, height: menuSize.height)
                        .position(
                            magicMenuPosition(
                                for: selectionBounds,
                                in: proxy.size,
                                menuSize: menuSize
                            )
                        )
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                        .zIndex(20)
                    }
                }
            }
            .frame(width: pageViewportFrame.width, height: pageViewportFrame.height)
            .position(x: pageViewportFrame.midX, y: pageViewportFrame.midY)
        }
        .overlay(alignment: .topTrailing) {
            // Only surface the zoom capsule while the user is actively zooming
            // (pinch in flight, or shortly after any zoom change) — it no
            // longer sits permanently in the corner.
            if !isPageLocked && (isZoomHUDVisible || isPinchZooming) {
                zoomControls
                    .padding(12)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .onChange(of: vm.zoomScale) { _, _ in flashZoomHUD() }
        .clipped()
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, showsWorkingToolbar ? 74 : 12)
        .offset(
            x: vm.settings.pageScrollDirection == .horizontal ? flipOffset : 0,
            y: vm.settings.pageScrollDirection == .vertical ? flipOffset : 0
        )
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { pageContainerSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in
                        pageContainerSize = size
                    }
            }
        )
    }

    private func handleMagicEraserCapture(
        _ path: [PageNormalizedPoint],
        canvasSize: CGSize
    ) {
        _ = canvasSize
        guard let selection = vm.makeSelectionSnapshot(capturedPath: path) else {
            vm.agentError = "Circle an area containing ink or an image."
            magicEraserPath = []
            return
        }
        vm.cancelAnalysis()
        vm.removeAgenticPins(inside: selection.lassoPath, pageID: selection.pageID)
        magicEraserPath = path
        magicEraserSelection = selection
        vm.agentError = nil
        vm.interventionNotice = nil
        isRefinementActive = false
        isRefinementLassoActive = false
        isMagicAskExpanded = false
        magicAskText = ""
        if sendsMagicLassoToChat {
            sendsMagicLassoToChat = false
            if case .signedIn = openAILogin.phase {
                submitMagicSelectionToChat(selection)
            } else {
                pendingMagicChatAfterSignIn = selection
                withAnimation { showProviderAccessPopup = true }
            }
        }
    }

    private func submitMagicSelectionToChat(_ selection: SelectionArtifact) {
        vm.isAgenticLayersActive = true
        selectedAgentParentThreadID = nil
        vm.analyzeCurrentPage(selection: selection)
        withAnimation { showAgentSidebar = true }
    }

    private func submitMagicGuidance(_ intent: InvestigationIntent) {
        guard let selection = magicEraserSelection else { return }
        vm.isAgenticLayersActive = true
        if case .signedIn = openAILogin.phase {
            vm.requestIntervention(selection: selection, intent: intent)
        } else {
            pendingGuidanceAfterSignIn = selection
            pendingGuidanceIntent = intent
            withAnimation { showProviderAccessPopup = true }
        }
    }

    private func clearMagicSelectionForPageChange() {
        vm.cancelAnalysis()
        magicEraserPath = []
        magicEraserSelection = nil
        magicAskText = ""
        isMagicAskExpanded = false
        pendingGuidanceAfterSignIn = nil
        pendingGuidanceIntent = nil
        pendingMagicChatAfterSignIn = nil
        sendsMagicLassoToChat = false
        isRefinementLassoActive = false
        vm.agentError = nil
        vm.interventionNotice = nil
    }

    private func magicMenuPosition(
        for bounds: PageNormalizedRect,
        in size: CGSize,
        menuSize: CGSize
    ) -> CGPoint {
        let halfWidth = menuSize.width / 2
        let halfHeight = menuSize.height / 2
        let anchorX = CGFloat(bounds.x + bounds.width / 2) * size.width
        let below = CGFloat(bounds.y + bounds.height) * size.height + halfHeight + 12
        let above = CGFloat(bounds.y) * size.height - halfHeight - 12
        let x = min(
            max(anchorX, halfWidth + 12),
            max(halfWidth + 12, size.width - halfWidth - 12)
        )
        let y = below + halfHeight <= size.height - 10
            ? below
            : max(halfHeight + 10, above)
        return CGPoint(x: x, y: y)
    }

    private func magicMenuSize(
        in containerSize: CGSize,
        isExpanded: Bool,
        hasStatus: Bool
    ) -> CGSize {
        let desiredWidth: CGFloat = isExpanded ? 380 : (hasStatus ? 340 : 300)
        let desiredHeight: CGFloat = isExpanded
            ? (hasStatus ? 176 : 112)
            : (hasStatus ? 112 : 50)
        return CGSize(
            width: min(desiredWidth, max(containerSize.width - 24, 0)),
            height: min(desiredHeight, max(containerSize.height - 20, 0))
        )
    }

    private var showsWorkingToolbar: Bool {
        vm.settings.showsWritingTools
            || vm.settings.showsLayers
            || vm.settings.showsPageNavigation
    }
}

private struct MagicEraserContextMenu: View {
    @Binding var askText: String
    @Binding var isAskExpanded: Bool
    let isSubmitting: Bool
    let errorMessage: String?
    let notice: InterventionNotice?
    let onExplain: () -> Void
    let onCheck: () -> Void
    let onAsk: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            commandStrip

            if let errorMessage, !isSubmitting {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .background(menuSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            if let notice, !isSubmitting {
                Label(
                    notice.message,
                    systemImage: notice.style == .confirmation
                        ? "checkmark.seal.fill"
                        : "arrow.up.left.and.arrow.down.right"
                )
                .font(.caption)
                .foregroundStyle(notice.style == .confirmation ? Color.green : Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(9)
                .background(menuSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }

            if isAskExpanded {
                HStack(spacing: 8) {
                    TextField("What should the Pins focus on?", text: $askText, axis: .vertical)
                        .lineLimit(1...2)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    Button(action: onAsk) {
                        Image(systemName: "arrow.up")
                            .font(.caption.weight(.bold))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(.black)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send question")
                        .disabled(askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
                .padding(8)
                .background(menuSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("magic-eraser-context-menu")
    }

    private var commandStrip: some View {
        HStack(spacing: 0) {
            if isSubmitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Analyzing…")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                commandButton("Explain", symbol: "lightbulb", action: onExplain)
                stripDivider
                commandButton("Check", symbol: "checkmark.circle", action: onCheck)
                stripDivider
                commandButton("Ask", symbol: "text.bubble") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            isAskExpanded.toggle()
                        }
                }
            }
            stripDivider
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 38, height: 46)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Clear Magic Lasso selection")
        }
        .frame(height: 48)
        .background(menuSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
    }

    private func commandButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 46)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 20)
    }

    private var menuSurface: Color {
        Color(red: 0.055, green: 0.065, blue: 0.095).opacity(0.96)
    }
}

private struct AddPageHoldIndicator: View {
    let progress: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 28, height: 28)

            Text("Hold to add page")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold to add page")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        .accessibilityIdentifier("add-page-hold-indicator")
    }
}

private struct PendingImageImport: Identifiable {
    let id = UUID()
    let data: Data
    let preview: UIImage
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 14
            let rows = Int(ceil(size.height / square))
            let columns = Int(ceil(size.width / square))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(column) * square,
                            y: CGFloat(row) * square,
                            width: square,
                            height: square
                        )),
                        with: .color(.secondary.opacity(0.12))
                    )
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityHidden(true)
    }
}

private enum ImageBackgroundRemovalError: LocalizedError {
    case noForegroundSubject
    case unreadableResult

    var errorDescription: String? {
        switch self {
        case .noForegroundSubject:
            return "No clear foreground subject was found. Try importing the original image instead."
        case .unreadableResult:
            return "TuberNotes couldn’t create a transparent image from that photo."
        }
    }
}

private enum ImageBackgroundRemover {
    private static let context = CIContext()
    private static let maximumPixelDimension: CGFloat = 2_560

    static func removeBackground(from data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    guard var sourceImage = CIImage(
                        data: data,
                        options: [.applyOrientationProperty: true]
                    ), !sourceImage.extent.isEmpty else {
                        throw ImageBackgroundRemovalError.unreadableResult
                    }
                    let longestDimension = max(sourceImage.extent.width, sourceImage.extent.height)
                    let scale = min(1, maximumPixelDimension / longestDimension)
                    if scale < 1 {
                        sourceImage = sourceImage.transformed(
                            by: CGAffineTransform(scaleX: scale, y: scale)
                        )
                    }

                    let request = VNGenerateForegroundInstanceMaskRequest()
                    let handler = VNImageRequestHandler(ciImage: sourceImage, options: [:])
                    try handler.perform([request])
                    guard let observation = request.results?.first,
                          !observation.allInstances.isEmpty else {
                        throw ImageBackgroundRemovalError.noForegroundSubject
                    }

                    let buffer = try observation.generateMaskedImage(
                        ofInstances: observation.allInstances,
                        from: handler,
                        croppedToInstancesExtent: false
                    )
                    let image = CIImage(cvPixelBuffer: buffer)
                    guard let cgImage = context.createCGImage(image, from: image.extent),
                          let pngData = UIImage(cgImage: cgImage).pngData() else {
                        throw ImageBackgroundRemovalError.unreadableResult
                    }
                    return pngData
                })
            }
        }
    }
}

private enum PendingExportPresentation {
    case pdf
    case spud
    case error(String)
}

private enum ExportPageScope: Hashable {
    case entireDocument
    case selectedPages
}

private struct AgenticModeGlow: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shiftsColor = false

    private let colors: [Color] = [
        .cyan.opacity(0.75),
        .blue.opacity(0.85),
        .indigo.opacity(0.90),
        .purple.opacity(0.80),
        .pink.opacity(0.65),
    ]

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: shiftsColor ? .topLeading : .bottomLeading,
                        endPoint: shiftsColor ? .bottomTrailing : .topTrailing
                    )
                )
                .blur(radius: 24)
                .opacity(isActive ? 0.32 : 0)

            Rectangle()
                .stroke(
                    LinearGradient(
                        colors: colors,
                        startPoint: shiftsColor ? .leading : .top,
                        endPoint: shiftsColor ? .trailing : .bottom
                    ),
                    lineWidth: 5
                )
                .blur(radius: 6)
                .opacity(isActive ? 0.90 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                shiftsColor.toggle()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isActive)
    }
}

private struct NotebookExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf, .tuberNoteArchive] }

    var data = Data()

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct PageSettingsLightbox: View {
    @ObservedObject var vm: NotebookViewModel
    @Binding var snapStraight: Bool
    @Binding var fingerDrawing: Bool
    @Binding var isPageLocked: Bool
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 148), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    settingsHeading("Paper Template", detail: "Choose a background without moving ink, images, or Pins.")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(PageTemplate.allCases) { template in
                            PageTemplateChoice(template: template, isSelected: vm.currentTemplate == template) {
                                vm.setTemplate(template)
                            }
                        }
                    }
                    .accessibilityIdentifier("page-template-gallery")

                    Divider()
                    settingsHeading("Drawing", detail: "Control marks and page editing.")
                    VStack(spacing: 0) {
                        settingsToggle("Snap to straight line", isOn: $snapStraight, systemImage: "ruler")
                        Divider().padding(.leading, 50)
                        settingsToggle("Finger drawing", isOn: $fingerDrawing, systemImage: "hand.draw")
                        Divider().padding(.leading, 50)
                        settingsToggle("Lock page", isOn: $isPageLocked, systemImage: isPageLocked ? "lock.fill" : "lock.open")
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

                    Divider()
                    settingsHeading("Page Zoom", detail: isPageLocked ? "Unlock the page to change zoom." : "Adjust or reset the current page view.")
                    HStack(spacing: 12) {
                        Button { vm.zoomOut() } label: { Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 44) }
                            .disabled(isPageLocked || vm.zoomScale <= 0.5)
                        Button { vm.resetZoom() } label: {
                            VStack(spacing: 2) {
                                Text(vm.zoomLabel).font(.headline.monospacedDigit())
                                Text("Reset zoom").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(isPageLocked)
                        Button { vm.zoomIn() } label: { Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44) }
                            .disabled(isPageLocked || vm.zoomScale >= 5)
                    }
                    .buttonStyle(.bordered)

                    if !vm.currentPage.images.isEmpty {
                        Divider()
                        Button {
                            withAnimation { vm.toggleArrangeImages() }
                            dismiss()
                        } label: {
                            Label(vm.isArrangingImages ? "Finish arranging images" : "Arrange images", systemImage: "photo.on.rectangle.angled")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPageLocked)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Page Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Page \(vm.currentIndex + 1) of \(vm.notebook.pages.count)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .accessibilityIdentifier("page-settings-lightbox")
    }

    private func settingsHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>, systemImage: String) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage).padding(.vertical, 11)
        }
        .padding(.horizontal, 14)
    }
}

private struct PageTemplateChoice: View {
    let template: PageTemplate
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                PageTemplatePreview(template: template)
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(7)
                        }
                    }
                Label(template.label, systemImage: template.systemImage)
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: isSelected ? 2 : 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(template.label) paper")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("page-template-\(template.rawValue)")
    }
}

private struct PageTemplatePreview: View {
    let template: PageTemplate

    var body: some View {
        Canvas { context, size in
            let spacing = max(9, template.spacing * 0.36)
            let color = Color(red: 0.50, green: 0.62, blue: 0.78).opacity(0.58)
            var marks = Path()
            if template.isDotted {
                stride(from: spacing, to: size.height, by: spacing).forEach { y in
                    stride(from: spacing, to: size.width, by: spacing).forEach { x in
                        marks.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    }
                }
                context.fill(marks, with: .color(color))
            } else if template.isLined || template.isGrid {
                stride(from: spacing, to: size.height, by: spacing).forEach { y in
                    marks.move(to: CGPoint(x: 0, y: y)); marks.addLine(to: CGPoint(x: size.width, y: y))
                }
                if template.isGrid {
                    stride(from: spacing, to: size.width, by: spacing).forEach { x in
                        marks.move(to: CGPoint(x: x, y: 0)); marks.addLine(to: CGPoint(x: x, y: size.height))
                    }
                }
                context.stroke(marks, with: .color(color), lineWidth: 0.8)
            }
        }
        .background(Color.white)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
