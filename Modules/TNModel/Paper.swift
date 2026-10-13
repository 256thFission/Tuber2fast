import Foundation

/// What a drawn paper looks like: a name and nothing more. Spacing, colour,
/// and margins are rendering constants of the build that draws them.
package enum DrawnPaper: String, Codable, Sendable, Hashable, CaseIterable {
    /// `none`: nothing is drawn at all, not even a white ground.
    case none, blank, lined, grid, dotted
}

/// A page's paper: drawn procedurally, or an asset that fills the page.
package enum Paper: Sendable, Hashable {
    case drawn(DrawnPaper)
    case image(AssetRef)
    case pdf(AssetRef, sourcePageIndex: Int)

    package var asset: AssetRef? {
        switch self {
        case .drawn: nil
        case .image(let asset), .pdf(let asset, _): asset
        }
    }

    package var drawn: DrawnPaper? {
        if case .drawn(let drawn) = self { return drawn }
        return nil
    }

    package var isAsset: Bool { asset != nil }
}

/// The on-disk shape, keyed by kind so the kind is read before any payload
/// key: `{ "kind": "lined" }`, `{ "kind": "image", "asset": "UUID.heic" }`,
/// `{ "kind": "pdf", "asset": "UUID.pdf", "sourcePageIndex": 3 }`. A kind
/// this build does not write is not a paper; the index naming it is refused.
extension Paper: Codable {
    private enum CodingKeys: String, CodingKey { case kind, asset, sourcePageIndex }

    /// The two kind names that are not a `DrawnPaper` case.
    package static let imageKind = "image"
    package static let pdfKind = "pdf"

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .kind)
        switch name {
        case Self.imageKind:
            self = .image(try Self.asset(.heic, from: container))
        case Self.pdfKind:
            let index = try container.decode(Int.self, forKey: .sourcePageIndex)
            guard index >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sourcePageIndex, in: container, debugDescription: "sourcePageIndex is negative: \(index)"
                )
            }
            self = .pdf(try Self.asset(.pdf, from: container), sourcePageIndex: index)
        default:
            guard let drawn = DrawnPaper(rawValue: name) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container, debugDescription: "paper kind \(name) is not one this build writes"
                )
            }
            self = .drawn(drawn)
        }
    }

    /// The asset's format is stated only by its file name, so a kind that
    /// disagrees with it names two different pictures and is refused.
    private static func asset(
        _ format: AssetFormat, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> AssetRef {
        let asset = try container.decode(AssetRef.self, forKey: .asset)
        guard asset.format == format else {
            throw DecodingError.dataCorruptedError(
                forKey: .asset, in: container,
                debugDescription: "paper of kind \(format.rawValue) names \(asset.fileName)"
            )
        }
        return asset
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .drawn(let drawn):
            try container.encode(drawn.rawValue, forKey: .kind)
        case .image(let asset):
            try container.encode(Self.imageKind, forKey: .kind)
            try container.encode(asset, forKey: .asset)
        case .pdf(let asset, let index):
            try container.encode(Self.pdfKind, forKey: .kind)
            try container.encode(asset, forKey: .asset)
            try container.encode(index, forKey: .sourcePageIndex)
        }
    }
}
