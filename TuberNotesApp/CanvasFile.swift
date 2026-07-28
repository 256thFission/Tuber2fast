import Foundation

/// The complete durable contents of a Just a Canvas document
/// (`DataContract.md` §4). There is no package, manifest, background asset,
/// drawing reference, checksum table, thumbnail, or cache.
///
/// This is a durable value type: it imports Foundation only. It knows nothing
/// about PencilKit — `drawingData` is opaque bytes to everything except the
/// canvas owner.
struct CanvasFile: Codable, Sendable, Equatable {
    let formatVersion: UInt32
    let documentID: UUID
    let pageID: UUID
    let pageWidth: Double
    let pageHeight: Double
    let drawingData: Data

    static let currentFormatVersion: UInt32 = 1
}

enum CanvasFileError: Error, Equatable {
    case unsupportedFormatVersion(UInt32)
    case invalidGeometry(width: Double, height: Double)
}

extension CanvasFile {
    /// Every field the contract constrains, checked in one place.
    ///
    /// A grown height is not a new format: a file at the initial height and a
    /// file at a grown height are both valid version 1, so there is nothing to
    /// migrate.
    func validated() throws -> CanvasFile {
        guard formatVersion == Self.currentFormatVersion else {
            throw CanvasFileError.unsupportedFormatVersion(formatVersion)
        }
        guard pageWidth.isFinite,
              pageWidth > 0,
              PageGeometry.isValidHeight(pageHeight),
              pageWidth < pageHeight
        else {
            throw CanvasFileError.invalidGeometry(width: pageWidth, height: pageHeight)
        }
        return self
    }
}
