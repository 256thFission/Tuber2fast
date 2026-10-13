import Foundation
import TNCanvas
import TNModel
import TNNotebook
import UIKit

// The only file in this target that names `TNCanvas`. Everything else in
// `TNEditor` drives an `any CanvasRuntime`, which is what lets a test
// stand a recorder in the runtime's place, and what keeps the concrete
// runtime out of the app's vocabulary.

extension PagedCanvasController: CanvasRuntime {}

extension EditorBinding {
    /// The production binding: it makes the runtime it drives, and hands
    /// it a forwarder, because the runtime needs a reporter before the
    /// binding exists.
    package convenience init(
        notebook: Notebook,
        environment: CanvasEnvironment,
        onLinkActivated: @escaping @MainActor (LinkTarget) -> Void
    ) {
        let forwarder = ReportForwarder()
        self.init(
            notebook: notebook,
            surface: PagedCanvasController(reporter: forwarder, environment: environment),
            forwarder: forwarder,
            onLinkActivated: onLinkActivated
        )
    }
}
