import Foundation

/// A persisted, note-local surface for spatial conversations.
/// Agent execution remains outside this UI model.
struct ConversationLayer: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var symbolName: String
    var conversations: [Pin]
    var isVisible = true

    private enum CodingKeys: String, CodingKey {
        case id, name, symbolName, conversations, isVisible
    }

    init(
        id: UUID,
        name: String,
        symbolName: String,
        conversations: [Pin],
        isVisible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.conversations = conversations
        self.isVisible = isVisible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbolName = try container.decode(String.self, forKey: .symbolName)
        conversations = try container.decodeIfPresent([Pin].self, forKey: .conversations) ?? []
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
    }
}

struct NoteConversationLayers: Codable, Equatable {
    let noteID: UUID
    var layers: [ConversationLayer]
}
