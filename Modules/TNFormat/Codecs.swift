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

    /// The parsed top-level object, for what is read before a typed decode:
    /// a version before any key, a kind name before its payload.
    package static func topLevelObject(of data: Data) throws(FormatFault) -> [String: Any] {
        guard let dictionary = try tree(of: data) as? [String: Any] else {
            throw .corruptJSON("top level is not an object")
        }
        return dictionary
    }

    /// The one implementation of "the exact key set". The value is decoded
    /// first, so a missing key refuses naming it; then it is re-encoded with
    /// the one encoder and the two trees are walked together, so a key the
    /// file carries at any depth and the re-encode lacks, one the next write
    /// would drop, refuses naming its path. Missing wins so a file from a
    /// build that forgot the version bump is reported by what this build
    /// needs, not by what it added. Arrays are walked element by element,
    /// because a page record's paper keys depend on that record's kind.
    package static func decodeStrict<T: Codable>(_ type: T.Type, from data: Data) throws(FormatFault) -> T {
        let value = try decode(type, from: data)
        if let extra = firstUnwrittenKey(in: try tree(of: data), against: try tree(of: try encode(value)), at: "") {
            throw .unknownKey(extra)
        }
        return value
    }

    private static func tree(of data: Data) throws(FormatFault) -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .corruptJSON(String(describing: error))
        }
    }

    private static func firstUnwrittenKey(in read: Any, against written: Any, at path: String) -> String? {
        switch (read, written) {
        case (let read as [String: Any], let written as [String: Any]):
            for (key, value) in read.sorted(by: { $0.key < $1.key }) {
                let child = path.isEmpty ? key : "\(path).\(key)"
                guard let echo = written[key] else { return child }
                if let extra = firstUnwrittenKey(in: value, against: echo, at: child) { return extra }
            }
        case (let read as [Any], let written as [Any]):
            for (offset, (element, echo)) in zip(read, written).enumerated() {
                if let extra = firstUnwrittenKey(in: element, against: echo, at: "\(path)[\(offset)]") { return extra }
            }
        default:
            break
        }
        return nil
    }
}

/// Why the format refused, at file scope. Page-scoped faults are `PageFault`.
package enum FormatFault: Error, Sendable, Equatable, CustomStringConvertible {
    case missingKey(String)
    case unknownKey(String)
    case corruptJSON(String)
    case indexInvalid(NotebookIndexFault)
    case newerFormat(found: UInt32)
    case olderFormat(found: UInt32)
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
        case .indexInvalid(let fault): "index invalid: \(fault)"
        case .newerFormat: "made by a newer TuberNotes; update the app"
        case .olderFormat: "made by an older TuberNotes this version cannot upgrade"
        case .insufficientSpace(let needed, let available): "insufficient space: need \(needed), have \(available)"
        case .invalidWrite(let detail): "invalid write: \(detail)"
        case .io(let error): "I/O: \(error)"
        case .noPackage: "no package"
        }
    }
}
