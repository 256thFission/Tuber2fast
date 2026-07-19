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
    /// Serialized `PKDrawing` (`dataRepresentation()`), stored in fixed page-space
    /// coordinates (`NotebookPageLayout.size`) so drawings are device-independent.
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

// MARK: - Page layout (GoodNotes-style portrait sheet)

enum NotebookPageLayout {
    /// Fixed portrait sheet (~Letter ratio). The canvas scrolls vertically within this.
    static let size = CGSize(width: 768, height: 994)
    static let lineSpacing: CGFloat = 38
    static let marginX: CGFloat = 60
    static var aspect: CGFloat { size.height / size.width }
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

    var label: String {
        switch self {
        case .pen:    "Pen"
        case .pencil: "Pencil"
        case .marker: "Highlighter"
        case .eraser: "Eraser"
        }
    }

    var usesColor: Bool { self != .eraser }
    var usesWidth: Bool { self != .eraser }

    /// Highlighter is drawn semi-transparent so it reads as a highlight.
    func pkTool(color: UIColor, width: CGFloat) -> PKTool {
        switch self {
        case .pen:    PKInkingTool(.pen, color: color, width: width)
        case .pencil: PKInkingTool(.pencil, color: color, width: width)
        case .marker: PKInkingTool(.marker, color: color.withAlphaComponent(0.4), width: width)
        case .eraser: PKEraserTool(.bitmap)
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .pen:    2...16
        case .pencil: 1...14
        case .marker: 8...44
        case .eraser: 10...60
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .pen:    4
        case .pencil: 3
        case .marker: 18
        case .eraser: 24
        }
    }
}

// MARK: - Color palette + hex helpers

enum InkPalette {
    /// A standard, GoodNotes-like default palette.
    static let standard: [String] = [
        "#1C1E26", "#5B5F66", "#9AA0A6", "#FFFFFF",
        "#E11D2E", "#F2711C", "#F4B400", "#2FA84F",
        "#0B8043", "#00897B", "#1A73E8", "#1652CE",
        "#7C3AED", "#D81B8C", "#8B5E3C", "#111111",
    ]
    static let `default` = "#1C1E26"
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
