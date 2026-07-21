import ImageIO
import PencilKit
import SwiftUI
import UIKit

// MARK: - Notebook

struct Notebook: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var cover: NotebookCover
    var pages: [NotebookPage]
    var agenticLayers: [ConversationLayer]
    var createdAt: Date
    var updatedAt: Date
    var settings: NotebookSettings?

    init(
        id: UUID = UUID(),
        title: String,
        cover: NotebookCover = .indigo,
        pages: [NotebookPage] = [NotebookPage()],
        agenticLayers: [ConversationLayer] = [
            ConversationLayer(
                id: UUID(),
                name: "Agent",
                symbolName: "sparkles",
                conversations: []
            )
        ],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        settings: NotebookSettings? = NotebookSettings()
    ) {
        self.id = id
        self.title = title
        self.cover = cover
        self.pages = pages.isEmpty ? [NotebookPage()] : pages
        self.agenticLayers = agenticLayers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, cover, pages, agenticLayers, createdAt, updatedAt, settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        cover = try container.decode(NotebookCover.self, forKey: .cover)
        let decodedPages = try container.decodeIfPresent([NotebookPage].self, forKey: .pages) ?? []
        pages = decodedPages.isEmpty ? [NotebookPage()] : decodedPages
        agenticLayers = try container.decodeIfPresent([ConversationLayer].self, forKey: .agenticLayers)
            ?? [ConversationLayer(id: UUID(), name: "Agent", symbolName: "sparkles", conversations: [])]
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        settings = try container.decodeIfPresent(NotebookSettings.self, forKey: .settings)
            ?? NotebookSettings()
    }
}

enum NotebookPageScrollDirection: String, Codable, CaseIterable, Identifiable {
    case horizontal
    case vertical

    var id: Self { self }
    var label: String { rawValue.capitalized }
    var previousSymbolName: String { self == .horizontal ? "chevron.left" : "chevron.up" }
    var nextSymbolName: String { self == .horizontal ? "chevron.right" : "chevron.down" }
}

struct NotebookSettings: Codable, Equatable {
    var showsPageNavigation: Bool
    var showsWritingTools: Bool
    var showsLayers: Bool
    var showsExport: Bool
    var showsPageLock: Bool
    var favoriteColors: [String]
    var pageScrollDirection: NotebookPageScrollDirection

    init(
        showsPageNavigation: Bool = true,
        showsWritingTools: Bool = true,
        showsLayers: Bool = true,
        showsExport: Bool = true,
        showsPageLock: Bool = true,
        favoriteColors: [String] = [InkPalette.default, "#E11D2E", "#F4B400", "#1A73E8"],
        pageScrollDirection: NotebookPageScrollDirection = .horizontal
    ) {
        self.showsPageNavigation = showsPageNavigation
        self.showsWritingTools = showsWritingTools
        self.showsLayers = showsLayers
        self.showsExport = showsExport
        self.showsPageLock = showsPageLock
        self.favoriteColors = favoriteColors
        self.pageScrollDirection = pageScrollDirection
    }

    private enum CodingKeys: String, CodingKey {
        case showsPageNavigation, showsWritingTools, showsLayers, showsExport, showsPageLock
        case favoriteColors, pageScrollDirection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsPageNavigation = try container.decodeIfPresent(Bool.self, forKey: .showsPageNavigation) ?? true
        showsWritingTools = try container.decodeIfPresent(Bool.self, forKey: .showsWritingTools) ?? true
        showsLayers = try container.decodeIfPresent(Bool.self, forKey: .showsLayers) ?? true
        showsExport = try container.decodeIfPresent(Bool.self, forKey: .showsExport) ?? true
        showsPageLock = try container.decodeIfPresent(Bool.self, forKey: .showsPageLock) ?? true
        favoriteColors = try container.decodeIfPresent([String].self, forKey: .favoriteColors)
            ?? [InkPalette.default, "#E11D2E", "#F4B400", "#1A73E8"]
        pageScrollDirection = try container.decodeIfPresent(
            NotebookPageScrollDirection.self,
            forKey: .pageScrollDirection
        ) ?? .horizontal
    }
}

// MARK: - Page

/// An image placed on a page. `rect` is normalized (0...1) in page space and
/// images render *under* the ink so you can annotate on top of them.
struct PlacedImage: Identifiable, Codable, Equatable {
    private static let maximumDisplayPixelDimension = 4_096

    let id: UUID
    var imageData: Data
    var rect: CGRect
    var rotationRadians: CGFloat

    init(
        id: UUID = UUID(),
        imageData: Data,
        rect: CGRect,
        rotationRadians: CGFloat = 0
    ) {
        self.id = id
        self.imageData = imageData
        self.rect = rect
        self.rotationRadians = rotationRadians
    }

    /// The original import remains in `imageData`; UIKit receives a bounded
    /// display decode so a large camera photo cannot consume its full decoded
    /// pixel footprint merely by appearing on a notebook page.
    var image: UIImage? {
        downsampledImage(maximumPixelDimension: Self.maximumDisplayPixelDimension)
    }

