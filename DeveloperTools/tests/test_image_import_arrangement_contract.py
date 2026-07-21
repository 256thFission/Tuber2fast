import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
NOTEBOOK = ROOT / "TuberNotes" / "Notebook"


class ImageImportArrangementContractTests(unittest.TestCase):
    def test_placed_image_rotation_is_persisted_with_legacy_default(self):
        source = (NOTEBOOK / "Notebook.swift").read_text()

        self.assertIn("var rotationRadians: CGFloat", source)
        self.assertIn(
            "decodeIfPresent(CGFloat.self, forKey: .rotationRadians) ?? 0",
            source,
        )

    def test_arrangement_supports_twist_and_visible_rotate_action(self):
        canvas = (NOTEBOOK / "NotebookCanvas.swift").read_text()
        view = (NOTEBOOK / "NotebookView.swift").read_text()
        model = (NOTEBOOK / "NotebookViewModel.swift").read_text()

        self.assertIn("UIRotationGestureRecognizer", canvas)
        self.assertIn("handleRotation", canvas)
        self.assertIn("images[idx].rotationRadians = atan2", canvas)
        self.assertIn('Label("Rotate", systemImage: "rotate.right")', view)
        self.assertIn("vm.rotateSelectedImage()", view)
        self.assertIn("func rotateSelectedImage", model)
        self.assertIn("atan2(sin(angle), cos(angle))", model)

    def test_transform_commit_is_immediate_and_keeps_images_reachable(self):
        canvas = (NOTEBOOK / "NotebookCanvas.swift").read_text()
        model = (NOTEBOOK / "NotebookViewModel.swift").read_text()

        update_images = model[
            model.index("func updateImages"):model.index("func selectImage")
        ]
        self.assertIn("persistNow()", update_images)
        self.assertNotIn("scheduleSave()", update_images)
        self.assertEqual(canvas.count("keepReachable(v)"), 3)
        self.assertIn("private func keepReachable(_ view: UIView)", canvas)
        self.assertIn("center.x = bounds.midX", canvas)
        self.assertIn("center.y = bounds.midY", canvas)

    def test_rotation_is_honored_by_all_image_compositions(self):
        notebook = (NOTEBOOK / "Notebook.swift").read_text()
        view = (NOTEBOOK / "NotebookView.swift").read_text()
        model = (NOTEBOOK / "NotebookViewModel.swift").read_text()

        self.assertIn("func draw(in rect: CGRect)", notebook)
        self.assertIn("context.rotate(by: rotationRadians)", notebook)
        self.assertIn("placed.draw(in: r)", notebook)
        self.assertIn("placed.draw(in: rect)", model)
        self.assertIn("placedImage.draw(in: CGRect(", view)

    def test_import_offers_on_device_transparent_background_processing(self):
        source = (NOTEBOOK / "NotebookView.swift").read_text()

        self.assertIn('Text("Make background transparent")', source)
        self.assertIn(
            'accessibilityIdentifier("image-import-remove-background")',
            source,
        )
        self.assertIn("VNGenerateForegroundInstanceMaskRequest", source)
        self.assertIn("observation.allInstances", source)
        self.assertIn("croppedToInstancesExtent: false", source)
        self.assertIn("UIImage(cgImage: cgImage).pngData()", source)

    def test_late_background_work_cannot_mutate_a_closed_or_replaced_import(self):
        source = (NOTEBOOK / "NotebookView.swift").read_text()

        self.assertIn("@State private var imageImportTask: Task<Void, Never>?", source)
        self.assertIn("imageImportTask?.cancel()", source)
        self.assertIn("try Task.checkCancellation()", source)
        self.assertIn("guard pendingImageImport?.id == importID else { return }", source)
        self.assertIn("catch is CancellationError", source)
        self.assertIn("private static let context = CIContext()", source)
        self.assertIn("private static let maximumPixelDimension: CGFloat = 2_560", source)
        self.assertIn("options: [.applyOrientationProperty: true]", source)
        self.assertIn("VNImageRequestHandler(ciImage: sourceImage", source)


if __name__ == "__main__":
    unittest.main()
