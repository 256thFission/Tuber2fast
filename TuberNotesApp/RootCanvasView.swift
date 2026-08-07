import SwiftUI

/// The SwiftUI root: navigation and visible controls only.
///
/// It holds no drawing, pan, or zoom state, and it sends intentions rather than
/// mutating anything. The canvas is hosted only once the document is loaded, so
/// the canvas is never editable before its contents are known.
struct RootCanvasView: View {
    let session: EditorSession

    /// Which shape button is lit. View state, and only that: the tool itself
    /// lives in the canvas runtime, and this is the picture of it the chrome
    /// draws. Nothing about a Pencil sample or a drawing is mirrored here
    /// (`Contract.md` — Owners, golden rule 2).
    @State private var shapeKind: ShapeKind?

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
                    .overlay(alignment: .topTrailing) { shapePicker }
            }
        }
        .task { await session.start() }
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
        .padding(16)
        .accessibilityIdentifier("shape.picker")
    }

    private func shapeButton(_ kind: ShapeKind?, symbol: String, named name: String) -> some View {
        Button {
            shapeKind = kind
            session.setShapeTool(kind)
        } label: {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 36, height: 36)
                .background(
                    shapeKind == kind ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityIdentifier("shape.tool.\(kind?.rawValue ?? "freehand")")
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
