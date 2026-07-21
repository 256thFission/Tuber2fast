import Foundation

private enum PC25CheckFailure: Error {
    case failed(String)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PC25CheckFailure.failed(message) }
}

@main
private struct PC25CorpusChecks {
    static func main() async throws {
        let documentID = UUID(uuidString: "84000000-0000-0000-0000-000000000001")!
        let pages = OfflineKnowledgeCorpus.pages(
            documentID: documentID,
            documentTitle: "Organic Chemistry",
            pageTexts: [
                "Nucleophilic substitution by the SN2 mechanism uses backside attack.",
                nil,
                "   \n\t",
                "Steric hindrance slows reaction at a substituted carbon."
            ]
        )

        try require(pages.count == 2, "text extraction should omit image-only and blank pages")
        try require(pages.map(\.pageNumber) == [1, 4], "corpus should retain 1-based PDF page numbers")
        try require(pages.allSatisfy { $0.documentID == documentID }, "corpus should retain notebook identity")
        try require(
            pages.allSatisfy { $0.documentTitle == "Organic Chemistry" },
            "corpus should retain notebook title"
        )

        let corpusData = try JSONEncoder().encode(pages)
        let importedSearcher = try OfflineTextbookKnowledgeSearcher.resolvingImportedCorpus(corpusData)
        let hits = try await importedSearcher.searchTextbook(
            KnowledgeQuery(documentID: documentID, text: "SN2 backside attack", limit: 5)
        )
        try require(hits.first?.pageNumber == 1, "import extraction output should find its source PDF page")

        let imageOnlyCorpusData = try JSONEncoder().encode(
            OfflineKnowledgeCorpus.pages(
                documentID: documentID,
                documentTitle: "Scanned Textbook",
                pageTexts: [nil, "  "]
            )
        )
        let imageOnlySearcher = try OfflineTextbookKnowledgeSearcher.resolvingImportedCorpus(imageOnlyCorpusData)
        let imageOnlyHits = try await imageOnlySearcher.searchTextbook(
            KnowledgeQuery(documentID: nil, text: "inverse operation", limit: 5)
        )
        try require(imageOnlyHits.isEmpty, "image-only corpus must not produce empty entries or fixture hits")

        let fixtureSearcher = try OfflineTextbookKnowledgeSearcher.resolvingImportedCorpus(nil)
        let fixtureHits = try await fixtureSearcher.searchTextbook(
            KnowledgeQuery(documentID: nil, text: "inverse operation", limit: 5)
        )
        try require(fixtureHits.first?.pageNumber == 12, "only a missing sidecar should use the fixture")

        do {
            _ = try OfflineTextbookKnowledgeSearcher.resolvingImportedCorpus(Data("not-json".utf8))
            throw PC25CheckFailure.failed("malformed imported corpus should fail")
        } catch OfflineKnowledgeCorpusError.malformedCorpus {
            // Expected: corrupt imported content must never fall back to the fixture.
        }

        print("PC25_CORPUS_CHECKS: PASS")
    }
}
