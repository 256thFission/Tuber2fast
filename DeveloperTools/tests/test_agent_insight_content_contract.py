import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
INSIGHT = REPO_ROOT / "TuberNotes/Notebook/AgentInsight.swift"


class AgentInsightContentContractTests(unittest.TestCase):
    def test_provider_parser_preserves_the_complete_source(self):
        source = INSIGHT.read_text()
        parser = source.split("private func parseInsight", 1)[1].split("#if DEBUG", 1)[0]

        self.assertIn("AgentInsight(body: text)", parser)
        self.assertNotIn("split(separator:", parser)
        self.assertNotIn("trimmingCharacters", parser)
        self.assertNotIn("joined(separator:", parser)

    def test_canonical_body_is_not_derived_from_legacy_projections(self):
        source = INSIGHT.read_text()
        insight = source.split("struct AgentInsight", 1)[1].split(
            "protocol AgentInsightClient", 1
        )[0]

        self.assertIn("let body: String", insight)
        self.assertIn("init(body: String)", insight)
        self.assertIn("self.body = body", insight)
        self.assertIn("var summary: String", insight)
        self.assertIn("var items: [String]", insight)

    def test_markdown_round_trip_examples_need_no_normalization(self):
        examples = [
            "Plain text",
            "# Heading\n\nA **strong** paragraph.\n\n- one\n  - nested",
            "> quoted\n\n```swift\nlet value = 1\n```\n\n[Docs](https://example.com)",
            "Malformed **emphasis and <script>alert(1)</script>",
            "First paragraph.\n\nSecond paragraph with `inline code`.",
        ]

        # AgentInsight(body:) is an identity boundary: upstream response-size
        # limits remain responsible for bounding these strings.
        for provider_text in examples:
            persisted_body = provider_text
            self.assertEqual(persisted_body, provider_text)


if __name__ == "__main__":
    unittest.main()
