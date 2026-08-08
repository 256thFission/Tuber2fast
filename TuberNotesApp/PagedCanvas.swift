import SwiftUI
import TuberCanvas

/// Hosts the paged canvas runtime in SwiftUI.
///
/// The controller is owned by `EditorSession` and merely handed here, so
/// re-evaluating the SwiftUI body cannot rebuild it or its pages
/// (`Contract.md` — Owners).
///
/// `updateUIViewController` is deliberately empty: intentions travel to the
/// session, which drives the runtime directly. Nothing about the canvas is
/// re-derived from SwiftUI state.
struct PagedCanvas: UIViewControllerRepresentable {
    let controller: PagedCanvasController

    func makeUIViewController(context: Context) -> PagedCanvasController {
        return controller
    }

    func updateUIViewController(_ controller: PagedCanvasController, context: Context) {}
}
