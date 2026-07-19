import Combine
import Foundation
import PencilKit
import SwiftUI
import UIKit

struct AgentObservation: Identifiable {
    let id = UUID()
    let summary: String
    let items: [String]
    let thumbnail: UIImage?
    let date: Date
}

@MainActor
final class NotebookViewModel: ObservableObject {
    @Published var notebook: Notebook
    @Published var currentIndex: Int = 0 {
        didSet { selectFirstDrawingLayer() }
    }

    @Published var tool: WritingTool = .pen
    @Published var inkColorHex: String = InkPalette.default

    // Independent widths per tool so pen and highlighter keep their own size.
    @Published var penWidth: CGFloat = WritingTool.pen.defaultWidth
    @Published var pencilWidth: CGFloat = WritingTool.pencil.defaultWidth
    @Published var markerWidth: CGFloat = WritingTool.marker.defaultWidth
    @Published var eraserWidth: CGFloat = WritingTool.eraser.defaultWidth

    // Spatial selection, image placement, and page presentation.
    @Published var isLassoActive = false
    @Published var lassoRect: CGRect?
    @Published var isArrangingImages = false
    @Published var selectedImageID: UUID?
    @Published var zoomScale: CGFloat = 1
    @Published var lastTemplate: PageTemplate = .linedMedium

    // Assistant output remains separate from persistent conversation layers.
    @Published var observations: [AgentObservation] = []
    @Published var isAnalyzing = false
    @Published var agentError: String?

    @Published var conversationLayers: NoteConversationLayers {
        didSet {
            guard oldValue != conversationLayers else { return }
            notebook.agenticLayers = conversationLayers.layers
            scheduleSave()
        }
    }
    @Published var selectedLayerID: UUID?
    @Published var selectedDrawingLayerID: UUID?
    @Published var isAgenticLayersActive = false
    @Published var settings: NotebookSettings {
        didSet {
            guard oldValue != settings else { return }
            notebook.settings = settings
            scheduleSave()
        }
    }

    private let store: NotebookStore
    private var saveTask: Task<Void, Never>?

    init(notebook: Notebook, store: NotebookStore) {
        let layers = notebook.agenticLayers
        self.notebook = notebook
        self.store = store
        conversationLayers = NoteConversationLayers(noteID: notebook.id, layers: layers)
        selectedLayerID = layers.first?.id
        selectedDrawingLayerID = notebook.pages.first?.drawingLayers.first?.id
        settings = notebook.settings ?? NotebookSettings()
        lastTemplate = notebook.pages.first?.template ?? .linedMedium
    }

    // MARK: Derived

