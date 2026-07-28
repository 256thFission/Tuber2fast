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
                PageCanvas(controller: session.canvas)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("page.canvas")
                    // Top-trailing, not bottom: the PencilKit tool picker
                    // floats along the bottom edge and a bottom-anchored
                    // control collides with it.
                    .overlay(alignment: .topTrailing) { extendControl }
            }
        }
        .task { await session.start() }
    }

    private var extendControl: some View {
        Button {
            session.extendPage()
        } label: {
            Label("Extend page", systemImage: "arrow.down.to.line")
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!session.canExtend)
        .padding(24)
        .accessibilityIdentifier("page.extend")
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
