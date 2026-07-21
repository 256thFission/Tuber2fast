import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        guard case let .failed(message) = self else { return "failed" }
        return message
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

@main
private enum PC28CitationNavigationChecks {
    static func main() {
        do {
            let worksheetID = UUID(uuidString: "88000000-0000-0000-0000-000000000001")!
            let textbookID = UUID(uuidString: "88000000-0000-0000-0000-000000000002")!
            let hit = KnowledgeHit(
                id: UUID(uuidString: "88000000-0000-0000-0000-000000000003")!,
                documentID: textbookID,
                documentTitle: "Imported Textbook",
                pageNumber: 3,
                sectionTitle: "Section",
                excerpt: "Returned local excerpt.",
                score: 1
            )
            let citation = GroundedCitation(hit: hit)

            try check(
                NotebookViewModel.validatedAgentNavigationRequest(
                    for: citation,
                    activeNotebookID: worksheetID,
                    destinationPageCount: 4
                ) == .openNotebook(notebookID: textbookID, pageIndex: 2),
                "1-based citation page should map to zero-based page index"
            )
            try check(
                NotebookViewModel.validatedAgentNavigationRequest(
                    for: citation,
                    activeNotebookID: textbookID,
                    destinationPageCount: 4
                ) == nil,
                "same-notebook citation must stay disabled"
            )
            try check(
                NotebookViewModel.validatedAgentNavigationRequest(
                    for: citation,
                    activeNotebookID: worksheetID,
                    destinationPageCount: nil
                ) == nil,
                "deleted or missing notebook must stay disabled"
            )
            try check(
                NotebookViewModel.validatedAgentNavigationRequest(
                    for: citation,
                    activeNotebookID: worksheetID,
                    destinationPageCount: 2
                ) == nil,
                "out-of-range page must stay disabled"
            )

            let zeroPageCitation = GroundedCitation(hit: KnowledgeHit(
                id: UUID(),
                documentID: textbookID,
                documentTitle: "Imported Textbook",
                pageNumber: 0,
                sectionTitle: nil,
                excerpt: "Returned local excerpt.",
                score: nil
            ))
            try check(
                NotebookViewModel.validatedAgentNavigationRequest(
                    for: zeroPageCitation,
                    activeNotebookID: worksheetID,
                    destinationPageCount: 4
                ) == nil,
                "non-positive source page must stay disabled"
            )
            let validRequest = NotebookViewModel.validatedAgentNavigationRequest(
                for: citation,
                activeNotebookID: worksheetID,
                destinationPageCount: 4
            )
            try check(
                AgentSidebarView.canOpenCitation(
                    request: validRequest,
                    hasNavigationHandler: true
                ),
                "origin notebook should enable a valid citation when routing exists"
            )
            try check(
                !AgentSidebarView.canOpenCitation(
                    request: validRequest,
                    hasNavigationHandler: false
                ),
                "pushed target notebook must disable citation chips when multi-hop routing is absent"
            )

            print("PASS PC-28 citation navigation validation checks")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