    var pageCount: Int { notebook.pages.count }
    var currentPage: NotebookPage { notebook.pages[safe: currentIndex] ?? notebook.pages[0] }
    var currentPageID: UUID { currentPage.id }
    var currentTemplate: PageTemplate { currentPage.template }
    var currentDrawingLayerID: UUID { currentDrawingLayer.id }
    var currentDrawingLayer: DrawingLayer {
        currentPage.drawingLayers.first { $0.id == selectedDrawingLayerID }
            ?? currentPage.drawingLayers[0]
    }
    var backgroundDrawingData: Data {
        let strokes = currentPage.drawingLayers
            .filter { $0.isVisible && $0.id != currentDrawingLayerID }
            .flatMap { $0.drawing.strokes }
        return PKDrawing(strokes: strokes).dataRepresentation()
    }
    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex < notebook.pages.count - 1 }
    var pageLabel: String { "\(currentIndex + 1) / \(pageCount)" }

    // MARK: Tool state

    var inkUIColor: UIColor { UIColor(hex: inkColorHex) ?? .black }
    var inkColor: Color { Color(inkUIColor) }

    func selectColor(_ hex: String) {
        inkColorHex = hex
        if tool == .eraser { tool = .pen }
        isLassoActive = false
        isArrangingImages = false
    }

    func selectTool(_ newTool: WritingTool) {
        tool = newTool
        isLassoActive = false
        isArrangingImages = false
    }

    func toggleLasso() {
        isLassoActive.toggle()
        if isLassoActive { isArrangingImages = false }
    }

    func clearLasso() { lassoRect = nil }

    func toggleFavoriteColor(_ hex: String) {
        var updated = settings
        if let index = updated.favoriteColors.firstIndex(where: {
            $0.caseInsensitiveCompare(hex) == .orderedSame
        }) {
            updated.favoriteColors.remove(at: index)
        } else {
            updated.favoriteColors.append(hex.uppercased())
        }
        settings = updated
    }

    func isFavoriteColor(_ hex: String) -> Bool {
        settings.favoriteColors.contains {
            $0.caseInsensitiveCompare(hex) == .orderedSame
        }
    }

    /// The width for whichever tool is active (bindable from the size popover).
    var activeWidth: CGFloat {
        get { width(for: tool) }
        set { setWidth(newValue, for: tool) }
    }

    var widthRange: ClosedRange<CGFloat> { tool.widthRange }

    func width(for tool: WritingTool) -> CGFloat {
        switch tool {
        case .pen:    penWidth
        case .pencil: pencilWidth
        case .marker: markerWidth
        case .eraser: eraserWidth
        }
    }

    func setWidth(_ width: CGFloat, for tool: WritingTool) {
        let clamped = min(max(width, tool.widthRange.lowerBound), tool.widthRange.upperBound)
        switch tool {
        case .pen:    penWidth = clamped
        case .pencil: pencilWidth = clamped
        case .marker: markerWidth = clamped
        case .eraser: eraserWidth = clamped
        }
    }

    // MARK: Images and page presentation

    func addImage(data: Data, aspect: CGFloat) {
        guard notebook.pages.indices.contains(currentIndex) else { return }
        let normalizedWidth: CGFloat = 0.6
        let page = NotebookPageLayout.size
        let pointWidth = normalizedWidth * page.width
        let normalizedHeight = min((pointWidth / max(aspect, 0.05)) / page.height, 0.85)
        let rect = CGRect(
            x: (1 - normalizedWidth) / 2,
            y: max(0.05, (1 - normalizedHeight) / 2),
            width: normalizedWidth,
            height: normalizedHeight
        )
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

    func setZoom(_ value: CGFloat) { zoomScale = min(max(value, 0.5), 5) }
    func zoomIn() { setZoom(zoomScale + 0.25) }
    func zoomOut() { setZoom(zoomScale - 0.25) }
    func resetZoom() { setZoom(1) }
    var zoomLabel: String { "\(Int((zoomScale * 100).rounded()))%" }

    func setTemplate(_ template: PageTemplate) {
        guard notebook.pages.indices.contains(currentIndex) else { return }
        notebook.pages[currentIndex].template = template
        lastTemplate = template
        persistNow()
    }

    // MARK: Drawing

    func updateCurrentDrawing(_ data: Data) {
        guard notebook.pages.indices.contains(currentIndex) else { return }
        guard let layerIndex = notebook.pages[currentIndex].drawingLayers.firstIndex(where: {
            $0.id == currentDrawingLayerID
        }) else { return }
        guard notebook.pages[currentIndex].drawingLayers[layerIndex].drawingData != data else { return }
        notebook.pages[currentIndex].drawingLayers[layerIndex].drawingData = data
        scheduleSave()
    }

    func addDrawingLayer(named rawName: String) {
        let name = normalizedName(rawName, fallback: "Drawing \(currentPage.drawingLayers.count + 1)")
        let layer = DrawingLayer(name: name)
        notebook.pages[currentIndex].drawingLayers.append(layer)
        selectedDrawingLayerID = layer.id
        scheduleSave()
    }

    func selectDrawingLayer(_ id: UUID) {
        guard currentPage.drawingLayers.contains(where: { $0.id == id && $0.isVisible }) else { return }
        selectedDrawingLayerID = id
    }

    func toggleDrawingLayerVisibility(_ id: UUID) {
        guard let index = notebook.pages[currentIndex].drawingLayers.firstIndex(where: { $0.id == id }) else { return }
        let layer = notebook.pages[currentIndex].drawingLayers[index]
        if layer.isVisible,
           currentPage.drawingLayers.filter(\.isVisible).count == 1 {
            return
        }
        notebook.pages[currentIndex].drawingLayers[index].isVisible.toggle()
        selectFirstDrawingLayer()
        scheduleSave()
    }

    func addAgenticLayer(named rawName: String) {
        let name = normalizedName(rawName, fallback: "Agent \(conversationLayers.layers.count + 1)")
        let layer = ConversationLayer(
            id: UUID(),
            name: name,
            symbolName: "sparkles",
            conversations: []
        )
        conversationLayers.layers.append(layer)
        selectedLayerID = layer.id
    }

    func selectAgenticLayer(_ id: UUID) {
        guard conversationLayers.layers.contains(where: { $0.id == id && $0.isVisible }) else { return }
        selectedLayerID = id
    }

    func toggleAgenticLayerVisibility(_ id: UUID) {
        guard let index = conversationLayers.layers.firstIndex(where: { $0.id == id }) else { return }
        conversationLayers.layers[index].isVisible.toggle()
        if !conversationLayers.layers.contains(where: { $0.id == selectedLayerID && $0.isVisible }) {
            selectedLayerID = conversationLayers.layers.first(where: \.isVisible)?.id
        }
    }

    // MARK: Pages

    func addPage() {
        let insertAt = min(currentIndex + 1, notebook.pages.count)
        notebook.pages.insert(NotebookPage(template: lastTemplate), at: insertAt)
        currentIndex = insertAt
        resetZoom()
        persistNow()
    }

    func deleteCurrentPage() {
        guard notebook.pages.count > 1 else { return }
        notebook.pages.remove(at: currentIndex)
        currentIndex = min(currentIndex, notebook.pages.count - 1)
        resetZoom()
        persistNow()
    }

    func go(to index: Int) {
        guard notebook.pages.indices.contains(index) else { return }
        currentIndex = index
        resetZoom()
        persistNow()
    }

    func goForward() {
        guard canGoForward else { return }
        currentIndex += 1
        resetZoom()
        persistNow()
    }

    func goBack() {
        guard canGoBack else { return }
        currentIndex -= 1
        resetZoom()
        persistNow()
    }

    // MARK: Assistant

    func makeSelectionSnapshot() -> SpatialSelection? {
        let drawing = currentPage.drawing
        let images = currentPage.images
        guard !drawing.bounds.isNull || !images.isEmpty else { return nil }

        let pageRect = CGRect(origin: .zero, size: NotebookPageLayout.size)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let full = UIGraphicsImageRenderer(size: pageRect.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(pageRect)
            for placed in images {
                guard let image = placed.image else { continue }
                image.draw(in: CGRect(
                    x: placed.rect.minX * pageRect.width,
                    y: placed.rect.minY * pageRect.height,
                    width: placed.rect.width * pageRect.width,
                    height: placed.rect.height * pageRect.height
                ))
            }
            drawing.image(from: pageRect, scale: 1).draw(in: pageRect)
        }

        var normalizedBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        var output = full
        if let lassoRect {
            let crop = CGRect(
                x: lassoRect.minX * pageRect.width,
                y: lassoRect.minY * pageRect.height,
                width: lassoRect.width * pageRect.width,
                height: lassoRect.height * pageRect.height
            ).insetBy(dx: -14, dy: -14).intersection(pageRect).integral
            if crop.width > 10, crop.height > 10, let image = full.cgImage?.cropping(to: crop) {
                output = UIImage(cgImage: image)
                normalizedBounds = lassoRect
            }
        }

        guard let data = output.jpegData(compressionQuality: 0.8) else { return nil }
        return SpatialSelection(pageID: currentPageID, normalizedBounds: normalizedBounds, imageData: data)
    }

    func analyzeCurrentPage(apiKey: String, question: String? = nil) {
        guard !isAnalyzing else { return }
        guard let selection = makeSelectionSnapshot() else {
            agentError = "Draw or circle something first, then analyze."
            return
        }
        let thumbnail = UIImage(data: selection.imageData)
        isAnalyzing = true
        agentError = nil
        let client = AgentClientFactory.make(apiKey: apiKey)

        Task { [weak self] in
            do {
                let insight = try await client.analyze(selection, question: question)
                self?.observations.insert(
                    AgentObservation(summary: insight.summary, items: insight.items, thumbnail: thumbnail, date: Date()),
                    at: 0
                )
                self?.isAnalyzing = false
            } catch {
                self?.agentError = error.localizedDescription
                self?.isAnalyzing = false
            }
        }
    }

    func clearObservations() { observations.removeAll() }

    // MARK: Persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.store.save(self.notebook)
        }
    }

    func persistNow() {
        saveTask?.cancel()
        store.save(notebook)
    }

    private func selectFirstDrawingLayer() {
        guard notebook.pages.indices.contains(currentIndex) else { return }
        let layers = notebook.pages[currentIndex].drawingLayers
        if layers.contains(where: { $0.id == selectedDrawingLayerID && $0.isVisible }) { return }
        selectedDrawingLayerID = layers.first(where: \.isVisible)?.id ?? layers[0].id
    }

    private func normalizedName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
