import CoreGraphics
import Foundation
import PencilKit
import UIKit

/// Native, lossless interchange format. Unlike PDF, this archive favors editing
/// fidelity and extensibility over compactness or presentation compatibility.
struct TuberNoteArchive: Codable {
    static let oldestSupportedFormatVersion = 1
    static let currentFormatVersion = 2
    static let formatIdentifier = "com.tubernotes.note"
    static let fileExtension = "spud"

    let format: String
    let formatVersion: Int
    let compression: Compression
    let createdAt: Date
    let noteID: UUID
    let canvasSize: ArchiveSize
    var inkLayers: [InkLayer]
    var conversationLayers: [ConversationLayerRecord]
    var extraData: [String: JSONValue]

    enum Compression: String, Codable {
        case none
    }

    struct ArchiveSize: Codable, Equatable {
        let width: Double
        let height: Double

        init(_ size: CGSize) {
            width = Double(size.width)
            height = Double(size.height)
        }

        var cgSize: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
    }

    struct InkLayer: Codable {
        let id: UUID
        var name: String
        var isVisible: Bool

        /// Apple's opaque representation is the lossless source used to reopen
        /// the drawing, including PencilKit details unknown to this schema.
        let pencilKitDrawing: Data

        /// An uncompressed, inspectable mirror for portability and diagnostics.
        let strokes: [StrokeRecord]
    }

    struct StrokeRecord: Codable {
        let ink: InkRecord
        let transform: TransformRecord
        let creationDate: Date
        let points: [StrokePointRecord]
    }

    struct InkRecord: Codable {
        let type: String
        let color: ColorRecord
    }

    struct ColorRecord: Codable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    struct TransformRecord: Codable {
        let a: Double
        let b: Double
        let c: Double
        let d: Double
        let tx: Double
        let ty: Double
    }

    struct StrokePointRecord: Codable {
        let x: Double
        let y: Double
        let timeOffset: TimeInterval
        let width: Double
        let height: Double
        let opacity: Double
        let force: Double
        let azimuth: Double
        let altitude: Double
    }

    struct ConversationLayerRecord: Codable {
        let id: UUID
        var name: String
        var symbolName: String
        var isVisible: Bool
        var conversations: [ConversationRecord]

        private enum CodingKeys: String, CodingKey {
            case id, name, symbolName, isVisible, conversations
        }

        init(
            id: UUID,
            name: String,
            symbolName: String,
            isVisible: Bool,
            conversations: [ConversationRecord]
        ) {
            self.id = id
            self.name = name
            self.symbolName = symbolName
            self.isVisible = isVisible
            self.conversations = conversations
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            symbolName = try container.decode(String.self, forKey: .symbolName)
            isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
            conversations = try container.decode([ConversationRecord].self, forKey: .conversations)
        }
    }

    struct ConversationRecord: Codable {
        let annotation: PageAnnotation

        private enum CodingKeys: String, CodingKey {
            case annotation

            // Version 1 compatibility. New archives encode only `annotation`.
            case id, pageX, pageY, title, detail
        }

