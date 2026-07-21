import Foundation
import PencilKit
import UniformTypeIdentifiers

/// Native, lossless interchange format for one complete editable notebook.
struct TuberNoteArchive: Codable {
    static let currentFormatVersion = 3
    static let formatIdentifier = "com.tubernotes.note"
    static let fileExtension = "spud"

    let format: String
    let formatVersion: Int
    let createdAt: Date
    let notebook: Notebook
}

enum TuberNoteArchiveCodec {
    struct DecodedDocument {
        let archive: TuberNoteArchive
        let notebook: Notebook
    }

    enum ArchiveError: Error, LocalizedError {
        case wrongFormat(String)
        case unsupportedVersion(Int)
        case damagedInkLayer(UUID)

        var errorDescription: String? {
            switch self {
            case .wrongFormat(let format):
                return "Not a TuberNotes archive: \(format)"
            case .unsupportedVersion(let version):
                return "Unsupported TuberNotes archive version: \(version)"
            case .damagedInkLayer(let id):
                return "The PencilKit data for ink layer \(id) is damaged."
            }
        }
    }

    static func encode(notebook: Notebook) throws -> Data {
        let archive = TuberNoteArchive(
            format: TuberNoteArchive.formatIdentifier,
            formatVersion: TuberNoteArchive.currentFormatVersion,
            createdAt: Date(),
            notebook: notebook
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
        guard archive.formatVersion == TuberNoteArchive.currentFormatVersion else {
            throw ArchiveError.unsupportedVersion(archive.formatVersion)
        }
        for page in archive.notebook.pages {
            for layer in page.drawingLayers {
                guard (try? PKDrawing(data: layer.drawingData)) != nil else {
                    throw ArchiveError.damagedInkLayer(layer.id)
                }
            }
        }

        return DecodedDocument(archive: archive, notebook: archive.notebook)
    }
}

extension UTType {
    static let tuberNoteArchive = UTType(
        exportedAs: TuberNoteArchive.formatIdentifier,
        conformingTo: .json
    )
}
