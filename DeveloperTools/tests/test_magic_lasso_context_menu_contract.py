import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
NOTEBOOK_VIEW = REPO_ROOT / "TuberNotes/Notebook/NotebookView.swift"
TOOLBAR = REPO_ROOT / "TuberNotes/Notebook/NotebookToolbar.swift"


class MagicLassoContextMenuContractTests(unittest.TestCase):
    def test_regular_and_magic_lasso_remain_separate(self):
        toolbar = TOOLBAR.read_text()
        view = NOTEBOOK_VIEW.read_text()

        self.assertIn('accessibilityIdentifier("tool-lasso")', toolbar)
        self.assertIn('accessibilityIdentifier("tool-magic-eraser")', toolbar)
        self.assertIn("private var refinementButton", toolbar)
        self.assertIn("MagicLassoOverlay(", view)

    def test_magic_lasso_uses_monochrome_command_strip_instead_of_pills(self):
        view = NOTEBOOK_VIEW.read_text()
        menu = view.split("private struct MagicEraserContextMenu", 1)[1].split(
            "private struct AddPageHoldIndicator", 1
        )[0]

        self.assertIn("private var commandStrip", menu)
        self.assertIn('commandButton("Explain"', menu)
        self.assertIn('commandButton("Check"', menu)
        self.assertIn('commandButton("Ask"', menu)
        self.assertIn('Text("Analyzing…")', menu)
        self.assertIn('accessibilityLabel("Clear Magic Lasso selection")', menu)
        self.assertNotIn('Label("Selected region"', menu)
        self.assertNotIn("LinearGradient(", menu)
        self.assertNotIn("radialButton", menu)
        self.assertNotIn("Circle()", menu)
        self.assertIn("let menuSize = magicMenuSize(", view)
        self.assertIn("menuSize: menuSize", view)

    def test_chat_sidebar_has_a_direct_open_close_button(self):
        view = NOTEBOOK_VIEW.read_text()
        sidebar = (REPO_ROOT / "TuberNotes/Notebook/AgentSidebarView.swift").read_text()

        self.assertIn('accessibilityIdentifier("nav-chat-sidebar")', view)
        self.assertIn('"Close chat sidebar" : "Open chat sidebar"', view)
        self.assertIn("private func toggleAgentSidebar()", view)
        self.assertIn("showAgentSidebar = false", view)
        self.assertIn("showAgentSidebar = true", view)
        self.assertNotIn("showAgentChatTab", view)
        self.assertNotIn("showAgentSidebar ? sidebarShift : 0", view)
        self.assertIn("isFullChatTab: true", view)
        self.assertIn(".frame(width: 340)", sidebar)
        self.assertNotIn("vm.go(to:", sidebar)


if __name__ == "__main__":
    unittest.main()