    private enum CodingKeys: String, CodingKey {
        case id, imageData, rect, rotationRadians
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        imageData = try container.decode(Data.self, forKey: .imageData)
        rect = try container.decode(CGRect.self, forKey: .rect)
        rotationRadians = try container.decodeIfPresent(CGFloat.self, forKey: .rotationRadians) ?? 0
    }

    func draw(in rect: CGRect) {
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return }

        let context = UIGraphicsGetCurrentContext()
        let maximumPixelDimension = context.map {
            let transform = $0.ctm
            let horizontalScale = hypot(transform.a, transform.b)
            let verticalScale = hypot(transform.c, transform.d)
            let requested = ceil(max(rect.width * horizontalScale, rect.height * verticalScale))
            guard requested.isFinite, requested > 0 else {
                return Self.maximumDisplayPixelDimension
            }
            return max(1, Int(min(requested, CGFloat(Self.maximumDisplayPixelDimension))))
        } ?? Self.maximumDisplayPixelDimension
        guard let image = downsampledImage(maximumPixelDimension: maximumPixelDimension) else {
            return
        }

        let safeRotation = rotationRadians.isFinite ? rotationRadians : 0
        guard safeRotation != 0, let context else {
            image.draw(in: rect)
            return
        }

        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: safeRotation)
        image.draw(in: CGRect(
            x: -rect.width / 2,
            y: -rect.height / 2,
            width: rect.width,
            height: rect.height
        ))
        context.restoreGState()
    }

    private func downsampledImage(maximumPixelDimension: Int) -> UIImage? {
        guard maximumPixelDimension > 0,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct NotebookPage: Identifiable, Codable, Equatable {
    let id: UUID
    var drawingLayers: [DrawingLayer]
    var createdAt: Date
    var template: PageTemplate
    var images: [PlacedImage]

    init(
        id: UUID = UUID(),
        drawingLayers: [DrawingLayer] = [DrawingLayer(name: "Drawing 1")],
        createdAt: Date = Date(),
        template: PageTemplate = .linedMedium,
        images: [PlacedImage] = []
    ) {
        self.id = id
        self.drawingLayers = drawingLayers.isEmpty ? [DrawingLayer(name: "Drawing 1")] : drawingLayers
        self.createdAt = createdAt
        self.template = template
        self.images = images
    }

    // Tolerant decoding migrates the previous single-drawing page format into a layer.
    enum CodingKeys: String, CodingKey {
        case id, drawingLayers, drawingData, createdAt, template, images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        if let decodedLayers = try c.decodeIfPresent([DrawingLayer].self, forKey: .drawingLayers),
           !decodedLayers.isEmpty {
            drawingLayers = decodedLayers
        } else {
            let legacyData = try c.decodeIfPresent(Data.self, forKey: .drawingData)
                ?? PKDrawing().dataRepresentation()
            drawingLayers = [DrawingLayer(name: "Drawing 1", drawingData: legacyData)]
        }
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        template = try c.decodeIfPresent(PageTemplate.self, forKey: .template) ?? .linedMedium
        images = try c.decodeIfPresent([PlacedImage].self, forKey: .images) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(drawingLayers, forKey: .drawingLayers)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(template, forKey: .template)
        try c.encode(images, forKey: .images)
    }

    var drawing: PKDrawing {
        PKDrawing(strokes: drawingLayers.filter(\.isVisible).flatMap { $0.drawing.strokes })
    }

    /// Bridges the layered model back to the single-drawing consumers (the canvas
    /// and view model still speak one `PKDrawing`-as-`Data`). Reads/writes the first
    /// drawing layer in place, so the layered on-disk format and legacy migration
    /// are preserved and layer name/visibility aren't clobbered.
    var drawingData: Data {
        get { drawingLayers.first?.drawingData ?? PKDrawing().dataRepresentation() }
        set {
            if drawingLayers.isEmpty {
                drawingLayers = [DrawingLayer(name: "Drawing 1", drawingData: newValue)]
            } else {
                drawingLayers[0].drawingData = newValue
            }
        }
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
                let r = CGRect(x: placed.rect.minX * size.width, y: placed.rect.minY * size.height,
                               width: placed.rect.width * size.width, height: placed.rect.height * size.height)
                placed.draw(in: r)
            }
            let d = drawing
            if !d.bounds.isNull {
                d.image(from: CGRect(origin: .zero, size: page), scale: 1)
                    .draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
}

struct DrawingLayer: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var drawingData: Data
    var isVisible: Bool

    init(
        id: UUID = UUID(),
        name: String,
        drawingData: Data = PKDrawing().dataRepresentation(),
        isVisible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.drawingData = drawingData
        self.isVisible = isVisible
    }

    var drawing: PKDrawing {
        (try? PKDrawing(data: drawingData)) ?? PKDrawing()
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
        case .eraser: PKEraserTool(.bitmap, width: width)
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

    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.62
    }
}
