import Foundation

/// Top-left-origin point normalized over the complete logical page.
struct PageNormalizedPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    var isFiniteAndInUnitBounds: Bool {
        x.isFinite && y.isFinite && (0 ... 1).contains(x) && (0 ... 1).contains(y)
    }
}

/// Top-left-origin rectangle normalized over the complete logical page.
struct PageNormalizedRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var isFiniteAndInUnitBounds: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0
            && y >= 0
            && width >= 0
            && height >= 0
            && x + width <= 1
            && y + height <= 1
    }
}

/// Top-left-origin point normalized over the encoded selection crop.
struct CropNormalizedPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    var isFiniteAndInUnitBounds: Bool {
        x.isFinite && y.isFinite && (0 ... 1).contains(x) && (0 ... 1).contains(y)
    }
}

/// Top-left-origin rectangle normalized over the encoded selection crop.
struct CropNormalizedRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var isFiniteAndInUnitBounds: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0
            && y >= 0
            && width >= 0
            && height >= 0
            && x + width <= 1
            && y + height <= 1
    }
}

struct SelectionArtifact: Identifiable, Equatable, Sendable {
    let id: UUID
    let documentID: UUID
    let pageID: UUID
    let pageIndex: Int
    let lassoPath: [PageNormalizedPoint]
    let pageBounds: PageNormalizedRect
    let crop: SelectionCrop
    /// Optional orientation-only evidence. Provider coordinates always refer
    /// to `crop`; this image can never justify a target outside `crop.pageBounds`.
    var contextCrop: SelectionCrop? = nil
    let context: SelectionContext
}

struct SelectionCrop: Equatable, Sendable {
    let imageData: Data
    let mediaType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let pageBounds: PageNormalizedRect
}

struct SelectionContext: Codable, Equatable, Sendable {
    var documentTitle: String?
    var sourceDocumentID: UUID?
    var pageNumber: Int?
    var nearbyText: String?
}
