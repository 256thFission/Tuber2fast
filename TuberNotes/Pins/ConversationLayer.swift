import Foundation

/// A persisted, note-local surface for spatial conversations.
/// Agent execution remains outside this UI model.
struct ConversationLayer: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var symbolName: String
    var conversations: [Pin]
    var isVisible = true
}

struct NoteConversationLayers: Codable, Equatable {
    let noteID: UUID
    var layers: [ConversationLayer]
}
