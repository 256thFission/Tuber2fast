import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLBAR = REPO_ROOT / "TuberNotes/Notebook/NotebookToolbar.swift"


class NotebookToolSelectionContractTests(unittest.TestCase):
    def test_tool_buttons_keep_tap_selection_and_priority_width_hold(self):
        source = TOOLBAR.read_text()
        tool_button = source[
            source.index("private func toolButton"):
            source.index("private var lassoButton")
        ]

        self.assertIn("Button {\n            activateToolbarTool(tool)", tool_button)
        self.assertIn(
            ".highPriorityGesture(widthAdjustmentGesture(for: tool))",
            tool_button,
        )
        self.assertIn(
            "TapGesture().onEnded { _ in activateToolbarTool(tool) }",
            tool_button,
        )
        self.assertIn("vm.selectTool(tool)", tool_button)


if __name__ == "__main__":
    unittest.main()
