import Foundation
import TNModel

/// `layers/<LayerID>.json`: `{ layerID, kind, transform, locked, <kind>: payload }`.
///
/// The payload object is keyed by the kind's name so the kind is checked
/// before its payload is parsed. One encoder and one decoder, both the
/// format's.
package enum LayerFile {
    package static func encode(_ layer: Layer) throws(FormatFault) -> Data {
        switch layer.payload {
        case .image(let image): try Codecs.encode(Body(layer: layer, payload: image))
        case .pdf(let pdf): try Codecs.encode(Body(layer: layer, payload: pdf))
        case .link(let link): try Codecs.encode(Body(layer: layer, payload: link))
        case .text(let text): try Codecs.encode(Body(layer: layer, payload: text))
        }
    }

    /// A layer, or why this file is not one. Corruption, a kind this build
    /// does not write among it, is the layer's fault, never the page file's
    /// or the notebook's.
    package static func decode(_ data: Data, expecting expected: LayerID) -> Result<Layer, LayerFault> {
        let object: [String: Any]
        do {
            object = try Codecs.topLevelObject(of: data)
        } catch {
            return .failure(.fileUnreadable(expected, error.description))
        }
        guard let idString = object["layerID"] as? String, let uuid = UUID.canonical(idString) else {
            return .failure(.fileUnreadable(expected, "layerID is not a canonical UUID"))
        }
        let found = LayerID(raw: uuid)
        guard found == expected else { return .failure(.idMismatch(expected: expected, found: found)) }
        guard let kindName = object["kind"] as? String else {
            return .failure(.fileUnreadable(expected, "missing key kind"))
        }
        guard let kind = LayerKind(rawValue: kindName) else {
            return .failure(.fileUnreadable(expected, "layer kind \(kindName) is not one this build writes"))
        }
        do {
            try Codecs.checkKeys(Set(object.keys), against: DurableKeys.layerFile(kind: kind.rawValue))
            let layer: Layer
            switch kind {
            case .image:
                let body = try Codecs.decode(Body<ImageLayer>.self, from: data)
                layer = Layer(id: body.layerID, transform: body.transform, payload: .image(body.payload), locked: body.locked)
            case .pdf:
                let body = try Codecs.decode(Body<PDFLayer>.self, from: data)
                layer = Layer(id: body.layerID, transform: body.transform, payload: .pdf(body.payload), locked: body.locked)
            case .link:
                let body = try Codecs.decode(Body<LinkLayer>.self, from: data)
                layer = Layer(id: body.layerID, transform: body.transform, payload: .link(body.payload), locked: body.locked)
            case .text:
                let body = try Codecs.decode(Body<TextLayer>.self, from: data)
                layer = Layer(id: body.layerID, transform: body.transform, payload: .text(body.payload), locked: body.locked)
            }
            return .success(try layer.validated())
        } catch let fault as LayerFault {
            return .failure(fault)
        } catch let fault as FormatFault {
            return .failure(.fileUnreadable(expected, fault.description))
        } catch {
            return .failure(.fileUnreadable(expected, String(describing: error)))
        }
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// The layer file's shape, with the payload under the key named by `kind`.
private struct Body<Payload: Codable>: Codable {
    let layerID: LayerID
    let kind: String
    let transform: PageSpaceTransform
    let locked: Bool
    let payload: Payload

    init(layer: Layer, payload: Payload) {
        self.layerID = layer.id
        self.kind = layer.payload.kind.rawValue
        self.transform = layer.transform
        self.locked = layer.locked
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        layerID = try container.decode(LayerID.self, forKey: AnyKey(stringValue: "layerID"))
        kind = try container.decode(String.self, forKey: AnyKey(stringValue: "kind"))
        transform = try container.decode(PageSpaceTransform.self, forKey: AnyKey(stringValue: "transform"))
        locked = try container.decode(Bool.self, forKey: AnyKey(stringValue: "locked"))
        payload = try container.decode(Payload.self, forKey: AnyKey(stringValue: kind))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(layerID, forKey: AnyKey(stringValue: "layerID"))
        try container.encode(kind, forKey: AnyKey(stringValue: "kind"))
        try container.encode(transform, forKey: AnyKey(stringValue: "transform"))
        try container.encode(locked, forKey: AnyKey(stringValue: "locked"))
        try container.encode(payload, forKey: AnyKey(stringValue: kind))
    }
}
