import Foundation

/// Branded identities. A `PageID` cannot be passed where a `LayerID` is
/// expected, which is how the compiler holds "identity, never position"
/// and "a page ID is never resolved outside its notebook".
///
/// Each is a UUID underneath and encodes as its uppercase hyphenated string,
/// the one canonical JSON spelling. Minting happens in exactly one place per
/// kind: `init()`.
public protocol BrandedID: Hashable, Codable, Sendable, CustomStringConvertible {
    var raw: UUID { get }
    init(raw: UUID)
}

extension UUID {
    /// The one canonical spelling the format accepts: uppercase, hyphenated.
    public static func canonical(_ string: String) -> UUID? {
        guard let uuid = UUID(uuidString: string), uuid.uuidString == string else { return nil }
        return uuid
    }
}

extension BrandedID {
    public init() { self.init(raw: UUID()) }
    public var description: String { raw.uuidString }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID.canonical(string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\(Self.self) is not a canonical uppercase UUID: \(string)"
            )
        }
        self.init(raw: uuid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw.uuidString)
    }
}

package struct NotebookID: BrandedID {
    package let raw: UUID
    package init(raw: UUID) { self.raw = raw }
}

package struct PageID: BrandedID {
    package let raw: UUID
    package init(raw: UUID) { self.raw = raw }
}

package struct LayerID: BrandedID {
    package let raw: UUID
    package init(raw: UUID) { self.raw = raw }
}

package struct AssetID: BrandedID {
    package let raw: UUID
    package init(raw: UUID) { self.raw = raw }
}
