import Combine
import Foundation
import PencilKit
import SwiftUI
import UIKit

@MainActor
final class NotebookViewModel: ObservableObject {
    @Published var notebook: Notebook
    @Published var currentIndex: Int = 0

    @Published var tool: WritingTool = .pen
    @Published var inkColorHex: String = InkPalette.default

    // Independent widths per tool so pen and highlighter keep their own size.
    @Published var penWidth: CGFloat = WritingTool.pen.defaultWidth
    @Published var pencilWidth: CGFloat = WritingTool.pencil.defaultWidth
    @Published var markerWidth: CGFloat = WritingTool.marker.defaultWidth

    private let store: NotebookStore
    private var saveTask: Task<Void, Never>?

    init(notebook: Notebook, store: NotebookStore) {
        self.notebook = notebook
        self.store = store
    }

    // MARK: Derived

    var pageCount: Int { notebook.pages.count }
    var currentPage: NotebookPage { notebook.pages[safe: currentIndex] ?? notebook.pages[0] }
    var currentPageID: UUID { currentPage.id }
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

    /// The width for whichever tool is active (bindable from the size popover).
    var activeWidth: CGFloat {
        get {
            switch tool {
            case .pen:    penWidth
            case .pencil: pencilWidth
            case .marker: markerWidth
            case .eraser: penWidth
            }
        }
        set {
            switch tool {
            case .pen:    penWidth = newValue
            case .pencil: pencilWidth = newValue
            case .marker: markerWidth = newValue
            case .eraser: break
            }
        }
    }

    var widthRange: ClosedRange<CGFloat> { tool.widthRange }

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
        notebook.pages.insert(NotebookPage(), at: insertAt)
        currentIndex = insertAt
        persistNow()
    }

    func deleteCurrentPage() {
        guard notebook.pages.count > 1 else { return }
        notebook.pages.remove(at: currentIndex)
        currentIndex = min(currentIndex, notebook.pages.count - 1)
        persistNow()
    }

    func go(to index: Int) {
        guard notebook.pages.indices.contains(index) else { return }
        currentIndex = index
        persistNow()
    }

    func goForward() {
        guard canGoForward else { return }
        currentIndex += 1
        persistNow()
    }

    func goBack() {
        guard canGoBack else { return }
        currentIndex -= 1
        persistNow()
    }

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
