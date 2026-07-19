import PencilKit
import SwiftUI
import UIKit

// MARK: - Notebook

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

/// An image placed on a page. `rect` is normalized (0...1) in page space and
/// images render *under* the ink so you can annotate on top of them.
struct PlacedImage: Identifiable, Codable, Equatable {
    let id: UUID
    var imageData: Data
    var rect: CGRect

    init(id: UUID = UUID(), imageData: Data, rect: CGRect) {
        self.id = id
        self.imageData = imageData
        self.rect = rect
    }

    var image: UIImage? { UIImage(data: imageData) }
}

struct NotebookPage: Identifiable, Codable, Equatable {
    let id: UUID
    /// Serialized `PKDrawing` in fixed page-space (`NotebookPageLayout.size`).
    var drawingData: Data
    var createdAt: Date
    var template: PageTemplate
    var images: [PlacedImage]

    init(
        id: UUID = UUID(),
        drawingData: Data = PKDrawing().dataRepresentation(),
        createdAt: Date = Date(),
        template: PageTemplate = .linedMedium,
        images: [PlacedImage] = []
    ) {
        self.id = id
        self.drawingData = drawingData
        self.createdAt = createdAt
        self.template = template
        self.images = images
    }

    // Tolerant decoding so older saved notebooks (without newer fields) still load.
    enum CodingKeys: String, CodingKey { case id, drawingData, createdAt, template, images }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        drawingData = try c.decode(Data.self, forKey: .drawingData)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        template = try c.decodeIfPresent(PageTemplate.self, forKey: .template) ?? .linedMedium
        images = try c.decodeIfPresent([PlacedImage].self, forKey: .images) ?? []
    }

    var drawing: PKDrawing {
        (try? PKDrawing(data: drawingData)) ?? PKDrawing()
    }

    /// Small white-backed render (images under ink), for strips and thumbnails.
    func renderThumbnail(maxWidth: CGFloat = 120) -> UIImage? {
        let page = NotebookPageLayout.size
        let scale = maxWidth / page.width
        let size = CGSize(width: page.width * scale, height: page.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for placed in images {
                guard let ui = placed.image else { continue }
                let r = CGRect(x: placed.rect.minX * size.width, y: placed.rect.minY * size.height,
                               width: placed.rect.width * size.width, height: placed.rect.height * size.height)
                ui.draw(in: r)
            }
            let d = drawing
            if !d.bounds.isNull {
                d.image(from: CGRect(origin: .zero, size: page), scale: 1)
                    .draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
}

// MARK: - Page layout (GoodNotes-style portrait sheet)

enum NotebookPageLayout {
    static let size = CGSize(width: 768, height: 994)
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
        LinearGradient(colors: [base, base.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
    /// All tools — including the eraser — are now sizable.
    var usesWidth: Bool { true }

    func pkTool(color: UIColor, width: CGFloat) -> PKTool {
        switch self {
        case .pen:    PKInkingTool(.pen, color: color, width: width)
        case .pencil: PKInkingTool(.pencil, color: color, width: width)
        case .marker: PKInkingTool(.marker, color: color.withAlphaComponent(0.4), width: width)
        case .eraser: PKEraserTool(.bitmap, width: width) // iOS 16.4+
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .pen:    2...16
        case .pencil: 1...14
        case .marker: 8...44
        case .eraser: 8...80
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
