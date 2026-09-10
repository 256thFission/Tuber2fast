import Foundation
import TNModel

/// JSON exactly one way: sorted keys, ISO-8601 dates, no pretty printing.
/// The key-set pins depend on this being the only encoder the format uses.
package enum Codecs {
    // One configured instance each. JSONEncoder/Decoder are reference types
    // that are never mutated after configuration, which is what makes the
    // shared instances safe.
    private static let sharedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let sharedDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    package static func encode<T: Encodable>(_ value: T) throws(FormatFault) -> Data {
        do {
            return try sharedEncoder.encode(value)
        } catch {
            throw .corruptJSON("encode failed: \(error)")
        }
    }

    package static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(FormatFault) -> T {
        do {
            return try sharedDecoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw FormatFault(decoding: error)
        } catch {
            throw .corruptJSON(String(describing: error))
        }
    }

    /// The parsed top-level object, for key checks that must run before a
    /// typed decode (an unknown layer kind is seen here, not as corruption).
    package static func topLevelObject(of data: Data) throws(FormatFault) -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .corruptJSON(String(describing: error))
        }
        guard let dictionary = object as? [String: Any] else {
            throw .corruptJSON("top level is not an object")
        }
        return dictionary
    }

    /// The one implementation of "the exact key set": a missing key refuses
    /// naming it, then an extra key refuses naming it. Missing wins so a
    /// file from a build that forgot the version bump is reported by what
    /// this build needs, not by what it added.
    package static func checkKeys(_ keys: Set<String>, against expected: Set<String>) throws(FormatFault) {
        if let missing = expected.subtracting(keys).sorted().first { throw .missingKey(missing) }
        if let extra = keys.subtracting(expected).sorted().first { throw .unknownKey(extra) }
    }

    package static func decodeStrict<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        expectedKeys: Set<String>
    ) throws(FormatFault) -> T {
        try checkKeys(Set(try topLevelObject(of: data).keys), against: expectedKeys)
        return try decode(type, from: data)
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
