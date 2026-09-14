import SwiftUI
import UIKit

/// The system camera, presented full screen. `UIImagePickerController` is the
/// only still-camera UI UIKit ships, and building one over
/// `AVCapturePhotoOutput` is a camera app inside a notebook app.
///
/// Nothing here edits the photo: `allowsEditing` stays false, its editor being
/// a square crop that a photo of a page is not.
struct CameraCapture: UIViewControllerRepresentable {
    /// The captured photo, or nil on cancel. Synchronous, so the handler wraps
    /// its `await` in `Task { }`, the pattern `EditorView.importPhoto` already
    /// uses. Nobody owns that task's cancellation: a capture whose import is in
    /// flight when the view goes away runs to completion into a notebook that
    /// is still open. True of the existing photo leg, and not made worse.
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    /// Bare, and deliberately. `UIImagePickerControllerDelegate` is declared
    /// `NS_SWIFT_UI_ACTOR` in `UIImagePickerController.h`, so its witnesses
    /// infer `@MainActor` and reach the view model with no annotation of ours.
    /// Writing `@preconcurrency` on the conformance is the spelling that warns
    /// here, and this build treats a warning as an error.
    ///
    /// The scanner's delegate carries no such annotation, which is why
    /// `DocumentScanner.Coordinator` is written the other way round; the
    /// asymmetry is real and is explained at that declaration.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
