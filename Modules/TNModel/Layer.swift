import Foundation

/// A static layer beneath (or, by `inkIndex`, among) a page's ink. The set of
/// kinds is closed in code and open on disk: an unknown kind refuses the
/// layer, and the page carrying it is a placeholder.
package enum LayerKind: String, Codable, Sendable, CaseIterable {
    case image, pdf, link
}

package enum AssetFormat: String, Codable, Sendable, CaseIterable {
    case heic, pdf
}

/// An asset named by its file name, `<AssetID>.<format>`, which is the only
/// statement of the asset's format anywhere in the package.
package struct AssetRef: Hashable, Sendable, Codable {
    package let id: AssetID
    package let format: AssetFormat

    package init(id: AssetID, format: AssetFormat) {
        self.id = id
        self.format = format
    }

    package var fileName: String { "\(id.raw.uuidString).\(format.rawValue)" }

    package init?(fileName: String) {
        let parts = fileName.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let uuid = UUID.canonical(parts[0]),
              let format = AssetFormat(rawValue: parts[1])
        else { return nil }
        self.init(id: AssetID(raw: uuid), format: format)
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let ref = AssetRef(fileName: name) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "asset name is not <UUID>.<heic|pdf>: \(name)"
            )
        }
        self = ref
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fileName)
    }
}

package struct PixelSize: Codable, Sendable, Equatable {
    package let width: Int
    package let height: Int
    package init(width: Int, height: Int) { self.width = width; self.height = height }
    package var isValid: Bool {
        width > 0 && height > 0 && width <= AssetBounds.maxPixelEdge && height <= AssetBounds.maxPixelEdge
    }
}

package enum AssetBounds {
    package static let maxBytes: Int = 64 * 1024 * 1024
    package static let maxPixelEdge: Int = 16384
}

package struct PageRect: Codable, Sendable, Equatable {
    package let x: Double
    package let y: Double
    package let width: Double
    package let height: Double
    package init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    package var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

package struct ImageLayer: Codable, Sendable, Equatable {
    package let asset: AssetRef
    package let naturalSize: PixelSize
    package init(asset: AssetRef, naturalSize: PixelSize) {
        self.asset = asset
        self.naturalSize = naturalSize
    }
}

/// The displayed source rectangle of a PDF page at import, post-rotation.
/// The render path re-derives it and refuses the layer on disagreement, so
/// a change of box policy can never move a worksheet under committed ink.
package struct SourceExtent: Codable, Sendable, Equatable {
    package let x: Double
    package let y: Double
    package let width: Double
    package let height: Double
    /// Degrees, one of 0, 90, 180, 270.
    package let rotation: Int
    package init(x: Double, y: Double, width: Double, height: Double, rotation: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.rotation = rotation
    }
    package var isValid: Bool {
        PageRect(x: x, y: y, width: width, height: height).isValid && [0, 90, 180, 270].contains(rotation)
    }
}

package struct PDFLayer: Codable, Sendable, Equatable {
    package let asset: AssetRef
    package let sourcePageIndex: Int
    package let sourceExtent: SourceExtent
    package init(asset: AssetRef, sourcePageIndex: Int, sourceExtent: SourceExtent) {
        self.asset = asset
        self.sourcePageIndex = sourcePageIndex
        self.sourceExtent = sourceExtent
    }
}

/// A link target: page-relative inside the notebook so Duplicate keeps it
/// internal, or absolute across notebooks.
package enum LinkTarget: Sendable, Equatable {
    case internalPage(PageID)
    case externalPage(notebook: NotebookID, page: PageID)
}

extension LinkTarget: Codable {
    private enum CodingKeys: String, CodingKey { case scope, pageID, notebookID }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scope = try container.decode(String.self, forKey: .scope)
        let page = try container.decode(PageID.self, forKey: .pageID)
        switch scope {
        case "internal":
            guard !container.contains(.notebookID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .notebookID, in: container,
                    debugDescription: "an internal link target carries no notebookID"
                )
            }
            self = .internalPage(page)
        case "external":
            self = .externalPage(notebook: try container.decode(NotebookID.self, forKey: .notebookID), page: page)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .scope, in: container, debugDescription: "unknown link scope \(scope)"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .internalPage(let page):
            try container.encode("internal", forKey: .scope)
            try container.encode(page, forKey: .pageID)
        case .externalPage(let notebook, let page):
            try container.encode("external", forKey: .scope)
            try container.encode(notebook, forKey: .notebookID)
            try container.encode(page, forKey: .pageID)
        }
    }
}

