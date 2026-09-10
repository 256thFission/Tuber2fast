import Foundation
import TNModel

/// `layers/<LayerID>.json`: `{ layerID, kind, transform, <kind>: payload }`.
///
/// The payload object is keyed by the kind's name so an unknown kind is
/// seen, and refused as a layer rather than as corruption, before its
/// payload is parsed.
package enum LayerFile {
    private struct Head: Decodable {
        let layerID: LayerID
        let kind: String
    }

    private struct Body<Payload: Codable>: Codable {
        let layerID: LayerID
        let kind: String
        let transform: PageSpaceTransform
        let payload: Payload
    }

    package static func encode(_ layer: Layer) throws(FormatFault) -> Data {
        // Encode the shared head and the kind-keyed payload into one object
        // by way of a dictionary, so the payload key is the kind's name.
        let encoder = Codecs.encoder()
        let payloadData: Data
        do {
            switch layer.payload {
            case .image(let image): payloadData = try encoder.encode(image)
            case .pdf(let pdf): payloadData = try encoder.encode(pdf)
            case .link(let link): payloadData = try encoder.encode(link)
            }
        } catch {
            throw .corruptJSON("layer payload encode failed: \(error)")
        }
        let transformData = try Codecs.encode(layer.transform)
        let payloadObject: Any
        let transformObject: Any
        do {
            payloadObject = try JSONSerialization.jsonObject(with: payloadData)
            transformObject = try JSONSerialization.jsonObject(with: transformData)
        } catch {
            throw .corruptJSON("layer reserialize failed: \(error)")
        }
        let object: [String: Any] = [
            "layerID": layer.id.raw.uuidString,
            "kind": layer.payload.kind.rawValue,
            "transform": transformObject,
            layer.payload.kind.rawValue: payloadObject,
        ]
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw .corruptJSON("layer serialize failed: \(error)")
        }
    }

    /// A layer, or why this file is not one. Corruption and unknown kinds
    /// are both faults of the layer, never of the page file or the notebook.
    package static func decode(_ data: Data, expecting expected: LayerID) -> Result<Layer, LayerFault> {
        let head: Head
        do {
            head = try Codecs.decoder().decode(Head.self, from: data)
        } catch {
            return .failure(.fileUnreadable(expected, String(describing: error)))
        }
        guard head.layerID == expected else {
            return .failure(.idMismatch(expected: expected, found: head.layerID))
        }
        guard let kind = LayerKind(rawValue: head.kind) else {
            return .failure(.unknownKind(expected, kind: head.kind))
        }
        let keys: Set<String>
        do {
            keys = try Codecs.topLevelKeys(of: data)
        } catch {
            return .failure(.fileUnreadable(expected, error.description))
        }
        let expectedKeys = DurableKeys.layerFile(kind: kind.rawValue)
        guard keys == expectedKeys else {
            let difference = keys.symmetricDifference(expectedKeys).sorted().joined(separator: ",")
            return .failure(.fileUnreadable(expected, "key set differs: \(difference)"))
        }
        do {
            let layer: Layer
            switch kind {
            case .image:
                let body = try decodeBody(ImageLayer.self, kind: kind, from: data)
                layer = Layer(id: body.layerID, transform: body.transform, payload: .image(body.payload))
            case .pdf:
                let body = try decodeBody(PDFLayer.self, kind: kind, from: data)
                layer = Layer(id: body.layerID, transform: body.transform, payload: .pdf(body.payload))
            case .link:
                let body = try decodeBody(LinkLayer.self, kind: kind, from: data)
                layer = Layer(id: body.layerID, transform: body.transform, payload: .link(body.payload))
            }
            return .success(try layer.validated())
        } catch let fault as LayerFault {
            return .failure(fault)
        } catch {
            return .failure(.fileUnreadable(expected, String(describing: error)))
        }
    }

    private static func decodeBody<P: Codable>(_: P.Type, kind: LayerKind, from data: Data) throws -> Body<P> {
        let raw = try Codecs.decoder().decode(RawLayer<P>.self, from: data)
        return Body(layerID: raw.layerID, kind: raw.kind, transform: raw.transform, payload: raw.payload)
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// The layer file with its payload read from the key named by `kind`.
private struct RawLayer<P: Decodable>: Decodable {
    let layerID: LayerID
    let kind: String
    let transform: PageSpaceTransform
    let payload: P

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        layerID = try container.decode(LayerID.self, forKey: AnyKey(stringValue: "layerID"))
        kind = try container.decode(String.self, forKey: AnyKey(stringValue: "kind"))
        transform = try container.decode(PageSpaceTransform.self, forKey: AnyKey(stringValue: "transform"))
        payload = try container.decode(P.self, forKey: AnyKey(stringValue: kind))
    }
}
