import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Editor for a single notebook: a GoodNotes-style vertical page (paper is drawn
/// inside the scrolling canvas), the floating menu bar, and the page navigator.
struct NotebookView: View {
    @StateObject private var vm: NotebookViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tuber.fingerDrawing") private var fingerDrawing = false
    @AppStorage("tuber.snapStraight") private var snapStraight = true
    @State private var showPages = false
    @State private var showStrip = false
    @State private var showSidebar = false
    @State private var showKeyPopup = false
    @State private var showPDFOptions = false
    @State private var showFileExporter = false
    @State private var exportContentType = UTType.pdf
    @State private var isPageLocked = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var pdfTolerance = Double(NotePDFExporter.defaultTolerance)
    @State private var exportDocument = NotebookExportDocument()
    @State private var exportError: String?
    @State private var pageViewportFrame = CGRect.zero
    @StateObject private var rippleModel = AmbientRippleModel()

    init(notebook: Notebook, store: NotebookStore) {
        _vm = StateObject(wrappedValue: NotebookViewModel(notebook: notebook, store: store))
    }

    var body: some View {
        ZStack {
            AmbientBackground(rippleModel: rippleModel)

            VStack(spacing: 0) {
                if showStrip {
                    PageStripView(vm: vm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                pageArea
            }

            // Passthrough observer: feeds ripples from touches over the page
            // (finger or Pencil) without intercepting them. Sits above the page
            // but below the chrome, so buttons/sidebar don't spawn ripples.
            AmbientTouchLayer { point in rippleModel.add(at: point) }
                .ignoresSafeArea()
                .allowsHitTesting(true)
                .zIndex(1)

            // Assistant floats OVER the page (doesn't shrink it).
            if showSidebar {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    AgentSidebarView(
                        vm: vm,
                        onClose: { withAnimation { showSidebar = false } },
                        onEditKey: { withAnimation { showKeyPopup = true } }
                    )
                }
                .transition(.move(edge: .trailing))
                .zIndex(5)
            }

            if vm.isArrangingImages {
                arrangeControls.zIndex(6)
            }

            VStack {
                Spacer()
                NotebookToolbar(
                    vm: vm,
                    isPageLocked: $isPageLocked,
                    isLassoActive: $vm.isLassoActive,
                    onHome: { vm.persistNow(); dismiss() },
                    onShowPages: { withAnimation { showPages = true } },
                    onExportPDF: { showPDFOptions = true },
                    onExportArchive: prepareSPUDExport
                )
                .padding(.bottom, 14)
                .padding(.trailing, showSidebar ? 348 : 0)
                .popover(isPresented: $showPDFOptions) {
                    pdfOptions
                        .presentationCompactAdaptation(.popover)
                }
            }

            if showPages {
                PageFlipOverlay(vm: vm) { withAnimation { showPages = false } }
                    .transition(.opacity)
            }

            if showKeyPopup {
                APIKeyPopup { withAnimation { showKeyPopup = false } }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10)
            }
        }
        .navigationTitle(vm.notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { vm.persistNow(); dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Back to notebooks")
                .accessibilityIdentifier("notebook-back")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { withAnimation { showStrip.toggle() } } label: {
                    Image(systemName: showStrip ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2")
                }
                .accessibilityIdentifier("nav-page-strip")

                templateMenu

                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.badge.plus")
                }
                .accessibilityIdentifier("nav-add-image")
                .accessibilityLabel("Add image")

                Button { withAnimation { showSidebar.toggle() } } label: {
                    Image(systemName: showSidebar ? "sparkles.rectangle.stack.fill" : "sparkles")
                }
                .accessibilityIdentifier("nav-assistant")
            }
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
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    vm.addImage(data: data, aspect: image.size.width / max(image.size.height, 1))
                }
                pickerItem = nil
            }
        }
        .onDisappear { vm.persistNow() }
    }

    private var templateMenu: some View {
        Menu {
            Picker("Template", selection: Binding(get: { vm.currentTemplate }, set: { vm.setTemplate($0) })) {
                ForEach(PageTemplate.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Toggle("Snap to straight line", isOn: $snapStraight)
            Toggle("Finger drawing", isOn: $fingerDrawing)
            Divider()
            Button("Zoom out", systemImage: "minus.magnifyingglass") { vm.zoomOut() }
                .disabled(vm.zoomScale <= 0.5)
            Button("Reset zoom (\(vm.zoomLabel))", systemImage: "1.magnifyingglass") { vm.resetZoom() }
            Button("Zoom in", systemImage: "plus.magnifyingglass") { vm.zoomIn() }
                .disabled(vm.zoomScale >= 5)
            if !vm.currentPage.images.isEmpty {
                Button(vm.isArrangingImages ? "Finish arranging images" : "Arrange images") {
                    withAnimation { vm.toggleArrangeImages() }
                }
            }
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .accessibilityIdentifier("nav-template")
    }

    private var arrangeControls: some View {
        VStack {
            HStack(spacing: 10) {
                Label("Move & pinch to resize", systemImage: "hand.draw")
                    .font(.footnote.weight(.medium))
                Divider().frame(height: 18)
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

    private var pdfOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("PDF Compression")
                .font(.headline)

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
            .accessibilityIdentifier("pdf-export-confirm")
        }
        .padding(20)
        .frame(width: 330)
    }

    private func preparePDFExport() {
        vm.persistNow()
        exportDocument = NotebookExportDocument(data: NotePDFExporter.makePDF(
            from: vm.currentPage.drawing,
            pageBounds: CGRect(origin: .zero, size: NotebookPageLayout.size),
            tolerance: CGFloat(pdfTolerance)
        ).data)
        exportContentType = .pdf
        showPDFOptions = false
        // Presenting the file exporter while the compression popover is still
        // dismissing can cause SwiftUI to discard the second presentation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showFileExporter = true
        }
    }

    private func prepareSPUDExport() {
        vm.persistNow()
        do {
            exportDocument = NotebookExportDocument(data: try TuberNoteArchiveCodec.encode(
                inkLayers: vm.currentPage.drawingLayers.map { layer in
                    TuberNoteArchiveCodec.InkLayerInput(
                        id: layer.id,
                        name: layer.name,
                        isVisible: layer.isVisible,
                        drawing: layer.drawing
                    )
                },
                canvasSize: NotebookPageLayout.size,
                conversationLayers: vm.conversationLayers
            ))
            exportContentType = .tuberNoteArchive
            showFileExporter = true
        } catch {
            exportError = error.localizedDescription
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
        return "\(title)-page-\(vm.currentIndex + 1).\(fileExtension)"
    }

    private func handleExportCompletion(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            exportError = error.localizedDescription
        }
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }

    private var pageArea: some View {
        NotebookCanvas(
            pageID: vm.currentDrawingLayerID,
            drawingData: vm.currentDrawingLayer.drawingData,
            backgroundDrawingData: vm.backgroundDrawingData,
            tool: vm.tool,
            color: vm.inkUIColor,
            width: vm.activeWidth,
            template: vm.currentTemplate,
            zoomScale: vm.zoomScale,
            fingerDrawing: fingerDrawing,
            isLassoActive: vm.isLassoActive,
            lassoRect: vm.lassoRect,
            snapStraight: snapStraight,
            images: vm.currentPage.images,
            isArrangingImages: vm.isArrangingImages,
            selectedImageID: vm.selectedImageID,
            isPageLocked: isPageLocked,
            onChange: { vm.updateCurrentDrawing($0) },
            onLongPress: { withAnimation { showPages = true } },
            onZoomChanged: { vm.zoomScale = $0 },
            onLassoChanged: { vm.lassoRect = $0 },
            onImagesChanged: { vm.updateImages($0) },
            onSelectImage: { vm.selectImage($0) },
            onPageViewportChange: { pageViewportFrame = $0 }
        )
        .background(alignment: .topLeading) {
            AgenticModeGlow(isActive: vm.isAgenticLayersActive)
                .frame(width: pageViewportFrame.width, height: pageViewportFrame.height)
                .position(x: pageViewportFrame.midX, y: pageViewportFrame.midY)
        }
        .clipped()
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 74) // room for the floating toolbar
        // New identity per page → clean canvas + page-turn transition.
        .id(vm.currentDrawingLayerID)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        ))
        .accessibilityIdentifier("notebook-page-area")
    }
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
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
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

private extension UTType {
    static let tuberNoteArchive = UTType(
        exportedAs: TuberNoteArchive.formatIdentifier,
        conformingTo: .json
    )
}
