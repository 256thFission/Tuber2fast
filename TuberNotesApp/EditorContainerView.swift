import SwiftUI

/// The open editor, full-screen — it replaces the browser; the two are never
/// on screen together — plus the one affordance the browser adds: Back.
///
/// A wrapper around `RootCanvasView` rather than an edit to it: the overlay
/// layers cleanly above the canvas chrome, and the canvas root stays the
/// document-editing surface it was.
struct EditorContainerView: View {
    let open: LibraryCoordinator.OpenDocument
    let coordinator: LibraryCoordinator

    var body: some View {
        RootCanvasView(session: open.lifecycle.session)
            .overlay(alignment: .topLeading) {
                backButton
                    .padding(16)
            }
    }

    /// Circular back chevron, top-leading, matching the folder-back style.
    /// Disabled while the one teardown runs — `close()` is idempotent, but a
    /// button that looks tappable should not pretend a second close exists.
    private var backButton: some View {
        Button {
            Task { await coordinator.closeOpenDocument() }
        } label: {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 44, height: 44)
                if coordinator.isClosing {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isClosing)
        .accessibilityLabel("Back to library")
        .accessibilityIdentifier("library.back")
    }
}
