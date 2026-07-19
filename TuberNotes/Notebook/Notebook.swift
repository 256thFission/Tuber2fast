import PencilKit
import SwiftUI
import UIKit

// MARK: - Notebook

/// A locally-persisted notebook. Each notebook owns an ordered list of pages.
struct Notebook: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var cover: NotebookCover
    var pages: [NotebookPage]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        cover: NotebookCover = .indigo,
        pages: [NotebookPage] = [NotebookPage()],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.cover = cover
        self.pages = pages.isEmpty ? [NotebookPage()] : pages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Page

struct NotebookPage: Identifiable, Codable, Equatable {
    let id: UUID
    /// Serialized `PKDrawing` (`dataRepresentation()`), stored in page-local coordinates.
    var drawingData: Data
    var createdAt: Date

    init(
        id: UUID = UUID(),
        drawingData: Data = PKDrawing().dataRepresentation(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.drawingData = drawingData
        self.createdAt = createdAt
    }

    var drawing: PKDrawing {
        (try? PKDrawing(data: drawingData)) ?? PKDrawing()
    }
}

// MARK: - Cover

enum NotebookCover: String, Codable, CaseIterable, Identifiable {
    case indigo, teal, rose, amber, slate, forest
    var id: String { rawValue }

    var base: Color {
        switch self {
        case .indigo: Color(red: 0.36, green: 0.34, blue: 0.83)
        case .teal:   Color(red: 0.13, green: 0.55, blue: 0.55)
        case .rose:   Color(red: 0.79, green: 0.29, blue: 0.44)
        case .amber:  Color(red: 0.86, green: 0.58, blue: 0.15)
        case .slate:  Color(red: 0.29, green: 0.34, blue: 0.42)
        case .forest: Color(red: 0.18, green: 0.45, blue: 0.28)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [base, base.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var displayName: String { rawValue.capitalized }
}

// MARK: - Writing tool

enum WritingTool: String, CaseIterable, Identifiable {
    case pen, pencil, marker, eraser
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pen:    "pencil.tip"
        case .pencil: "pencil"
        case .marker: "highlighter"
        case .eraser: "eraser"
        }
    }

    var label: String { rawValue.capitalized }

    func pkTool(color: UIColor, width: CGFloat) -> PKTool {
        switch self {
        case .pen:    PKInkingTool(.pen, color: color, width: width)
        case .pencil: PKInkingTool(.pencil, color: color, width: width)
        case .marker: PKInkingTool(.marker, color: color, width: width * 3.2)
        case .eraser: PKEraserTool(.bitmap)
        }
    }
}

// MARK: - Ink color

enum InkColor: String, CaseIterable, Identifiable {
    case ink, blue, red, green, orange, purple
    var id: String { rawValue }

    /// Note: `.ink` is a fixed near-black (not `.label`) so it stays visible on the
    /// always-white notebook page in both light and dark appearances.
    var uiColor: UIColor {
        switch self {
        case .ink:    UIColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1)
        case .blue:   UIColor(red: 0.13, green: 0.42, blue: 0.92, alpha: 1)
        case .red:    UIColor(red: 0.85, green: 0.20, blue: 0.24, alpha: 1)
        case .green:  UIColor(red: 0.16, green: 0.55, blue: 0.30, alpha: 1)
        case .orange: UIColor(red: 0.92, green: 0.52, blue: 0.10, alpha: 1)
        case .purple: UIColor(red: 0.50, green: 0.26, blue: 0.80, alpha: 1)
        }
    }

    var swatch: Color { Color(uiColor) }
    var label: String { rawValue.capitalized }
}

// MARK: - Appearance

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }

    var next: AppAppearance {
        switch self {
        case .system: .light
        case .light:  .dark
        case .dark:   .system
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light:  "sun.max"
        case .dark:   "moon"
        }
    }
}
