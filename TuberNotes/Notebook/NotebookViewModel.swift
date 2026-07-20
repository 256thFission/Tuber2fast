import Combine
import Foundation
import PencilKit
import SwiftUI
import UIKit

enum NotebookPageTurnDirection {
    case forward
    case backward
}

@MainActor
final class NotebookViewModel: ObservableObject {
    @Published var notebook: Notebook
    @Published var currentIndex: Int = 0
    @Published private(set) var pageTurnDirection: NotebookPageTurnDirection = .forward

    // Undo/redo follows the active drawing layer across canvas reconstruction.
    let undo = NotebookUndoBridge()

    // Tool state
    @Published private(set) var tool: WritingTool = .pen
    @Published private(set) var previousTool: WritingTool = .pen
    @Published var inkColorHex: String = InkPalette.default
    @Published var penWidth: CGFloat = WritingTool.pen.defaultWidth
    @Published var pencilWidth: CGFloat = WritingTool.pencil.defaultWidth
    @Published var markerWidth: CGFloat = WritingTool.marker.defaultWidth
    @Published var eraserWidth: CGFloat = WritingTool.eraser.defaultWidth

    // Lasso selection and stroke movement
    @Published var isLassoActive = false
    @Published var lassoRect: CGRect?   // normalized (0...1) page-space rect

    // Image placement
    @Published var isArrangingImages = false
    @Published var selectedImageID: UUID?

    // Zoom + template
    @Published var zoomScale: CGFloat = 1
    @Published var lastTemplate: PageTemplate = .linedMedium

    // Toolbar settings (mirrored to notebook.settings on save)
    @Published var settings: NotebookSettings

    // Layers (agentic conversation layers + per-page drawing layers)
    @Published var isAgenticLayersActive = false
    @Published var selectedLayerID: UUID?        // selected agentic layer
    @Published var currentDrawingLayerID: UUID   // active drawing layer on the current page

    // Export
    @Published var exportError: String?

    // Agentic Layer questions
    @Published var isAnalyzing = false
    @Published var agentError: String?
    @Published private(set) var newestAgentThreadID: UUID?

    private let store: NotebookStore
    private var saveTask: Task<Void, Never>?

    init(notebook: Notebook, store: NotebookStore) {
        self.notebook = notebook
        self.store = store
        self.lastTemplate = notebook.pages.first?.template ?? .linedMedium
        self.settings = notebook.settings ?? NotebookSettings()
        self.selectedLayerID = notebook.agenticLayers.first?.id
        self.currentDrawingLayerID = notebook.pages[0].drawingLayers[0].id
    }

    // MARK: Derived

