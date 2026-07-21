import plistlib
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
ARCHIVE_SOURCE = REPO_ROOT / "TuberNotes/SpatialCanvas/TuberNoteArchive.swift"
PDF_SOURCE = REPO_ROOT / "TuberNotes/SpatialCanvas/PDFStrokeCompression.swift"
NOTEBOOK_SOURCE = REPO_ROOT / "TuberNotes/Notebook/Notebook.swift"
NOTEBOOK_VIEW_SOURCE = REPO_ROOT / "TuberNotes/Notebook/NotebookView.swift"
NOTEBOOK_VIEW_MODEL_SOURCE = REPO_ROOT / "TuberNotes/Notebook/NotebookViewModel.swift"
LIBRARY_SOURCE = REPO_ROOT / "TuberNotes/Notebook/LibraryView.swift"
STORE_SOURCE = REPO_ROOT / "TuberNotes/Notebook/NotebookStore.swift"
INFO_PLIST = REPO_ROOT / "TuberNotes/Info.plist"
PROJECT_SOURCE = REPO_ROOT / "TuberNotes.xcodeproj/project.pbxproj"


class ArchiveExportContractTests(unittest.TestCase):
    def test_spud_is_version_three_only(self):
        source = ARCHIVE_SOURCE.read_text()

        self.assertIn("static let currentFormatVersion = 3", source)
        self.assertIn(
            "guard archive.formatVersion == TuberNoteArchive.currentFormatVersion",
            source,
        )
        for legacy_contract in (
            "oldestSupportedFormatVersion",
            "InkLayerInput",
            "ConversationLayerRecord",
            "JSONValue",
            "pageX",
            "formatVersion: 2",
        ):
            self.assertNotIn(legacy_contract, source)

    def test_spud_wraps_complete_notebook(self):
        source = ARCHIVE_SOURCE.read_text()
        notebook_source = NOTEBOOK_SOURCE.read_text()
        view_source = NOTEBOOK_VIEW_SOURCE.read_text()
        view_model_source = NOTEBOOK_VIEW_MODEL_SOURCE.read_text()

        self.assertIn("let notebook: Notebook", source)
        self.assertNotIn("let notebook: Notebook?", source)
        self.assertIn("static func encode(notebook: Notebook)", source)
        self.assertIn("notebook: notebook", source)
        self.assertIn("notebook: archive.notebook", source)
        for notebook_field in (
            "id, title, cover, pages, agenticLayers, createdAt, updatedAt, settings",
            "id, drawingLayers, drawingData, createdAt, template, images",
            "var isVisible: Bool",
        ):
            self.assertIn(notebook_field, notebook_source)
        self.assertIn("TuberNoteArchiveCodec.encode(notebook: exportNotebook)", view_source)
        self.assertIn("TuberNoteArchiveCodec.encode(notebook: notebook)", view_model_source)

    def test_export_page_scope_precedes_both_formats(self):
        source = NOTEBOOK_VIEW_SOURCE.read_text()

        self.assertIn("@State private var exportPageScope = ExportPageScope.entireDocument", source)
        self.assertIn("@State private var selectedExportPageIDs = Set<UUID>()", source)
        self.assertIn("private enum ExportPageScope: Hashable", source)
        self.assertIn('Text("Entire Document").tag(ExportPageScope.entireDocument)', source)
        self.assertIn('Text("Choose Pages").tag(ExportPageScope.selectedPages)', source)
        self.assertIn('accessibilityIdentifier("export-page-scope")', source)
        self.assertIn("selectedExportPageIDs.insert(vm.currentPageID)", source)
        self.assertIn("selectedExportPageIDs = Set(vm.notebook.pages.map(\\.id))", source)
        self.assertIn("selectedExportPageIDs.removeAll()", source)
        self.assertEqual(source.count(".disabled(exportPages.isEmpty)"), 2)
        self.assertIn("exportPageScope = .entireDocument", source)
        self.assertIn("openExportOptions()", source)

        pages_body = re.search(
            r"private var exportPages: \[NotebookPage\] \{(.*?)\n    \}\n\n"
            r"    private var exportPageSummary",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(pages_body)
        self.assertIn("return vm.notebook.pages", pages_body.group(1))
        self.assertIn(
            "return vm.notebook.pages.filter { selectedExportPageIDs.contains($0.id) }",
            pages_body.group(1),
        )

    def test_selected_spud_filters_pages_and_pins(self):
        source = NOTEBOOK_VIEW_SOURCE.read_text()

        notebook_body = re.search(
            r"private var exportNotebook: Notebook \{(.*?)\n    \}\n\n"
            r"    private func openExportOptions",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(notebook_body)
        body = notebook_body.group(1)
        self.assertIn("let pages = exportPages", body)
        self.assertIn("let exportPageIDs = Set(pages.map(\\.id))", body)
        self.assertIn("pages: pages", body)
        self.assertIn("filtered.conversations = layer.conversations.filter", body)
        self.assertIn("exportPageIDs.contains($0.pageID)", body)
        self.assertIn("agenticLayers: layers", body)

        spud_body = re.search(
            r"private func prepareSPUDExport\(\) \{(.*?)\n    \}\n\n"
            r"    private func queueExportPresentation",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(spud_body)
        self.assertIn("guard !exportPages.isEmpty else { return }", spud_body.group(1))
        self.assertIn(
            "TuberNoteArchiveCodec.encode(notebook: exportNotebook)",
            spud_body.group(1),
        )

    def test_spud_import_is_security_scoped_and_collision_safe(self):
        archive_source = ARCHIVE_SOURCE.read_text()
        library_source = LIBRARY_SOURCE.read_text()
        store_source = STORE_SOURCE.read_text()
        view_source = NOTEBOOK_VIEW_SOURCE.read_text()

        self.assertIn("extension UTType", archive_source)
        self.assertIn("static let tuberNoteArchive", archive_source)
        self.assertNotIn("private extension UTType", view_source)
        self.assertIn(".fileImporter(", library_source)
        self.assertIn("allowedContentTypes: [.tuberNoteArchive]", library_source)
        self.assertIn('accessibilityIdentifier("library-import-spud")', library_source)
        self.assertIn("let notebook = try store.importSPUD(from: sourceURL)", library_source)
        self.assertIn("path.append(notebook.id)", library_source)
        self.assertIn('alert("Couldn’t Import SPUD"', library_source)

        self.assertIn("func importSPUD(from sourceURL: URL) throws -> Notebook", store_source)
        self.assertIn("sourceURL.startAccessingSecurityScopedResource()", store_source)
        self.assertIn("sourceURL.stopAccessingSecurityScopedResource()", store_source)
        self.assertIn("TuberNoteArchiveCodec.decode(data).notebook", store_source)
        self.assertIn("id: UUID()", store_source)
        self.assertNotIn("id: archived.id", store_source)
        for preserved_field in (
            "title: archived.title",
            "cover: archived.cover",
            "pages: archived.pages",
            "agenticLayers: archived.agenticLayers",
            "createdAt: archived.createdAt",
            "settings: archived.settings",
        ):
            self.assertIn(preserved_field, store_source)
        self.assertIn("save(imported)", store_source)

    def test_spud_type_is_declared_for_files(self):
        project_source = PROJECT_SOURCE.read_text()
        with INFO_PLIST.open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(project_source.count("INFOPLIST_FILE = TuberNotes/Info.plist;"), 2)
        declaration = info["UTExportedTypeDeclarations"][0]
        self.assertEqual(declaration["UTTypeIdentifier"], "com.tubernotes.note")
        self.assertIn("public.json", declaration["UTTypeConformsTo"])
        self.assertIn("spud", declaration["UTTypeTagSpecification"]["public.filename-extension"])
        document_type = info["CFBundleDocumentTypes"][0]
        self.assertIn("com.tubernotes.note", document_type["LSItemContentTypes"])

    def test_spud_decode_validates_every_ink_layer(self):
        source = ARCHIVE_SOURCE.read_text()

        self.assertIn("for page in archive.notebook.pages", source)
        self.assertIn("for layer in page.drawingLayers", source)
        self.assertIn("try? PKDrawing(data: layer.drawingData)", source)
        self.assertIn("throw ArchiveError.damagedInkLayer(layer.id)", source)

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
        self.assertIn("workspaceBackgrounds: [UIImage] = []", signature)
        for forbidden_type in ("PageAnnotation", "ConversationLayer", "Citation", "Pin"):
            self.assertNotIn(forbidden_type, signature)
        self.assertIn("let compressedPages = drawings.map", source)
        self.assertIn(
            "for (pageIndex, compressedStrokes) in compressedPages.enumerated()",
            source,
        )
        self.assertIn("rendererContext.beginPage()", source)

        view_source = NOTEBOOK_VIEW_SOURCE.read_text()
        export_call = re.search(
            r"NotePDFExporter\.makePDF\((.*?)\)\.data",
            view_source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(export_call)
        self.assertIn(r"from: pages.map(\.drawing)", export_call.group(1))
        self.assertNotIn("conversation", export_call.group(1).lower())
        self.assertNotIn("annotation", export_call.group(1).lower())

    def test_pdf_workspace_background_is_opt_in_and_beneath_ink(self):
        view_source = NOTEBOOK_VIEW_SOURCE.read_text()
        pdf_source = PDF_SOURCE.read_text()

        self.assertIn("@State private var includePDFWorkspaceBackground = false", view_source)
        self.assertIn(
            'Toggle("Include workspace background", isOn: $includePDFWorkspaceBackground)',
            view_source,
        )
        self.assertIn(
            'accessibilityIdentifier("pdf-include-workspace-background")',
            view_source,
        )
        self.assertIn("includePDFWorkspaceBackground = false", view_source)
        self.assertIn(
            "? pages.map { renderWorkspaceBackground(for: $0) }",
            view_source,
        )
        self.assertIn("workspaceBackgrounds: backgrounds", view_source)

        renderer_body = re.search(
            r"private func renderWorkspaceBackground\(for page: NotebookPage\) -> UIImage \{"
            r"(.*?)\n    \}\n\n"
            r"    private func prepareSPUDExport",
            view_source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(renderer_body)
        body = renderer_body.group(1)
        self.assertIn("PaperSheetView(frame: pageBounds)", body)
        self.assertIn("paperView.template = page.template", body)
        self.assertIn("paperView.layer.render", body)
        self.assertIn("for placedImage in page.images", body)
        self.assertIn("placedImage.rect.minX * pageBounds.width", body)
        for forbidden_type in ("Pin", "Conversation", "Citation"):
            self.assertNotIn(forbidden_type, body)

        self.assertIn("for (pageIndex, compressedStrokes) in compressedPages.enumerated()", pdf_source)
        background_draw = "workspaceBackgrounds[pageIndex].draw(in: pageBounds)"
        self.assertIn(background_draw, pdf_source)
        self.assertLess(pdf_source.index(background_draw), pdf_source.index("for stroke in compressedStrokes"))

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
