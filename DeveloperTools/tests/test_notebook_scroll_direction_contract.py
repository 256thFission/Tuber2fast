import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
NOTEBOOK = REPO_ROOT / "TuberNotes/Notebook/Notebook.swift"
NOTEBOOK_VIEW = REPO_ROOT / "TuberNotes/Notebook/NotebookView.swift"
CANVAS = REPO_ROOT / "TuberNotes/Notebook/NotebookCanvas.swift"
TOOLBAR = REPO_ROOT / "TuberNotes/Notebook/NotebookToolbar.swift"


class NotebookScrollDirectionContractTests(unittest.TestCase):
    def test_setting_defaults_and_migrates_to_horizontal(self):
        source = NOTEBOOK.read_text()

        self.assertIn("enum NotebookPageScrollDirection: String, Codable", source)
        self.assertIn("pageScrollDirection: NotebookPageScrollDirection = .horizontal", source)
        self.assertIn("decodeIfPresent(\n            NotebookPageScrollDirection.self", source)
        self.assertIn(") ?? .horizontal", source)

    def test_settings_exposes_segmented_direction_picker(self):
        source = TOOLBAR.read_text()

        self.assertIn('Picker("Page scroll direction", selection: $vm.settings.pageScrollDirection)', source)
        self.assertIn("ForEach(NotebookPageScrollDirection.allCases)", source)
        self.assertIn('.accessibilityIdentifier("settings-page-scroll-direction")', source)

    def test_selected_axis_drives_gesture_offset_and_transition(self):
        canvas = CANVAS.read_text()
        view = NOTEBOOK_VIEW.read_text()

        self.assertIn("let pageScrollDirection: NotebookPageScrollDirection", canvas)
        self.assertIn("? translationVector.x\n                : translationVector.y", canvas)
        self.assertIn("case .vertical:\n                guard abs(velocity.y)", canvas)
        self.assertIn("scrollView.contentOffset.y >= bottomOffset - edgeTolerance", canvas)
        self.assertIn("pageScrollDirection: vm.settings.pageScrollDirection", view)
        self.assertIn(".onChange(of: vm.settings) { _, _ in vm.scheduleSave() }", view)
        self.assertIn("private func pageTurnTransitionOffset", view)
        self.assertIn(".offset(x: 0, y: distance)", view)
        self.assertIn("y: vm.settings.pageScrollDirection == .vertical ? flipOffset : 0", view)

        toolbar = TOOLBAR.read_text()
        self.assertIn("vm.settings.pageScrollDirection.previousSymbolName", toolbar)
        self.assertIn("vm.settings.pageScrollDirection.nextSymbolName", toolbar)


if __name__ == "__main__":
    unittest.main()
