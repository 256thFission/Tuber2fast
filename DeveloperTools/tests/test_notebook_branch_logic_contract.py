import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
NOTEBOOK_DIR = REPO_ROOT / "TuberNotes/Notebook"
PROJECT = REPO_ROOT / "TuberNotes.xcodeproj/project.pbxproj"


class NotebookBranchLogicContractTests(unittest.TestCase):
    def test_pencil_support_keeps_ios_17_fallback_and_project_membership(self):
        controller = (NOTEBOOK_DIR / "PencilInteractionController.swift").read_text()
        project = PROJECT.read_text()

        self.assertIn("func pencilInteractionDidTap", controller)
        self.assertIn("@available(iOS 17.5, *)", controller)
        self.assertIn("didReceiveSqueeze", controller)
        for filename in (
            "NotebookUndoBridge.swift",
            "PencilInteractionController.swift",
            "PencilShortcutPalette.swift",
        ):
            self.assertEqual(project.count(f"/* {filename} */"), 3)
            self.assertEqual(project.count(f"/* {filename} in Sources */"), 2)
            self.assertEqual(project.count(f"path = {filename};"), 1)
        self.assertIn("IPHONEOS_DEPLOYMENT_TARGET = 17.0", project)

    def test_dotted_templates_are_persistable_and_rendered(self):
        template = (NOTEBOOK_DIR / "PageTemplate.swift").read_text()
        canvas = (NOTEBOOK_DIR / "NotebookCanvas.swift").read_text()

        for case in ("dottedLarge", "dottedMedium", "dottedSmall"):
            self.assertIn(case, template)
        self.assertIn("var isDotted", template)
        self.assertIn("if template.isDotted", canvas)
        self.assertIn("ctx.fillEllipse", canvas)

    def test_ripples_observe_only_pencil_without_hit_test_interception(self):
        source = (NOTEBOOK_DIR / "AmbientBackground.swift").read_text()

        self.assertIn("PassivePencilTouchRecognizer", source)
        self.assertIn("$0.type == .pencil", source)
        self.assertIn("cancelsTouchesInView = false", source)
        self.assertNotIn("override func hitTest", source)

    def test_page_turn_direction_and_zoom_synchronization_contract(self):
        canvas = (NOTEBOOK_DIR / "NotebookCanvas.swift").read_text()
        view = (NOTEBOOK_DIR / "NotebookView.swift").read_text()
        view_model = (NOTEBOOK_DIR / "NotebookViewModel.swift").read_text()

        self.assertIn("applyBoundZoomScale", canvas)
        self.assertIn("isUserZooming", canvas)
        self.assertIn("pageFitsViewport", canvas)
        self.assertIn("parent.isPageLocked", canvas)
        self.assertIn("UITouch.TouchType.direct.rawValue", canvas)
        self.assertNotIn("isSyncingZoom", canvas)

        self.assertIn("pageTurnDirection = .forward", view_model)
        self.assertIn("pageTurnDirection = .backward", view_model)
        self.assertIn(
            "pageTurnDirection = index > currentIndex ? .forward : .backward",
            view_model,
        )
        self.assertIn(
            "pageTurnDirection = currentIndex < notebook.pages.count - 1 ? .forward : .backward",
            view_model,
        )
        self.assertIn("flipOffset = forward ? -width : width", view)
        self.assertIn("flipOffset = forward ? width : -width", view)
        self.assertIn("insertion: pageTurnTransitionOffset(distance)", view)
        self.assertIn("removal: pageTurnTransitionOffset(-distance)", view)
        self.assertIn("insertion: pageTurnTransitionOffset(-distance)", view)
        self.assertIn("removal: pageTurnTransitionOffset(distance)", view)
        self.assertIn(".offset(x: distance, y: 0)", view)
        self.assertIn(".offset(x: 0, y: distance)", view)
        self.assertIn(".id(vm.currentPageID)", view)
        self.assertIn(".id(vm.currentDrawingLayerID)", view)
        self.assertNotIn("insertion: .move(edge: .trailing)", view)


if __name__ == "__main__":
    unittest.main()
