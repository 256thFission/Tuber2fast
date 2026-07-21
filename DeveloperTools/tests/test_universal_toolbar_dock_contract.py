import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOLBAR = (REPO_ROOT / "TuberNotes/Notebook/NotebookToolbar.swift").read_text()
NOTEBOOK_VIEW = (REPO_ROOT / "TuberNotes/Notebook/NotebookView.swift").read_text()


class UniversalToolbarDockContractTests(unittest.TestCase):
    def test_image_picker_lives_in_main_toolbar_only(self):
        self.assertIn("PhotosPicker(\n            selection: $imagePickerItem", TOOLBAR)
        self.assertIn('accessibilityIdentifier("toolbar-add-image")', TOOLBAR)
        self.assertNotIn('accessibilityIdentifier("nav-add-image")', NOTEBOOK_VIEW)

    def test_all_four_docks_and_vertical_side_layout_exist(self):
        for dock in ("case top", "case bottom", "case leading", "case trailing"):
            self.assertIn(dock, TOOLBAR)
        self.assertIn("AnyLayout(VStackLayout(spacing: 8))", TOOLBAR)
        self.assertIn("AnyLayout(HStackLayout(spacing: 8))", TOOLBAR)

    def test_dock_is_app_wide_and_drag_uses_a_dedicated_grip(self):
        self.assertIn('@AppStorage("tuber.notebookToolbarDock")', NOTEBOOK_VIEW)
        self.assertIn('accessibilityIdentifier("toolbar-dock-grip")', TOOLBAR)
        self.assertIn("drag.predictedEndTranslation", NOTEBOOK_VIEW)
        self.assertIn("distances.min", NOTEBOOK_VIEW)

    def test_toolbar_has_requested_compact_order_without_page_navigation_or_pencil(self):
        content = TOOLBAR[
            TOOLBAR.index("private var toolbarContent"):
            TOOLBAR.index("private var toolbarLayout")
        ]
        requested = [
            "toolButton(.pen)",
            "toolButton(.marker)",
            "toolButton(.eraser)",
            "lassoControls",
            "imagePickerButton",
            "undoControls",
            "agenticLayersButton",
        ]
        offsets = [content.index(item) for item in requested]
        self.assertEqual(offsets, sorted(offsets))
        self.assertNotIn("WritingTool.allCases", content)
        self.assertNotIn("toolButton(.pencil)", content)
        self.assertNotIn("pageNavigationControls", TOOLBAR)
        self.assertNotIn('Toggle("Page navigation"', TOOLBAR)


if __name__ == "__main__":
    unittest.main()
