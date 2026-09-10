import Foundation
import TNModel

/// JSON exactly one way: sorted keys, ISO-8601 dates, no pretty printing.
/// The key-set pins depend on this being the only encoder the format uses.
package enum Codecs {
    package static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    package static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The exact top-level key set every durable JSON type must carry. A
    /// missing key refuses naming the key; an extra key refuses naming it
    /// too, because a key nothing in this build reads is a key some other
    /// build wrote without the version bump D9 requires.
    package static func topLevelKeys(of data: Data) throws(FormatFault) -> Set<String> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .corruptJSON(String(describing: error))
        }
        guard let dictionary = object as? [String: Any] else {
            throw .corruptJSON("top level is not an object")
        }
        return Set(dictionary.keys)
    }

    package static func decodeStrict<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        expectedKeys: Set<String>
    ) throws(FormatFault) -> T {
        let keys = try topLevelKeys(of: data)
        if let missing = expectedKeys.subtracting(keys).sorted().first {
            throw .missingKey(missing)
        }
        if let extra = keys.subtracting(expectedKeys).sorted().first {
            throw .unknownKey(extra)
        }
        do {
            return try decoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw FormatFault(decoding: error)
        } catch {
            throw .corruptJSON(String(describing: error))
        }
    }

    package static func encode<T: Encodable>(_ value: T) throws(FormatFault) -> Data {
        do {
            return try encoder().encode(value)
        } catch {
            throw .corruptJSON("encode failed: \(error)")
        }
    }
}

/// The key sets the format pins. One place, mirrored by one test each.
package enum DurableKeys {
    package static let index: Set<String> = ["formatVersion", "notebookID", "createdAt", "pages"]
    package static let pageRecord: Set<String> = ["id", "width", "height", "paper"]
    package static let paper: Set<String> = ["kind"]
    package static let pageFile: Set<String> = ["pageID", "hasInk", "inkIndex", "layers"]
    package static let view: Set<String> = ["currentPageID"]
    package static func layerFile(kind: String) -> Set<String> { ["layerID", "kind", "transform", kind] }
    package static let image: Set<String> = ["asset", "naturalSize"]
    package static let pdf: Set<String> = ["asset", "sourcePageIndex", "sourceExtent"]
    package static let link: Set<String> = ["rect", "style", "target"]
}

/// Why the format refused, at file scope. Page-scoped faults are `PageFault`.
package enum FormatFault: Error, Sendable, Equatable, CustomStringConvertible {
    case missingKey(String)
    case unknownKey(String)
    case corruptJSON(String)
    case indexUnreadable(String)
    case indexInvalid(NotebookIndexFault)
    case insufficientSpace(needed: Int64, available: Int64)
    case invalidWrite(String)
    case io(FileSystemError)
    case noPackage

    init(decoding error: DecodingError) {
        switch error {
        case .keyNotFound(let key, _):
            self = .missingKey(key.stringValue)
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            self = .corruptJSON(path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)")
        @unknown default:
            self = .corruptJSON(String(describing: error))
        }
    }

    package var description: String {
        switch self {
        case .missingKey(let key): "missing key \(key)"
        case .unknownKey(let key): "unknown key \(key)"
        case .corruptJSON(let detail): "corrupt JSON: \(detail)"
        case .indexUnreadable(let detail): "index unreadable: \(detail)"
        case .indexInvalid(let fault): "index invalid: \(fault)"
        case .insufficientSpace(let needed, let available): "insufficient space: need \(needed), have \(available)"
        case .invalidWrite(let detail): "invalid write: \(detail)"
        case .io(let error): "I/O: \(error)"
        case .noPackage: "no package"
        }
    }
}
