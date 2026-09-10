import Foundation

/// The paper a page is ruled with: a name and nothing more. Spacing, colour,
/// and margins are rendering constants of the build that draws them.
package enum Paper: String, Codable, Sendable, Equatable, CaseIterable {
    case blank, lined, grid, dotted
}

/// What the index carries: a known paper, or the name of one this build
/// does not have. Unknown refuses the page, never the notebook.
package enum PaperKind: Sendable, Equatable {
    case known(Paper)
    case unknown(String)

    package var paper: Paper? {
        if case .known(let paper) = self { return paper }
        return nil
    }

    package var rawKind: String {
        switch self {
        case .known(let paper): paper.rawValue
        case .unknown(let name): name
        }
    }
}

/// The on-disk shape `{ "kind": "lined" }`, keyed by kind so a future
/// parameterized paper adds keys beside `kind` rather than a new form.
extension PaperKind: Codable {
    private enum CodingKeys: String, CodingKey { case kind }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .kind)
        self = Paper(rawValue: name).map(PaperKind.known) ?? .unknown(name)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawKind, forKey: .kind)
    }
}
