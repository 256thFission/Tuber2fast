import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

@main
private enum PC27GroundedCitationChecks {
    static func main() throws {
        let hit = KnowledgeHit(
            id: UUID(uuidString: "27000000-0000-0000-0000-000000000001")!,
            documentID: UUID(uuidString: "27000000-0000-0000-0000-000000000002")!,
            documentTitle: "Organic Chemistry Ch. 11",
            pageNumber: 214,
            sectionTitle: "11.3 Stereochemistry of SN2",
            excerpt: "The nucleophile attacks from the side opposite the leaving group.",
            score: 0.97
        )
        let citation = GroundedCitation(hit: hit)
        try check(citation.id == hit.id, "citation id must be copied from the hit")
        try check(citation.documentID == hit.documentID, "document id must be copied from the hit")
        try check(citation.documentTitle == hit.documentTitle, "title must be copied from the hit")
        try check(citation.pageNumber == hit.pageNumber, "page must be copied from the hit")
        try check(citation.sectionTitle == hit.sectionTitle, "section must be copied from the hit")
        try check(citation.excerpt == hit.excerpt, "excerpt must be copied from the hit")

        let legacyRoot = """
        {
          "id":"27000000-0000-0000-0000-000000000003",
          "pageID":"27000000-0000-0000-0000-000000000004",
          "threadID":"27000000-0000-0000-0000-000000000005",
          "target":{"x":0.5,"y":0.5},
          "kind":"explanation",
          "teaser":"Legacy root",
          "body":"Legacy response",
          "citations":[],
          "status":"complete"
        }
        """
        let root = try JSONDecoder().decode(PageAnnotation.self, from: Data(legacyRoot.utf8))
        try check(root.groundedCitation == nil, "legacy root must decode without a grounded citation")

        let legacyFollowUp = """
        {
          "id":"27000000-0000-0000-0000-000000000006",
          "parentMessageID":"27000000-0000-0000-0000-000000000005",
          "userPrompt":"Why?",
          "body":"Legacy follow-up"
        }
        """
        let followUp = try JSONDecoder().decode(PinConversationMessage.self, from: Data(legacyFollowUp.utf8))
        try check(followUp.groundedCitation == nil, "legacy follow-up must decode without a grounded citation")

        let groundedRoot = PageAnnotation(
            id: UUID(),
            pageID: UUID(),
            threadID: UUID(),
            target: PageNormalizedPoint(x: 0.5, y: 0.5),
            kind: .explanation,
            teaser: "Grounded root",
            body: "Grounded response",
            citations: [],
            groundedCitation: citation,
            status: .complete
        )
        let rootRoundTrip = try JSONDecoder().decode(
            PageAnnotation.self,
            from: JSONEncoder().encode(groundedRoot)
        )
        try check(rootRoundTrip.groundedCitation == citation, "root citation must round-trip exactly")

        let groundedFollowUp = PinConversationMessage(
            id: UUID(),
            parentMessageID: groundedRoot.threadID,
            userPrompt: "Why?",
            body: "Because…",
            groundedCitation: citation
        )
        let followUpRoundTrip = try JSONDecoder().decode(
            PinConversationMessage.self,
            from: JSONEncoder().encode(groundedFollowUp)
        )
        try check(followUpRoundTrip.groundedCitation == citation, "follow-up citation must round-trip exactly")

        print("PC-27 grounded citation contract checks passed")
    }
}
