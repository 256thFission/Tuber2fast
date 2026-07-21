import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
ARCHIVE_SOURCE = REPO_ROOT / "TuberNotes/SpatialCanvas/TuberNoteArchive.swift"
PDF_SOURCE = REPO_ROOT / "TuberNotes/SpatialCanvas/PDFStrokeCompression.swift"
NOTEBOOK_VIEW_SOURCE = REPO_ROOT / "TuberNotes/Notebook/NotebookView.swift"
NOTEBOOK_VIEW_MODEL_SOURCE = REPO_ROOT / "TuberNotes/Notebook/NotebookViewModel.swift"


class ArchiveExportContractTests(unittest.TestCase):
    def test_spud_uses_full_page_annotation_payload(self):
        source = ARCHIVE_SOURCE.read_text()

        self.assertIn("static let currentFormatVersion = 3", source)
        self.assertIn("let annotation: PageAnnotation", source)
        self.assertIn(".init(annotation: conversation)", source)
        self.assertIn("conversation.annotation", source)
        self.assertIn("try container.encode(annotation, forKey: .annotation)", source)

        # Version 1 archives remain readable through the legacy field adapter.
        self.assertIn("static let oldestSupportedFormatVersion = 1", source)
        for legacy_key in ("pageX", "pageY", "title", "detail"):
            self.assertRegex(source, rf"decode\([^\n]+forKey: \.{legacy_key}\)")

    def test_spud_preserves_layer_visibility(self):
        source = ARCHIVE_SOURCE.read_text()

        self.assertIn("isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true", source)
        self.assertIn("isVisible: layer.isVisible", source)

    def test_spud_exports_complete_notebook_with_legacy_decode(self):
        source = ARCHIVE_SOURCE.read_text()
        view_source = NOTEBOOK_VIEW_SOURCE.read_text()
        view_model_source = NOTEBOOK_VIEW_MODEL_SOURCE.read_text()

        self.assertIn("var notebook: Notebook?", source)
        self.assertIn("static func encode(notebook: Notebook)", source)
        self.assertIn("formatVersion: TuberNoteArchive.currentFormatVersion", source)
        self.assertIn("notebook: notebook", source)
        self.assertIn("guard archive.formatVersion < 3 || archive.notebook != nil", source)
        self.assertIn("let notebook = archive.notebook ?? Notebook(", source)
        self.assertIn("formatVersion: 2", source)
        self.assertIn("notebook: nil", source)
        self.assertIn("TuberNoteArchiveCodec.encode(notebook: vm.notebook)", view_source)
        self.assertIn("TuberNoteArchiveCodec.encode(notebook: notebook)", view_model_source)

        spud_body = re.search(
            r"private func prepareSPUDExport\(\) \{(.*?)\n    \}\n\n"
            r"    private func queueExportPresentation",
            view_source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(spud_body)
        self.assertNotIn("currentPage", spud_body.group(1))

    def test_compressed_pdf_exports_all_pages_without_annotation_input(self):
        source = PDF_SOURCE.read_text()
        signature_match = re.search(
            r"static func makePDF\((.*?)\) -> PDFExportResult",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(signature_match)
        signature = signature_match.group(1)

        self.assertIn("from drawings: [PKDrawing]", signature)
        for forbidden_type in ("PageAnnotation", "ConversationLayer", "Citation", "Pin"):
            self.assertNotIn(forbidden_type, signature)
        self.assertIn("let compressedPages = drawings.map", source)
        self.assertIn("for compressedStrokes in compressedPages", source)
        self.assertIn("rendererContext.beginPage()", source)

        # The UI passes every page's drawing, in notebook order, into the exporter.
        view_source = NOTEBOOK_VIEW_SOURCE.read_text()
        export_call = re.search(
            r"NotePDFExporter\.makePDF\((.*?)\)\.data",
            view_source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(export_call)
        self.assertIn(r"from: vm.notebook.pages.map(\.drawing)", export_call.group(1))
        self.assertNotIn("conversation", export_call.group(1).lower())
        self.assertNotIn("annotation", export_call.group(1).lower())

    def test_export_filename_describes_complete_notebook(self):
        source = NOTEBOOK_VIEW_SOURCE.read_text()

        filename_body = re.search(
            r"private func exportFilename\(.*?\) -> String \{(.*?)\n    \}\n\n"
            r"    private func handleExportCompletion",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(filename_body)
        self.assertIn('return "\\(title).\\(fileExtension)"', filename_body.group(1))
        self.assertNotIn("currentIndex", filename_body.group(1))
        self.assertNotIn("-page-", filename_body.group(1))

    def test_export_presentation_has_one_ordered_file_exporter(self):
        source = NOTEBOOK_VIEW_SOURCE.read_text()

        self.assertNotIn(".popover(isPresented: $showExportOptions)", source)
        self.assertIn(
            ".sheet(isPresented: $showExportOptions, onDismiss: presentPendingExport)",
            source,
        )
        self.assertIn("await Task.yield()", source)
        self.assertNotIn("asyncAfter(deadline: .now() + 0.35)", source)
        self.assertEqual(source.count(".fileExporter("), 1)
        self.assertIn("isPresented: $showFileExporter", source)
        self.assertIn("contentType: exportContentType", source)
        self.assertIn("exportContentType = .pdf", source)
        self.assertIn("exportContentType = .tuberNoteArchive", source)
        self.assertNotIn("showPDFExporter", source)
        self.assertNotIn("showSPUDExporter", source)
        self.assertIn("nsError.code == NSUserCancelledError", source)

        queue_body = re.search(
            r"private func queueExportPresentation\(.*?\) \{(.*?)\n    \}\n\n"
            r"    private func dismissExportOptions",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(queue_body)
        self.assertLess(
            queue_body.group(1).index("exportContentType = .pdf"),
            queue_body.group(1).index("showExportOptions = false"),
        )
        self.assertLess(
            queue_body.group(1).index("exportContentType = .tuberNoteArchive"),
            queue_body.group(1).index("showExportOptions = false"),
        )

        handoff_body = re.search(
            r"private func presentPendingExport\(\) \{(.*?)\n    \}\n\n"
            r"    private func exportFilename",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(handoff_body)
        self.assertLess(
            handoff_body.group(1).index("await Task.yield()"),
            handoff_body.group(1).index("showFileExporter = true"),
        )
        self.assertEqual(source.count("showFileExporter = true"), 1)


if __name__ == "__main__":
    unittest.main()