        init(annotation: PageAnnotation) {
            self.annotation = annotation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let annotation = try container.decodeIfPresent(PageAnnotation.self, forKey: .annotation) {
                self.annotation = annotation
                return
            }

            let id = try container.decode(UUID.self, forKey: .id)
            self.annotation = PageAnnotation(
                id: id,
                pagePosition: CGPoint(
                    x: try container.decode(CGFloat.self, forKey: .pageX),
                    y: try container.decode(CGFloat.self, forKey: .pageY)
                ),
                title: try container.decode(String.self, forKey: .title),
                detail: try container.decode(String.self, forKey: .detail)
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(annotation, forKey: .annotation)
        }
    }
}

/// Codable JSON payload suitable for application-specific data without a schema
/// migration for every new key. Binary extras can be represented as base64 strings.
enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum TuberNoteArchiveCodec {
    struct InkLayerInput {
        let id: UUID
        let name: String
        let isVisible: Bool
        let drawing: PKDrawing

        init(id: UUID = UUID(), name: String, isVisible: Bool = true, drawing: PKDrawing) {
            self.id = id
            self.name = name
            self.isVisible = isVisible
            self.drawing = drawing
        }
    }

    struct DecodedInkLayer {
        let id: UUID
        let name: String
        let isVisible: Bool
        let drawing: PKDrawing
    }

    struct DecodedDocument {
        let archive: TuberNoteArchive
        let inkLayers: [DecodedInkLayer]
        let conversationLayers: NoteConversationLayers
        let integrityWarnings: [String]
    }

    enum ArchiveError: Error, LocalizedError {
        case wrongFormat(String)
        case unsupportedVersion(Int)
        case unexpectedCompression(String)
        case damagedInkLayer(UUID)

        var errorDescription: String? {
            switch self {
            case .wrongFormat(let format):
                return "Not a TuberNotes archive: \(format)"
            case .unsupportedVersion(let version):
                return "Unsupported TuberNotes archive version: \(version)"
            case .unexpectedCompression(let compression):
                return "Unsupported TuberNotes archive compression: \(compression)"
            case .damagedInkLayer(let id):
                return "The PencilKit data for ink layer \(id) is damaged."
            }
        }
    }

    static func encode(
        drawing: PKDrawing,
        canvasSize: CGSize,
        conversationLayers: NoteConversationLayers,
        extraData: [String: JSONValue] = [:]
    ) throws -> Data {
        try encode(
            inkLayers: [InkLayerInput(name: "Ink", drawing: drawing)],
            canvasSize: canvasSize,
            conversationLayers: conversationLayers,
            extraData: extraData
        )
    }

    static func encode(
        inkLayers: [InkLayerInput],
        canvasSize: CGSize,
        conversationLayers: NoteConversationLayers,
        extraData: [String: JSONValue] = [:]
    ) throws -> Data {
        let archive = TuberNoteArchive(
            format: TuberNoteArchive.formatIdentifier,
            formatVersion: TuberNoteArchive.currentFormatVersion,
            compression: .none,
            createdAt: Date(),
            noteID: conversationLayers.noteID,
            canvasSize: .init(canvasSize),
            inkLayers: inkLayers.map(makeInkLayer),
            conversationLayers: conversationLayers.layers.map(makeConversationLayer),
            extraData: extraData
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> DecodedDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.dataDecodingStrategy = .base64
        let archive = try decoder.decode(TuberNoteArchive.self, from: data)

        guard archive.format == TuberNoteArchive.formatIdentifier else {
            throw ArchiveError.wrongFormat(archive.format)
        }
        guard (TuberNoteArchive.oldestSupportedFormatVersion...TuberNoteArchive.currentFormatVersion)
            .contains(archive.formatVersion)
        else {
            throw ArchiveError.unsupportedVersion(archive.formatVersion)
        }
        guard archive.compression == .none else {
            throw ArchiveError.unexpectedCompression(archive.compression.rawValue)
        }

        var integrityWarnings: [String] = []
        let decodedLayers = try archive.inkLayers.map { layer -> DecodedInkLayer in
            guard let drawing = try? PKDrawing(data: layer.pencilKitDrawing) else {
                throw ArchiveError.damagedInkLayer(layer.id)
            }
            let mirrorsMatch = drawing.strokes.count == layer.strokes.count
                && drawing.strokes.enumerated().allSatisfy { index, stroke in
                    stroke.path.count == layer.strokes[index].points.count
                }
            if !mirrorsMatch {
                integrityWarnings.append(
                    "Ink layer \(layer.id) was normalized by PencilKit; the lossless PencilKit payload was used."
                )
            }
            return DecodedInkLayer(
                id: layer.id,
                name: layer.name,
                isVisible: layer.isVisible,
                drawing: drawing
            )
        }

        return DecodedDocument(
            archive: archive,
            inkLayers: decodedLayers,
            conversationLayers: NoteConversationLayers(
                noteID: archive.noteID,
                layers: archive.conversationLayers.map(makeConversationLayer)
            ),
            integrityWarnings: integrityWarnings
        )
    }

    private static func makeInkLayer(from input: InkLayerInput) -> TuberNoteArchive.InkLayer {
        let drawing = input.drawing
        return TuberNoteArchive.InkLayer(
            id: input.id,
            name: input.name,
            isVisible: input.isVisible,
            pencilKitDrawing: drawing.dataRepresentation(),
            strokes: drawing.strokes.map { stroke in
                TuberNoteArchive.StrokeRecord(
                    ink: .init(
                        type: stroke.ink.inkType.rawValue,
                        color: colorRecord(from: stroke.ink.color)
                    ),
                    transform: .init(
                        a: Double(stroke.transform.a),
                        b: Double(stroke.transform.b),
                        c: Double(stroke.transform.c),
                        d: Double(stroke.transform.d),
                        tx: Double(stroke.transform.tx),
                        ty: Double(stroke.transform.ty)
                    ),
                    creationDate: stroke.path.creationDate,
                    points: (0..<stroke.path.count).map { index in
                        let point = stroke.path[index]
                        return TuberNoteArchive.StrokePointRecord(
                            x: Double(point.location.x),
                            y: Double(point.location.y),
                            timeOffset: point.timeOffset,
                            width: Double(point.size.width),
                            height: Double(point.size.height),
                            opacity: Double(point.opacity),
                            force: Double(point.force),
                            azimuth: Double(point.azimuth),
                            altitude: Double(point.altitude)
                        )
                    }
                )
            }
        )
    }

    private static func colorRecord(from color: UIColor) -> TuberNoteArchive.ColorRecord {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if !resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            resolved.getWhite(&white, alpha: &alpha)
            red = white
            green = white
            blue = white
        }
        return .init(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha)
        )
    }

    private static func makeConversationLayer(_ layer: ConversationLayer) -> TuberNoteArchive.ConversationLayerRecord {
        .init(
            id: layer.id,
            name: layer.name,
            symbolName: layer.symbolName,
            isVisible: layer.isVisible,
            conversations: layer.conversations.map { conversation in
                .init(annotation: conversation)
            }
        )
    }

    private static func makeConversationLayer(_ layer: TuberNoteArchive.ConversationLayerRecord) -> ConversationLayer {
        ConversationLayer(
            id: layer.id,
            name: layer.name,
            symbolName: layer.symbolName,
            conversations: layer.conversations.map { conversation in
                conversation.annotation
            },
            isVisible: layer.isVisible
        )
    }
}
