import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
NOTEBOOK_VIEW = REPO_ROOT / "TuberNotes/Notebook/NotebookView.swift"


class NotebookEndPullAddPageContractTests(unittest.TestCase):
    def test_last_page_forward_pull_starts_a_bounded_hold(self):
        source = NOTEBOOK_VIEW.read_text()

        self.assertIn("!vm.canGoForward, translation <= -addPageHoldActivationDistance", source)
        self.assertIn("private var addPageHoldActivationDistance: CGFloat { 72 }", source)
        self.assertIn("private var addPageHoldDuration: TimeInterval { 0.7 }", source)
        self.assertIn("withAnimation(.linear(duration: addPageHoldDuration))", source)

    def test_completion_adds_once_and_release_cancels(self):
        source = NOTEBOOK_VIEW.read_text()

        self.assertIn("!didAddPageDuringCurrentGesture", source)
        self.assertIn(
            "guard !isFlipAnimating, !didAddPageDuringCurrentGesture else { return }",
            source,
        )
        self.assertIn("didAddPageDuringCurrentGesture = true", source)
        self.assertIn("cancelAddPageHold()\n        let addedPage", source)
        self.assertIn("didAddPageDuringCurrentGesture = false", source)
        self.assertIn("if addedPage {", source)
        self.assertIn("completeAddedPageFlip(width: pageTurnDistance)", source)
        self.assertIn("vm.addPage()", source)

    def test_progress_is_visible_on_both_configured_forward_edges(self):
        source = NOTEBOOK_VIEW.read_text()

        self.assertIn("AddPageHoldIndicator(progress: addPageHoldProgress)", source)
        self.assertIn("case .horizontal:\n            HStack", source)
        self.assertIn("case .vertical:\n            VStack", source)
        self.assertIn('.accessibilityIdentifier("add-page-hold-indicator")', source)
        self.assertIn(".allowsHitTesting(false)", source)


if __name__ == "__main__":
    unittest.main()