package enum LinkStyle: String, Codable, Sendable, CaseIterable {
    case button
}

package struct LinkLayer: Codable, Sendable, Equatable {
    package let rect: PageRect
    package let style: LinkStyle
    package let target: LinkTarget
    package init(rect: PageRect, style: LinkStyle, target: LinkTarget) {
        self.rect = rect
        self.style = style
        self.target = target
    }
}

package enum LayerPayload: Sendable, Equatable {
    case image(ImageLayer)
    case pdf(PDFLayer)
    case link(LinkLayer)

    package var kind: LayerKind {
        switch self {
        case .image: .image
        case .pdf: .pdf
        case .link: .link
        }
    }

    package var asset: AssetRef? {
        switch self {
        case .image(let image): image.asset
        case .pdf(let pdf): pdf.asset
        case .link: nil
        }
    }
}

/// One static layer: identity, placement, and a kind-specific payload.
package struct Layer: Sendable, Equatable, Identifiable {
    package let id: LayerID
    package let transform: PageSpaceTransform
    package let payload: LayerPayload

    package init(id: LayerID, transform: PageSpaceTransform, payload: LayerPayload) {
        self.id = id
        self.transform = transform
        self.payload = payload
    }

    /// Every rule a layer's own bytes can violate, checked in one place.
    package func validated() throws(LayerFault) -> Layer {
        guard transform.isValid else { throw .invalidTransform(id) }
        switch payload {
        case .image(let image):
            guard image.naturalSize.isValid else { throw .invalidNaturalSize(id) }
        case .pdf(let pdf):
            guard pdf.sourcePageIndex >= 0 else { throw .negativeSourcePageIndex(id) }
            guard pdf.sourceExtent.isValid else { throw .invalidSourceExtent(id) }
        case .link(let link):
            guard transform.isIdentity else { throw .linkTransformNotIdentity(id) }
            guard link.rect.isValid else { throw .invalidLinkRect(id) }
        }
        return self
    }

    package func withTransform(_ transform: PageSpaceTransform) -> Layer {
        Layer(id: id, transform: transform, payload: payload)
    }
}

/// Why a layer was refused. Every case names its layer; the page carrying
/// one is a placeholder.
package enum LayerFault: Error, Sendable, Equatable {
    case unknownKind(LayerID, kind: String)
    case fileMissing(LayerID)
    case fileUnreadable(LayerID, String)
    case idMismatch(expected: LayerID, found: LayerID)
    case invalidTransform(LayerID)
    case invalidNaturalSize(LayerID)
    case negativeSourcePageIndex(LayerID)
    case invalidSourceExtent(LayerID)
    case linkTransformNotIdentity(LayerID)
    case invalidLinkRect(LayerID)
    case danglingAsset(LayerID, AssetRef)
    case sourceExtentDisagrees(LayerID)

    package var layerID: LayerID {
        switch self {
        case .unknownKind(let id, _), .fileMissing(let id), .fileUnreadable(let id, _),
             .invalidTransform(let id), .invalidNaturalSize(let id), .negativeSourcePageIndex(let id),
             .invalidSourceExtent(let id), .linkTransformNotIdentity(let id), .invalidLinkRect(let id),
             .danglingAsset(let id, _), .sourceExtentDisagrees(let id):
            id
        case .idMismatch(let expected, _):
            expected
        }
    }
}
