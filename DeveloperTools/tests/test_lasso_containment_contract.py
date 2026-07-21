import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
GEOMETRY = REPO_ROOT / "TuberNotes/SpatialCanvas/LassoGeometry.swift"
OVERLAY = REPO_ROOT / "TuberNotes/SpatialCanvas/DrawingRefinementOverlay.swift"
VIEW_MODEL = REPO_ROOT / "TuberNotes/Notebook/NotebookViewModel.swift"


class LassoContainmentContractTests(unittest.TestCase):
    def test_geometry_validates_closed_paths_deterministically(self):
        source = GEOMETRY.read_text()
        self.assertIn("static let minimumArea", source)
        self.assertIn("static let closeDistance", source)
        self.assertIn("static func closedPath(from captured: [CGPoint]) -> [CGPoint]?", source)
        self.assertIn("static func contains(_ point: CGPoint, in closedPath: [CGPoint]) -> Bool", source)

    def test_overlay_keeps_the_lasso_polygon_it_applies(self):
        source = OVERLAY.read_text()
        self.assertIn("let onApply: (Data, CGRect, [CGPoint]) -> Void", source)
        self.assertIn("selectionPath = LassoGeometry.closedPath(", source)

    def test_refinement_deletes_by_containment_never_by_grazing(self):
        source = VIEW_MODEL.read_text()
        apply_refinement = source[
            source.index("func applyDrawingRefinement"):
            source.index("// MARK: Pages")
        ]
        self.assertIn("LassoGeometry.contains($0.location.applying(stroke.transform)", apply_refinement)
        self.assertIn("!pageRect.contains(stroke.renderBounds)", apply_refinement)
        self.assertNotIn("!$0.renderBounds.intersects(pageRect)", apply_refinement)


if __name__ == "__main__":
    unittest.main()
