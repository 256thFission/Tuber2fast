import Foundation

struct PageAnnotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let pageID: UUID
    let threadID: UUID
    var target: PageNormalizedPoint
    var targetRegion: PageNormalizedRect?
    var kind: AnnotationKind
    var teaser: String
    var body: String
    var citations: [Citation]
    var status: AnnotationStatus
}

enum AnnotationKind: String, Codable, Equatable, Sendable {
    case confirmation
    case issue
    case explanation
    case source
    case uncertainty
    case suggestion
}

enum AnnotationStatus: String, Codable, Equatable, Sendable {
    case streaming
    case complete
    case failed
}

struct Citation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var pageNumber: Int?
    var url: URL?
    var excerpt: String?
}

struct PinDraft: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var target: CropNormalizedPoint
    var targetRegion: CropNormalizedRect?
    var kind: AnnotationKind
    var teaser: String
    var body: String
    var citations: [Citation]
}
