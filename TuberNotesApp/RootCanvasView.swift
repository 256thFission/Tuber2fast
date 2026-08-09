import SwiftUI
import TuberCanvas
import TuberModel

/// The SwiftUI root: navigation and visible controls only.
///
/// It holds no drawing, pan, or zoom state, and it sends intentions rather than
/// mutating anything. The canvas is hosted only once the document is loaded, so
/// the canvas is never editable before its contents are known.
struct RootCanvasView: View {
    let session: EditorSession

    /// Page-action UI state: which picker is up, and the last failure. View
    /// state only — the actions themselves are the session's, and every one of
    /// them throws loudly rather than being swallowed here.
    @State private var showingImagePicker = false
    @State private var showingPDFImporter = false
    @State private var actionError: String?

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray5)
                .ignoresSafeArea()

            switch session.phase {
            case .loading:
                ProgressView()

            case .failed(let message):
                failure(message)

            case .ready:
                PagedCanvas(controller: session.pages)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("page.canvas")
                    // Top-leading, not bottom: the PencilKit tool picker floats
                    // along the bottom edge and a bottom-anchored control
                    // collides with it.
                    .overlay(alignment: .topLeading) { saveFailure }
                    .overlay(alignment: .topTrailing) {
                        VStack(alignment: .trailing, spacing: 8) {
                            shapePicker
                            templatePicker
                            pageActions
                        }
                        .padding(16)
                    }
            }
        }
        .task { await session.start() }
        .sheet(isPresented: $showingImagePicker) {
            PhotoImportPicker { outcome in
                showingImagePicker = false
                switch outcome {
                case .cancelled:
                    break
                case .failed(let message):
                    actionError = message
                case .picked(let data):
                    importPickedImage(data)
                }
            }
        }
        .fileImporter(
            isPresented: $showingPDFImporter,
            allowedContentTypes: [.pdf]
        ) { result in
            // Cancelling never reaches here; a cancelled picker is not an error.
            switch result {
            case .failure(let error):
                actionError = String(describing: error)
            case .success(let url):
                importPickedPDF(url)
            }
        }
        .alert(
            "That did not work",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    /// The page-level actions: add an image, add a PDF, and throw this page's
    /// PDF away. They sit under the shape picker in the same floating cluster,
    /// because all three are user actions on the document rather than canvas
    /// chrome.
    ///
    /// Removing the PDF is here rather than on the layer itself because a
    /// `pdf` layer is deliberately **not selectable**
    /// (`LayerEnvelope.isSelectable`) and selection is the only other way to
    /// name a layer. Without this button a mis-imported PDF could never be
    /// removed at all; see `EditorSession.deletePDFLayers`.
    private var pageActions: some View {
        HStack(spacing: 2) {
            actionButton("photo", named: "Add image") { showingImagePicker = true }
            actionButton("doc", named: "Add PDF") { showingPDFImporter = true }
            actionButton("trash", named: "Remove this page's PDF", identifier: "remove.pdf") {
                removePDFFromCurrentPage()
            }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .accessibilityIdentifier("page.actions")
    }

    private func actionButton(
        _ symbol: String,
        named name: String,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityIdentifier("page.action.\(identifier ?? symbol)")
    }

    /// Throws away the PDF behind the page the user is looking at.
    ///
    /// Always enabled, and the refusal is an alert rather than a disabled
    /// button, deliberately: a destructive button that has quietly greyed out
    /// says nothing, while "This page has no PDF behind it." says exactly what
    /// happened. The session answers, once, when asked.
    ///
    /// The template picker beside it *is* disabled on a PDF page, and the two
    /// are not in disagreement: a disabled picker states what a page is —
    /// paper does not apply to this one — where a disabled trash button would
    /// only withhold an explanation. `session.currentPageCarriesPDF` is the
    /// same fact and this button could read it; it deliberately does not.
    private func removePDFFromCurrentPage() {
        Task {
            do {
                try await session.deletePDFLayers()
            } catch LayerEditError.noPDFLayerOnPage {
                actionError = "This page has no PDF behind it."
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    /// One picked image, prepared off the main actor and imported onto the
    /// current page. The preparation is what closes the EXIF hole: the extent
    /// handed to `importImage` is the orientation-applied one — see
    /// `PreparedImageImport`.
    private func importPickedImage(_ data: Data) {
        Task {
            do {
                // Detached for the first of the two reasons
                // `CONTRIBUTING.md` — Getting off the main actor allows: the
                // preparation is a synchronous call and this is a main-actor
                // context, so nothing else sheds the isolation.
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ImageImportPreparation.prepare(data)
                }.value
                try await session.importImage(
                    prepared.bytes,
                    format: prepared.format,
                    sourceWidth: prepared.orientedPixelWidth,
                    sourceHeight: prepared.orientedPixelHeight
                )
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    /// One picked PDF, read under its security scope off the main actor. Its
    /// pages land at the end and the visible page does not change — turning to
    /// an import would be navigation the user did not ask for, and finding the
    /// pages at the end is the documented behavior ("import-doesn't-navigate").
    private func importPickedPDF(_ url: URL) {
        Task {
            do {
                // Detached to shed main-actor isolation for a synchronous
                // read, as `importPickedImage` is.
                let bytes = try await Task.detached(priority: .userInitiated) {
                    try PickedFileReading.read(url)
                }.value
                try await session.importPDF(bytes)
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    /// The shape tool's whole user interface.
    ///
    /// Four buttons and no design system: PencilKit's own tool picker owns the
    /// pen, the colour, and the width, and this says only what that drag will
    /// be shaped like. It sits top-trailing because the tool picker floats
    /// along the bottom edge and the save-failure banner takes top-leading.
    ///
    /// It is off the frame path entirely — a button tap is a user action, and
    /// the intention it sends changes one flag inside the canvas runtime.
    private var shapePicker: some View {
        HStack(spacing: 2) {
            shapeButton(nil, symbol: "scribble.variable", named: "Freehand")
            shapeButton(.line, symbol: "line.diagonal", named: "Line")
            shapeButton(.rectangle, symbol: "rectangle", named: "Rectangle")
            shapeButton(.ellipse, symbol: "oval", named: "Ellipse")
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .accessibilityIdentifier("shape.picker")
    }

    private func shapeButton(_ kind: ShapeKind?, symbol: String, named name: String) -> some View {
        Button {
            session.setShapeTool(kind)
        } label: {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 36, height: 36)
                .background(
                    // Lit from the session's read-through of the runtime's own
                    // tool, never from a copy held here: the active tool is
                    // `PagedCanvasController`'s (`Contract.md` — Owners), and a
                    // second writer of it up here could only drift.
                    session.shapeTool == kind ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityIdentifier("shape.tool.\(kind?.rawValue ?? "freehand")")
    }

    /// The document's paper, and the whole of its user interface.
    ///
    /// One control for the document, because the template is one durable value
    /// on the index rather than a per-page fact — so there is nothing here to
    /// scope to a page. Four buttons in the shape picker's idiom: no custom
    /// spacing, no colour, no margins, no per-page override, and no preview
    /// thumbnails. Each of those is a decision that has not been taken, and
    /// adding one is a change of scope rather than a flourish.
    ///
    /// Built from `PageTemplate.allCases` with an exhaustive `switch` behind
    /// each button, so a template added to the enum is a compile error here
    /// rather than a case with no way to choose it.
    ///
    /// Disabled on a page carrying a `pdf` layer: a page is a PDF or it is
    /// paper, and such a page draws no template at all. The durable value is
    /// left exactly as it was while the control is disabled, which is why
    /// throwing the PDF away reveals the paper the document already had.
    ///
    /// **Choosing paper is not undoable**, exactly as turning and appending are
    /// not: it is not a PencilKit stroke edit, and there is no semantic undo
    /// domain (`Contract.md` — Undo). Nothing here registers with an undo
    /// manager.
    private var templatePicker: some View {
        HStack(spacing: 2) {
            ForEach(PageTemplate.allCases, id: \.self) { template in
                templateButton(template)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .disabled(session.currentPageCarriesPDF)
        .accessibilityIdentifier("template.picker")
    }

    private func templateButton(_ template: PageTemplate) -> some View {
        Button {
            chooseTemplate(template)
        } label: {
            Image(systemName: Self.symbol(for: template))
                .font(.body)
                .frame(width: 36, height: 36)
                .background(
                    // Lit from the session's read-through of the index, never
                    // from a copy held here: the durable template is the
                    // document's (`Contract.md` — Owners).
                    session.template == template
                        ? AnyShapeStyle(.tint.opacity(0.25))
                        : AnyShapeStyle(.clear),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.name(for: template))
        .accessibilityIdentifier("template.\(template.rawValue)")
    }

    private static func symbol(for template: PageTemplate) -> String {
        switch template {
        case .blank: "square"
        case .lined: "text.justify"
        case .grid: "square.grid.3x3"
        case .dotted: "circle.grid.3x3"
        }
    }

    private static func name(for template: PageTemplate) -> String {
        switch template {
        case .blank: "Blank paper"
        case .lined: "Ruled paper"
        case .grid: "Grid paper"
        case .dotted: "Dotted paper"
        }
    }

    /// Rules the document differently, and surfaces a refusal the way every
    /// other failing action here does — the same alert, never a swallowed
    /// error. `setTemplate` throws when the session is not ready, and writes
    /// the index through the ordinary save path, so a write failure arrives as
    /// the save-failure banner rather than as a throw.
    private func chooseTemplate(_ template: PageTemplate) {
        Task {
            do {
                try await session.setTemplate(template)
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    @ViewBuilder
    private var saveFailure: some View {
        if let message = session.lastSaveError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes are not saved")
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                }
                Button("Retry") {
                    Task { await session.saveIfNeeded() }
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(24)
            .accessibilityIdentifier("save.error")
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("This canvas could not be opened.")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .accessibilityIdentifier("page.error")
    }
}
