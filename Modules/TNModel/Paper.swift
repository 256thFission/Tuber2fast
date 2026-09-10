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

/// What the index carries: a known paper, or the name of a kind this build
/// does not have. Unknown refuses the page, never the notebook.
package enum PaperKind: Sendable, Equatable {
    case known(Paper)
    case unknown(String)

    package var paper: Paper? {
        if case .known(let paper) = self { return paper }
        return nil
    }

    /// The two kind names that are not a `DrawnPaper` case.
    package static let imageKind = "image"
    package static let pdfKind = "pdf"

    package static func isKnownKind(_ name: String) -> Bool {
        name == imageKind || name == pdfKind || DrawnPaper(rawValue: name) != nil
    }

    package var rawKind: String {
        switch self {
        case .known(.drawn(let drawn)): drawn.rawValue
        case .known(.image): Self.imageKind
        case .known(.pdf): Self.pdfKind
        case .unknown(let name): name
        }
    }
}

/// The on-disk shape, keyed by kind so an unknown kind is seen before any
/// payload key is looked at: `{ "kind": "lined" }`,
/// `{ "kind": "image", "asset": "UUID.heic" }`,
/// `{ "kind": "pdf", "asset": "UUID.pdf", "sourcePageIndex": 3 }`.
extension PaperKind: Codable {
    private enum CodingKeys: String, CodingKey { case kind, asset, sourcePageIndex }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .kind)
        switch name {
        case Self.imageKind:
            self = .known(.image(try Self.asset(.heic, from: container)))
        case Self.pdfKind:
            let index = try container.decode(Int.self, forKey: .sourcePageIndex)
            guard index >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sourcePageIndex, in: container, debugDescription: "sourcePageIndex is negative: \(index)"
                )
            }
            self = .known(.pdf(try Self.asset(.pdf, from: container), sourcePageIndex: index))
        default:
            self = DrawnPaper(rawValue: name).map { .known(.drawn($0)) } ?? .unknown(name)
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
        try container.encode(rawKind, forKey: .kind)
        switch self {
        case .known(.image(let asset)):
            try container.encode(asset, forKey: .asset)
        case .known(.pdf(let asset, let index)):
            try container.encode(asset, forKey: .asset)
            try container.encode(index, forKey: .sourcePageIndex)
        case .known(.drawn), .unknown:
            break
        }
    }
}
