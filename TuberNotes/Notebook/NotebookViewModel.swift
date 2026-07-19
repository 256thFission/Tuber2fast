import Combine
import Foundation
import PencilKit
import SwiftUI
import UIKit

/// One assistant observation shown in the sidebar.
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
    @Published var currentIndex: Int = 0

    // Tool state
    @Published var tool: WritingTool = .pen
    @Published var inkColorHex: String = InkPalette.default
    @Published var penWidth: CGFloat = WritingTool.pen.defaultWidth
    @Published var pencilWidth: CGFloat = WritingTool.pencil.defaultWidth
    @Published var markerWidth: CGFloat = WritingTool.marker.defaultWidth
    @Published var eraserWidth: CGFloat = WritingTool.eraser.defaultWidth

    // Zoom + template
    @Published var zoomScale: CGFloat = 1
    @Published var lastTemplate: PageTemplate = .linedMedium

    // Assistant
    @Published var observations: [AgentObservation] = []
    @Published var isAnalyzing = false
    @Published var agentError: String?

    private let store: NotebookStore
    private var saveTask: Task<Void, Never>?

    init(notebook: Notebook, store: NotebookStore) {
        self.notebook = notebook
        self.store = store
        self.lastTemplate = notebook.pages.first?.template ?? .linedMedium
    }

    // MARK: Derived

    var pageCount: Int { notebook.pages.count }
    var currentPage: NotebookPage { notebook.pages[safe: currentIndex] ?? notebook.pages[0] }
    var currentPageID: UUID { currentPage.id }
    var currentTemplate: PageTemplate { currentPage.template }
    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex < notebook.pages.count - 1 }
    var pageLabel: String { "\(currentIndex + 1) / \(pageCount)" }

    // MARK: Tool state

    var inkUIColor: UIColor { UIColor(hex: inkColorHex) ?? .label }
    var inkColor: Color { Color(inkUIColor) }

    func selectColor(_ hex: String) {
        inkColorHex = hex
        if tool == .eraser { tool = .pen }
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
        guard notebook.pages.indices.contains(currentIndex) else { return }
        guard notebook.pages[currentIndex].drawingData != data else { return }
        notebook.pages[currentIndex].drawingData = data
        scheduleSave()
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

    func goForward() { guard canGoForward else { return }; currentIndex += 1; resetZoom(); persistNow() }
    func goBack()    { guard canGoBack else { return }; currentIndex -= 1; resetZoom(); persistNow() }

    // MARK: Assistant

    /// Render the current page (white paper + ink) as JPEG for the vision model.
    func makeSelectionSnapshot() -> SpatialSelection? {
        let drawing = currentPage.drawing
        guard !drawing.bounds.isNull else { return nil }

        let pageRect = CGRect(origin: .zero, size: NotebookPageLayout.size)
        let renderer = UIGraphicsImageRenderer(size: pageRect.size)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(pageRect)
            drawing.image(from: pageRect, scale: 1).draw(in: pageRect)
        }
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }

        let b = drawing.bounds
        let normalized = CGRect(
            x: b.minX / pageRect.width,
            y: b.minY / pageRect.height,
            width: b.width / pageRect.width,
            height: b.height / pageRect.height
        )
        return SpatialSelection(pageID: currentPageID, normalizedBounds: normalized, imageData: data)
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
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
