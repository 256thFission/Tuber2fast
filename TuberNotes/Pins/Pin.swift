import CoreGraphics
import Foundation

/// Product-facing spatial contract. Persistent positions are page-normalized, never screen coordinates.
struct Pin: Identifiable, Equatable {
    let id: UUID
    var pagePosition: CGPoint
    var title: String
    var detail: String
}

