import Foundation
import TNModel

/// `ink/<PageID>.tnink`: a 64-byte header and the PKDrawing archive.
///
/// Little-endian throughout. Magic `TNIK`, container version, notebook ID,
/// page ID, payload length, CRC32 of the payload, reserved zeros. The
/// container is its own integrity authority: any disagreement refuses the
/// page.
package enum InkContainer {
    package static let magic: [UInt8] = Array("TNIK".utf8)
    package static let currentVersion: UInt32 = 1
    package static let headerLength = 64

    package static func encode(notebookID: NotebookID, pageID: PageID, archive: Data) -> Data {
        var header = Data(capacity: headerLength)
        header.append(contentsOf: magic)
        header.append(littleEndian: currentVersion)
        header.append(contentsOf: uuidBytes(notebookID.raw))
        header.append(contentsOf: uuidBytes(pageID.raw))
        header.append(littleEndian: UInt64(archive.count))
        header.append(littleEndian: CRC32.checksum(archive))
        header.append(contentsOf: [UInt8](repeating: 0, count: headerLength - header.count))
        precondition(header.count == headerLength)
        return header + archive
    }

    package struct Decoded: Sendable, Equatable {
        package let notebookID: NotebookID
        package let pageID: PageID
        package let archive: Data
    }

    package static func decode(
        _ data: Data,
        expecting notebookID: NotebookID,
        page pageID: PageID
    ) throws(InkContainerFault) -> Decoded {
        guard data.count >= headerLength else { throw .tooShort }
        let bytes = [UInt8](data.prefix(headerLength))
        guard Array(bytes[0..<4]) == magic else { throw .badMagic }
        let version = UInt32(littleEndian: bytes, at: 4)
        guard version == currentVersion else { throw .unsupportedVersion(version) }
        let foundNotebook = uuid(from: bytes, at: 8)
        guard foundNotebook == notebookID.raw else { throw .notebookIDMismatch }
        let foundPage = uuid(from: bytes, at: 24)
        guard foundPage == pageID.raw else { throw .pageIDMismatch }
        let length = UInt64(littleEndian: bytes, at: 40)
        let payload = data.dropFirst(headerLength)
        guard length == UInt64(payload.count) else {
            throw .lengthMismatch(declared: length, actual: payload.count)
        }
        let crc = UInt32(littleEndian: bytes, at: 48)
        guard crc == CRC32.checksum(payload) else { throw .checksumMismatch }
        return Decoded(notebookID: notebookID, pageID: pageID, archive: Data(payload))
    }

    /// The same container under a new notebook identity. The payload and
    /// its checksum are untouched; only sixteen header bytes change, so a
    /// page need not be decodable for its identity to be corrected.
    package static func rewritingNotebookID(_ data: Data, to notebookID: NotebookID) throws(InkContainerFault) -> Data {
        guard data.count >= headerLength else { throw .tooShort }
        guard Array(data.prefix(4)) == magic else { throw .badMagic }
        var copy = data
        copy.replaceSubrange(8..<24, with: uuidBytes(notebookID.raw))
        return copy
    }

    private static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        Swift.withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    private static func uuid(from bytes: [UInt8], at offset: Int) -> UUID {
        var tuple: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        Swift.withUnsafeMutableBytes(of: &tuple) { destination in
            for i in 0..<16 { destination[i] = bytes[offset + i] }
        }
        return UUID(uuid: tuple)
    }
}

extension Data {
    fileprivate mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

extension FixedWidthInteger {
    fileprivate init(littleEndian bytes: [UInt8], at offset: Int) {
        var value: Self = 0
        for i in 0..<(Self.bitWidth / 8) {
            value |= Self(bytes[offset + i]) << (8 * i)
        }
        self = value
    }
}

/// CRC-32 (IEEE 802.3), table-driven. Small enough to own outright.
package enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
        return crc
    }

    package static func checksum<C: ContiguousBytes>(_ bytes: C) -> UInt32 {
        bytes.withUnsafeBytes { buffer in
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            return crc ^ 0xFFFF_FFFF
        }
    }
}
