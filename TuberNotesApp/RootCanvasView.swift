import SwiftUI

/// The SwiftUI root: navigation and visible controls only.
///
/// It holds no drawing, pan, or zoom state, and it sends intentions rather than
/// mutating anything. The canvas is hosted only once the document is loaded, so
/// the canvas is never editable before its contents are known.
struct RootCanvasView: View {
    let session: EditorSession

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
            }
        }
        .task { await session.start() }
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