    var pageCount: Int { notebook.pages.count }
    var currentPage: NotebookPage { notebook.pages[safe: currentIndex] ?? notebook.pages[0] }
    var currentPageID: UUID { currentPage.id }
    var currentTemplate: PageTemplate { currentPage.template }
    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex < notebook.pages.count - 1 }
    var pageLabel: String { "\(currentIndex + 1) / \(pageCount)" }
    var currentDrawingLayer: DrawingLayer {
        currentPage.drawingLayers.first { $0.id == currentDrawingLayerID }
            ?? currentPage.drawingLayers[0]
    }
    var backgroundDrawingData: Data {
        let strokes = currentPage.drawingLayers
            .filter { $0.isVisible && $0.id != currentDrawingLayerID }
            .flatMap { $0.drawing.strokes }
        return PKDrawing(strokes: strokes).dataRepresentation()
    }
    var activeAgenticPins: [Pin] {
        guard isAgenticLayersActive,
              let layer = notebook.agenticLayers.first(where: {
                  $0.id == selectedLayerID && $0.isVisible
              })
        else { return [] }
        return layer.conversations.filter { $0.pageID == currentPageID }
    }

    // MARK: Tool state

    var inkUIColor: UIColor { UIColor(hex: inkColorHex) ?? .label }
    var inkColor: Color { Color(inkUIColor) }

    func selectColor(_ hex: String) {
        inkColorHex = hex
        if tool == .eraser { setActiveTool(.pen) }
        isLassoActive = false
        isArrangingImages = false
    }

    func selectTool(_ newTool: WritingTool) {
        setActiveTool(newTool)
        clearCompetingToolModes()
    }

    /// Follows the system's "Switch between current tool and eraser" action.
    func togglePencilEraser() {
        if tool == .eraser {
            let restoredTool = previousTool == .eraser ? WritingTool.pen : previousTool
            previousTool = .eraser
            tool = restoredTool
        } else {
            previousTool = tool
            tool = .eraser
        }
        clearCompetingToolModes()
    }

    /// Follows the system's "Switch between current tool and last used" action.
    func swapToPreviousTool() {
        guard previousTool != tool else { return }
        let currentTool = tool
        tool = previousTool
        previousTool = currentTool
        clearCompetingToolModes()
    }

    private func setActiveTool(_ newTool: WritingTool) {
        guard newTool != tool else { return }
        previousTool = tool
        tool = newTool
    }

    private func clearCompetingToolModes() {
        isLassoActive = false
        isArrangingImages = false
        isAgenticLayersActive = false
    }

    func toggleLasso() {
        isLassoActive.toggle()
        if isLassoActive {
            isArrangingImages = false
            isAgenticLayersActive = false
        }
    }
    func clearLasso() { lassoRect = nil }

    // MARK: Images

    func addImage(data: Data, aspect: CGFloat) {
        guard notebook.pages.indices.contains(currentIndex) else { return }
        let normWidth: CGFloat = 0.6
        let page = NotebookPageLayout.size
        let pxWidth = normWidth * page.width
        let pxHeight = pxWidth / max(aspect, 0.05)
        let normHeight = min(pxHeight / page.height, 0.85)
        let rect = CGRect(x: (1 - normWidth) / 2, y: max(0.05, (1 - normHeight) / 2),
                          width: normWidth, height: normHeight)
        let placed = PlacedImage(imageData: data, rect: rect)
        notebook.pages[currentIndex].images.append(placed)
        selectedImageID = placed.id
        isArrangingImages = true
        isLassoActive = false
        persistNow()
    }

    func updateImages(_ images: [PlacedImage]) {
        guard notebook.pages.indices.contains(currentIndex) else { return }
        notebook.pages[currentIndex].images = images
        scheduleSave()
    }

    func selectImage(_ id: UUID?) { selectedImageID = id }

    func deleteSelectedImage() {
        guard notebook.pages.indices.contains(currentIndex), let id = selectedImageID else { return }
        notebook.pages[currentIndex].images.removeAll { $0.id == id }
        selectedImageID = nil
        persistNow()
    }

    func toggleArrangeImages() {
        isArrangingImages.toggle()
        if isArrangingImages { isLassoActive = false } else { selectedImageID = nil }
    }

    func finishArrangingImages() {
        isArrangingImages = false
        selectedImageID = nil
    }

    var activeWidth: CGFloat {
        get {
            switch tool {
            case .pen:    penWidth
            case .pencil: pencilWidth
            case .marker: markerWidth
            case .eraser: eraserWidth
            }
        }
        set {
            switch tool {
            case .pen:    penWidth = newValue
            case .pencil: pencilWidth = newValue
            case .marker: markerWidth = newValue
            case .eraser: eraserWidth = newValue
            }
        }
    }

    var widthRange: ClosedRange<CGFloat> { tool.widthRange }

    /// Per-tool width read/write (used by the toolbar's press-and-slide sizing).
    func width(for tool: WritingTool) -> CGFloat {
        switch tool {
        case .pen:    penWidth
        case .pencil: pencilWidth
        case .marker: markerWidth
        case .eraser: eraserWidth
        }
    }

    func setWidth(_ value: CGFloat, for tool: WritingTool) {
        let clamped = min(max(value, tool.widthRange.lowerBound), tool.widthRange.upperBound)
        switch tool {
        case .pen:    penWidth = clamped
        case .pencil: pencilWidth = clamped
        case .marker: markerWidth = clamped
        case .eraser: eraserWidth = clamped
        }
    }

    // MARK: Favorite colors (stored in settings)

    func isFavoriteColor(_ hex: String) -> Bool {
        settings.favoriteColors.contains { $0.caseInsensitiveCompare(hex) == .orderedSame }
    }

    func toggleFavoriteColor(_ hex: String) {
        if let idx = settings.favoriteColors.firstIndex(where: { $0.caseInsensitiveCompare(hex) == .orderedSame }) {
            settings.favoriteColors.remove(at: idx)
        } else {
            settings.favoriteColors.append(hex)
        }
        persistNow()
    }

    // MARK: Layers

    /// Agentic conversation layers, wrapped for the toolbar's layer popover.
    var conversationLayers: NoteConversationLayers {
        get { NoteConversationLayers(noteID: notebook.id, layers: notebook.agenticLayers) }
        set { notebook.agenticLayers = newValue.layers }
    }

    func selectAgenticLayer(_ id: UUID) {
        guard let index = notebook.agenticLayers.firstIndex(where: { $0.id == id }) else { return }
        let restoredVisibility = !notebook.agenticLayers[index].isVisible
        notebook.agenticLayers[index].isVisible = true
        selectedLayerID = id
        isAgenticLayersActive = true
        isLassoActive = false
        isArrangingImages = false
        if restoredVisibility { persistNow() }
    }

    func addAgenticLayer(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let layer = ConversationLayer(
            id: UUID(),
            name: name.isEmpty ? "Layer \(notebook.agenticLayers.count + 1)" : name,
            symbolName: "sparkles",
            conversations: []
        )
        notebook.agenticLayers.append(layer)
        selectedLayerID = layer.id
        isAgenticLayersActive = true
        persistNow()
    }

    func toggleAgenticLayerActivation(_ id: UUID) {
        guard let index = notebook.agenticLayers.firstIndex(where: { $0.id == id }) else { return }
        let isActive = isAgenticLayersActive
            && selectedLayerID == id
            && notebook.agenticLayers[index].isVisible

        if isActive {
            notebook.agenticLayers[index].isVisible = false
            isAgenticLayersActive = false
        } else {
            notebook.agenticLayers[index].isVisible = true
            selectedLayerID = id
            isAgenticLayersActive = true
            isLassoActive = false
            isArrangingImages = false
        }
        persistNow()
    }

    func moveAgenticPin(_ id: UUID, to target: PageNormalizedPoint) {
        guard target.isFiniteAndInUnitBounds else { return }
        for layerIndex in notebook.agenticLayers.indices {
            guard let pinIndex = notebook.agenticLayers[layerIndex].conversations.firstIndex(where: {
                $0.id == id && $0.pageID == currentPageID
            }) else { continue }
            guard notebook.agenticLayers[layerIndex].conversations[pinIndex].target != target else { return }
            notebook.agenticLayers[layerIndex].conversations[pinIndex].target = target
            persistNow()
            return
        }
    }

    func selectDrawingLayer(_ id: UUID) {
        guard currentPage.drawingLayers.contains(where: { $0.id == id }) else { return }
        currentDrawingLayerID = id
        isAgenticLayersActive = false
    }

    func addDrawingLayer(named rawName: String) {
        guard notebook.pages.indices.contains(currentIndex) else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = notebook.pages[currentIndex].drawingLayers.count
        let layer = DrawingLayer(name: name.isEmpty ? "Drawing \(count + 1)" : name)
        notebook.pages[currentIndex].drawingLayers.append(layer)
        currentDrawingLayerID = layer.id
        isAgenticLayersActive = false
        persistNow()
    }

    func toggleDrawingLayerVisibility(_ id: UUID) {
        guard notebook.pages.indices.contains(currentIndex),
              let idx = notebook.pages[currentIndex].drawingLayers.firstIndex(where: { $0.id == id })
        else { return }
        notebook.pages[currentIndex].drawingLayers[idx].isVisible.toggle()
        if !notebook.pages[currentIndex].drawingLayers[idx].isVisible, currentDrawingLayerID == id {
            if let replacement = notebook.pages[currentIndex].drawingLayers.first(where: \.isVisible) {
                currentDrawingLayerID = replacement.id
            } else {
                notebook.pages[currentIndex].drawingLayers[idx].isVisible = true
            }
        }
        persistNow()
    }

    // MARK: Export

    /// Vector PDF of the current page's ink.
    func exportPDF() -> Data? {
        let pageRect = CGRect(origin: .zero, size: NotebookPageLayout.size)
        let result = NotePDFExporter.makePDF(from: currentPage.drawing, pageBounds: pageRect)
        return result.data
    }

    /// SPUD archive (ink layers + conversation layers) for the whole note's current page.
    func exportArchive() -> Data? {
        let inkLayers = currentPage.drawingLayers.map {
            TuberNoteArchiveCodec.InkLayerInput(
                id: $0.id, name: $0.name, isVisible: $0.isVisible, drawing: $0.drawing
            )
        }
        do {
            return try TuberNoteArchiveCodec.encode(
                inkLayers: inkLayers,
                canvasSize: NotebookPageLayout.size,
                conversationLayers: conversationLayers
            )
        } catch {
            exportError = error.localizedDescription
            return nil
        }
    }

    // MARK: Zoom

    func setZoom(_ value: CGFloat) { zoomScale = min(max(value, 0.5), 5) }
    func zoomIn()  { setZoom(zoomScale + 0.25) }
    func zoomOut() { setZoom(zoomScale - 0.25) }
    func resetZoom() { setZoom(1) }
    var zoomLabel: String { "\(Int((zoomScale * 100).rounded()))%" }

    // MARK: Templates

    func setTemplate(_ template: PageTemplate) {
        guard notebook.pages.indices.contains(currentIndex) else { return }
        notebook.pages[currentIndex].template = template
        lastTemplate = template
        persistNow()
    }

    // MARK: Drawing

    func updateCurrentDrawing(_ data: Data) {
        guard notebook.pages.indices.contains(currentIndex),
              let layerIndex = notebook.pages[currentIndex].drawingLayers.firstIndex(where: {
                  $0.id == currentDrawingLayerID
              })
        else { return }
        guard notebook.pages[currentIndex].drawingLayers[layerIndex].drawingData != data else { return }
        notebook.pages[currentIndex].drawingLayers[layerIndex].drawingData = data
        scheduleSave()
    }

    /// Commits a raster refinement into the page and removes source strokes
    /// intersecting the refined region. Refinement is document state, never an
    /// Agentic Layer or Pin.
    func applyDrawingRefinement(imageData: Data, normalizedRect: CGRect) {
        guard notebook.pages.indices.contains(currentIndex),
              let layerIndex = notebook.pages[currentIndex].drawingLayers.firstIndex(where: {
                  $0.id == currentDrawingLayerID
              })
        else { return }

        let pageSize = NotebookPageLayout.size
        let pageRect = CGRect(
            x: normalizedRect.minX * pageSize.width,
            y: normalizedRect.minY * pageSize.height,
            width: normalizedRect.width * pageSize.width,
            height: normalizedRect.height * pageSize.height
        )
        var drawing = notebook.pages[currentIndex].drawingLayers[layerIndex].drawing
        drawing.strokes = drawing.strokes.filter { !$0.renderBounds.intersects(pageRect) }
        notebook.pages[currentIndex].drawingLayers[layerIndex].drawingData = drawing.dataRepresentation()
        notebook.pages[currentIndex].images.append(
            PlacedImage(imageData: imageData, rect: normalizedRect)
        )
        lassoRect = nil
        persistNow()
    }

    // MARK: Pages

    func addPage() {
        let insertAt = min(currentIndex + 1, notebook.pages.count)
        pageTurnDirection = .forward
        notebook.pages.insert(NotebookPage(template: lastTemplate), at: insertAt)
        currentIndex = insertAt
        selectFirstDrawingLayerForCurrentPage()
        resetZoom()
        persistNow()
    }

    func deleteCurrentPage() {
        guard notebook.pages.count > 1 else { return }
        pageTurnDirection = currentIndex < notebook.pages.count - 1 ? .forward : .backward
        notebook.pages.remove(at: currentIndex)
        currentIndex = min(currentIndex, notebook.pages.count - 1)
        selectFirstDrawingLayerForCurrentPage()
        resetZoom()
        persistNow()
    }

    /// Delete a page by index, keeping the currently-viewed page in view.
    func deletePage(at index: Int) {
        guard notebook.pages.count > 1, notebook.pages.indices.contains(index) else { return }
        let currentID = currentPageID
        if index == currentIndex {
            pageTurnDirection = index < notebook.pages.count - 1 ? .forward : .backward
        }
        notebook.pages.remove(at: index)
        if let idx = notebook.pages.firstIndex(where: { $0.id == currentID }) {
            currentIndex = idx
        } else {
            currentIndex = min(index, notebook.pages.count - 1)
            resetZoom()
        }
        selectFirstDrawingLayerForCurrentPage()
        persistNow()
    }

    /// Reorder a page, keeping the currently-viewed page in view.
    func movePage(from: Int, to: Int) {
        guard notebook.pages.indices.contains(from) else { return }
        let target = max(0, min(to, notebook.pages.count - 1))
        guard target != from else { return }
        let currentID = currentPageID
        let page = notebook.pages.remove(at: from)
        notebook.pages.insert(page, at: target)
        if let idx = notebook.pages.firstIndex(where: { $0.id == currentID }) {
            currentIndex = idx
        }
        persistNow()
    }

    func go(to index: Int) {
        guard notebook.pages.indices.contains(index) else { return }
        if index != currentIndex {
            pageTurnDirection = index > currentIndex ? .forward : .backward
        }
        currentIndex = index
        selectFirstDrawingLayerForCurrentPage()
        resetZoom()
        persistNow()
    }

    func goForward() {
        guard canGoForward else { return }
        pageTurnDirection = .forward
        currentIndex += 1
        selectFirstDrawingLayerForCurrentPage()
        resetZoom()
        persistNow()
    }

    func goBack() {
        guard canGoBack else { return }
        pageTurnDirection = .backward
        currentIndex -= 1
        selectFirstDrawingLayerForCurrentPage()
        resetZoom()
        persistNow()
    }

    private func selectFirstDrawingLayerForCurrentPage() {
        currentDrawingLayerID = currentPage.drawingLayers[0].id
        lassoRect = nil
    }

    // MARK: Agentic Layer questions

    /// Render the current page as a canonical selection artifact. A live lasso
    /// wins; otherwise a conversation branch can reuse its parent's persisted region.
    func makeSelectionSnapshot(preferredBounds: PageNormalizedRect? = nil) -> SelectionArtifact? {
        let drawing = currentPage.drawing
        let images = currentPage.images
        guard !drawing.bounds.isNull || !images.isEmpty else { return nil }

        let pageRect = CGRect(origin: .zero, size: NotebookPageLayout.size)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: pageRect.size, format: format)
        let full = renderer.image { context in
            UIColor.white.setFill()
            context.fill(pageRect)
            for placed in images {
                guard let image = placed.image else { continue }
                let rect = CGRect(
                    x: placed.rect.minX * pageRect.width,
                    y: placed.rect.minY * pageRect.height,
                    width: placed.rect.width * pageRect.width,
                    height: placed.rect.height * pageRect.height
                )
                image.draw(in: rect)
            }
            drawing.image(from: pageRect, scale: 1).draw(in: pageRect)
        }

        let inheritedBounds = preferredBounds.flatMap { bounds -> CGRect? in
            guard bounds.isFiniteAndInUnitBounds else { return nil }
            return CGRect(
                x: CGFloat(bounds.x),
                y: CGFloat(bounds.y),
                width: CGFloat(bounds.width),
                height: CGFloat(bounds.height)
            )
        }
        let usesFocusedCrop = lassoRect != nil || inheritedBounds != nil
        var normalized = lassoRect ?? inheritedBounds ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        normalized = normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        var output = full
        if usesFocusedCrop {
            let cropRect = CGRect(
                x: normalized.minX * pageRect.width,
                y: normalized.minY * pageRect.height,
                width: normalized.width * pageRect.width,
                height: normalized.height * pageRect.height
            ).insetBy(dx: -14, dy: -14).intersection(pageRect).integral
            if cropRect.width > 10,
               cropRect.height > 10,
               let image = full.cgImage?.cropping(to: cropRect) {
                output = UIImage(cgImage: image)
            }
        }

        guard let data = output.jpegData(compressionQuality: 0.8) else { return nil }
        let pageBounds = PageNormalizedRect(
            x: Double(normalized.minX),
            y: Double(normalized.minY),
            width: Double(normalized.width),
            height: Double(normalized.height)
        )
        let corners = [
            PageNormalizedPoint(x: Double(normalized.minX), y: Double(normalized.minY)),
            PageNormalizedPoint(x: Double(normalized.maxX), y: Double(normalized.minY)),
            PageNormalizedPoint(x: Double(normalized.maxX), y: Double(normalized.maxY)),
            PageNormalizedPoint(x: Double(normalized.minX), y: Double(normalized.maxY)),
        ]
        return SelectionArtifact(
            id: UUID(),
            documentID: notebook.id,
            pageID: currentPageID,
            pageIndex: currentIndex,
            lassoPath: corners,
            pageBounds: pageBounds,
            crop: SelectionCrop(
                imageData: data,
                mediaType: "image/jpeg",
                pixelWidth: Int(output.size.width),
                pixelHeight: Int(output.size.height),
                pageBounds: pageBounds
            ),
            context: SelectionContext(
                documentTitle: notebook.title,
                sourceDocumentID: notebook.id,
                pageNumber: currentIndex + 1,
                nearbyText: nil
            )
        )
    }

    func analyzeCurrentPage(
        providerAccess: AgentProviderAccess?,
        question: String? = nil,
        parentThreadID: UUID? = nil
    ) {
        guard !isAnalyzing else { return }
        guard isAgenticLayersActive,
              let layerIndex = notebook.agenticLayers.firstIndex(where: {
                  $0.id == selectedLayerID && $0.isVisible
              })
        else {
            agentError = "Choose a visible Agentic Layer first."
            return
        }
        let layerID = notebook.agenticLayers[layerIndex].id
        let parentPin = parentThreadID.flatMap { threadID in
            notebook.agenticLayers[layerIndex].conversations.first(where: { $0.threadID == threadID })
        }
        if parentThreadID != nil, parentPin == nil {
            agentError = "That conversation branch is no longer available on this layer."
            return
        }
        if let parentPin, parentPin.pageID != currentPageID {
            agentError = "Open the parent Pin's page before continuing this branch."
            return
        }
        guard let selection = makeSelectionSnapshot(preferredBounds: parentPin?.targetRegion) else {
            agentError = "Draw or add something first, then ask about it."
            return
        }

        let trimmedQuestion = question?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let submittedQuestion = branchQuestion(trimmedQuestion, parent: parentPin)
        let childThreadID = UUID()
        isAnalyzing = true
        agentError = nil
        let client = AgentInsightClientFactory.make(access: providerAccess)

        Task { [weak self] in
            guard let self else { return }
            do {
                let insight = try await client.analyze(selection, question: submittedQuestion)
                guard let destinationLayerIndex = notebook.agenticLayers.firstIndex(where: {
                    $0.id == layerID
                }) else {
                    agentError = "That Agentic Layer was removed before the response completed."
                    isAnalyzing = false
                    return
                }
                let target = branchTarget(
                    parent: parentPin,
                    in: notebook.agenticLayers[destinationLayerIndex].conversations,
                    fallback: PageNormalizedPoint(
                        x: selection.pageBounds.x + selection.pageBounds.width / 2,
                        y: selection.pageBounds.y + selection.pageBounds.height / 2
                    )
                )
                let body = ([insight.summary] + insight.items.map { "• \($0)" })
                    .joined(separator: "\n")
                notebook.agenticLayers[destinationLayerIndex].conversations.append(
                    PageAnnotation(
                        id: UUID(),
                        pageID: selection.pageID,
                        threadID: childThreadID,
                        parentThreadID: parentPin?.threadID,
                        target: target,
                        targetRegion: selection.pageBounds,
                        kind: .explanation,
                        teaser: trimmedQuestion
                            ?? (parentPin == nil ? "Agent insight" : "Follow-up branch"),
                        body: body,
                        citations: [],
                        status: .complete
                    )
                )
                newestAgentThreadID = childThreadID
                isAnalyzing = false
                persistNow()
            } catch {
                agentError = error.localizedDescription
                isAnalyzing = false
            }
        }
    }

    private func branchQuestion(_ question: String?, parent: PageAnnotation?) -> String? {
        guard let parent else { return question }
        let followUp = question ?? "Explain this further."
        let boundedAnswer = String(parent.body.prefix(2_000))
        return """
        Continue this notebook conversation as a branch from the selected Pin.
        Parent prompt: \(parent.teaser)
        Parent answer: \(boundedAnswer)
        Follow-up: \(followUp)
        """
    }

    private func branchTarget(
        parent: PageAnnotation?,
        in conversations: [PageAnnotation],
        fallback: PageNormalizedPoint
    ) -> PageNormalizedPoint {
        guard let parent else { return fallback }
        let siblingCount = conversations.filter { $0.parentThreadID == parent.threadID }.count
        let offsets: [(Double, Double)] = [
            (0.055, 0.035),
            (-0.055, 0.035),
            (0.055, -0.035),
            (-0.055, -0.035),
        ]
        let offset = offsets[siblingCount % offsets.count]
        return PageNormalizedPoint(
            x: min(max(parent.target.x + offset.0, 0.035), 0.965),
            y: min(max(parent.target.y + offset.1, 0.035), 0.965)
        )
    }

    // MARK: Persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.notebook.settings = self.settings
            self.store.save(self.notebook)
        }
    }

    func persistNow() {
        saveTask?.cancel()
        notebook.settings = settings
        store.save(notebook)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
