import Foundation

/// A virtual, note-local surface for spatial conversations.
/// Agent execution and durable persistence intentionally live outside this UI model.
struct ConversationLayer: Identifiable, Equatable {
    let id: UUID
    var name: String
    var symbolName: String
    var conversations: [Pin]
}

struct NoteConversationLayers: Equatable {
    let noteID: UUID
    var layers: [ConversationLayer]
}
