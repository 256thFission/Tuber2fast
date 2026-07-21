import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "TuberNotes" / "Notebook" / "MarkdownMessageView.swift"


class MarkdownMessageContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text()

    def test_renderer_is_bounded_and_preserves_source(self):
        self.assertIn("let source: String", self.source)
        self.assertIn("maximumInputCharacters = 100_000", self.source)
        self.assertIn("maximumBlocks = 2_000", self.source)
        self.assertIn("maximumNesting = 4", self.source)
        self.assertIn("maximumBlockCharacters = 10_000", self.source)

    def test_unsafe_content_has_no_loading_or_execution_surface(self):
        for forbidden in ("AsyncImage", "WebView", "WKWebView", "JavaScript", "UIApplication.shared.open"):
            self.assertNotIn(forbidden, self.source)
        self.assertIn('scheme == "http" || scheme == "https"', self.source)
        self.assertIn('case "<": output += "&lt;"', self.source)
        self.assertIn('"Image omitted"', self.source)

    def test_projection_and_required_block_styles_exist(self):
        self.assertIn("enum MarkdownTextProjection", self.source)
        for kind in ("case paragraph", "case heading", "case listItem", "case quote", "case code"):
            self.assertIn(kind, self.source)
        self.assertIn("inlineOnlyPreservingWhitespace", self.source)
        self.assertIn(".textSelection(.enabled)", self.source)
        self.assertIn("ScrollView(.horizontal)", self.source)


if __name__ == "__main__":
    unittest.main()
