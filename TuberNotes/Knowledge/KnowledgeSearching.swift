import Foundation

protocol KnowledgeSearching: Sendable {
    func searchTextbook(_ query: KnowledgeQuery) async throws -> [KnowledgeHit]
}

enum OfflineKnowledgeCorpusError: Error, Equatable {
    case missingCorpus
    case malformedCorpus
    case invalidCorpus
}

/// A preprocessed page in the small offline textbook corpus. The page identity becomes the
/// stable `KnowledgeHit` identity, so repeated searches return the same result IDs.
struct OfflineKnowledgePage: Codable, Equatable, Sendable {
    let id: UUID
    let documentID: UUID
    let documentTitle: String
    let pageNumber: Int
    let sectionTitle: String?
    let excerpt: String
}

/// Deterministic lexical textbook search for offline demos and AgentHarness recordings.
struct OfflineTextbookKnowledgeSearcher: KnowledgeSearching {
    private let pages: [OfflineKnowledgePage]

    init() {
        pages = Self.fixturePages
    }

    init(corpusData: Data?) throws {
        guard let corpusData else {
            throw OfflineKnowledgeCorpusError.missingCorpus
        }

        let decoded: [OfflineKnowledgePage]
        do {
            decoded = try JSONDecoder().decode([OfflineKnowledgePage].self, from: corpusData)
        } catch {
            throw OfflineKnowledgeCorpusError.malformedCorpus
        }
        try Self.validate(decoded)
        pages = decoded
    }

    init(pages: [OfflineKnowledgePage]) throws {
        try Self.validate(pages)
        self.pages = pages
    }

    func searchTextbook(_ query: KnowledgeQuery) async throws -> [KnowledgeHit] {
        let queryTerms = Self.terms(in: query.text)
        guard query.limit > 0, !queryTerms.isEmpty else { return [] }

        let normalizedPhrase = Self.normalized(query.text)
        let candidates = pages.lazy.filter { page in
            query.documentID == nil || page.documentID == query.documentID
        }

        return candidates.compactMap { page -> KnowledgeHit? in
            let searchableText = [page.documentTitle, page.sectionTitle, page.excerpt]
                .compactMap { $0 }
                .joined(separator: " ")
            let pageTerms = Self.terms(in: searchableText)
            let matches = queryTerms.reduce(into: 0) { count, term in
                if pageTerms.contains(term) { count += 1 }
            }
            guard matches > 0 else { return nil }

            let phraseBonus = Self.normalized(searchableText).contains(normalizedPhrase) ? 1.0 : 0.0
            let score = Double(matches) / Double(queryTerms.count) + phraseBonus
            return KnowledgeHit(
                id: page.id,
                documentID: page.documentID,
                documentTitle: page.documentTitle,
                pageNumber: page.pageNumber,
                sectionTitle: page.sectionTitle,
                excerpt: page.excerpt,
                score: score
            )
        }
        .sorted(by: Self.precedes)
        .prefix(query.limit)
        .map { $0 }
    }

    private static func validate(_ pages: [OfflineKnowledgePage]) throws {
        guard !pages.isEmpty,
              Set(pages.map(\.id)).count == pages.count,
              pages.allSatisfy({
                  $0.pageNumber > 0
                      && !$0.documentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw OfflineKnowledgeCorpusError.invalidCorpus
        }
    }

    private static func precedes(_ lhs: KnowledgeHit, _ rhs: KnowledgeHit) -> Bool {
        let leftScore = lhs.score ?? 0
        let rightScore = rhs.score ?? 0
        if leftScore != rightScore { return leftScore > rightScore }
        if lhs.documentTitle != rhs.documentTitle { return lhs.documentTitle < rhs.documentTitle }
        if lhs.pageNumber != rhs.pageNumber { return lhs.pageNumber < rhs.pageNumber }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func terms(in text: String) -> Set<String> {
        Set(normalized(text).split(separator: " ").map(String.init))
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        })
        .split(separator: " ")
        .joined(separator: " ")
    }

    static let algebraDocumentID = UUID(uuidString: "81000000-0000-0000-0000-000000000001")!
    static let physicsDocumentID = UUID(uuidString: "81000000-0000-0000-0000-000000000002")!

    private static let fixturePages: [OfflineKnowledgePage] = [
        OfflineKnowledgePage(
            id: UUID(uuidString: "81000000-0000-0000-0000-000000000012")!,
            documentID: algebraDocumentID,
            documentTitle: "Algebra Essentials",
            pageNumber: 12,
            sectionTitle: "Inverse Operations",
            excerpt: "Moving a term is shorthand for applying the inverse operation to both sides. A negative term becomes positive when you add its opposite to each side."
        ),
        OfflineKnowledgePage(
            id: UUID(uuidString: "81000000-0000-0000-0000-000000000018")!,
            documentID: algebraDocumentID,
            documentTitle: "Algebra Essentials",
            pageNumber: 18,
            sectionTitle: "The Distributive Property",
            excerpt: "Multiply every term inside the parentheses before combining like terms."
        ),
        OfflineKnowledgePage(
            id: UUID(uuidString: "81000000-0000-0000-0000-000000000031")!,
            documentID: algebraDocumentID,
            documentTitle: "Algebra Essentials",
            pageNumber: 31,
            sectionTitle: "Checking a Solution",
            excerpt: "Substitute the proposed solution into the original equation and compare both sides."
        ),
        OfflineKnowledgePage(
            id: UUID(uuidString: "81000000-0000-0000-0000-000000000107")!,
            documentID: physicsDocumentID,
            documentTitle: "Physics in Motion",
            pageNumber: 7,
            sectionTitle: "Acceleration",
            excerpt: "Acceleration describes the rate at which velocity changes over time."
        )
    ]
}
