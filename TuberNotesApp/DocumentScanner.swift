import SwiftUI
import UIKit
import VisionKit

/// VisionKit's scanner, presented full screen. Nothing here configures it: the
/// edge detection, the perspective correction, the corner drag, the page buffer
/// and the retake are the system's. `updateUIViewController` is empty.
struct DocumentScanner: UIViewControllerRepresentable {
    /// One JPEG per scanned page, in scan order. Empty on cancel.
    ///
    /// The coordinator encodes page by page inside an `autoreleasepool`, so one
    /// bitmap is live rather than all of them: handing the app `[UIImage]`
    /// would need every page decoded before the first was encoded, and a
    /// rectified 12 MP page is about 48 MB of bitmap.
    let onFinish: ([Data]) -> Void

    /// A scanner failure, or a page that would not encode. Both dismiss and
    /// both banner: the SDK header says twice, on the `delegate` property and
    /// on the protocol, that the app is responsible for dismissing the document
    /// camera in every delegate callback. Without this a failed scan is a cover
    /// with no exit.
    let onFailure: (any Error) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onFailure: onFailure) }

    /// A page the scanner produced that would not become bytes. It is
    /// `LocalizedError` because the banner shows `localizedDescription`, which
    /// for a bare Swift error is the "operation couldn't be completed" string
    /// and a domain nobody can act on.
    enum PageFault: LocalizedError {
        case pageWouldNotEncode(Int)

        var errorDescription: String? {
            switch self {
            case .pageWouldNotEncode(let number):
                "page \(number) of the scan could not be read"
            }
        }
    }

    /// Both attributes are load-bearing, and neither alone compiles.
    ///
    /// `VNDocumentCameraViewControllerDelegate` carries no `NS_SWIFT_UI_ACTOR`
    /// and no `SwiftAttributes` in VisionKit's apinotes, so its witnesses are
    /// nonisolated; `UIViewControllerRepresentable` is `@MainActor` but a
    /// nested class does not inherit that. Bare gives "call to main
    /// actor-isolated instance method in a synchronous nonisolated context"
    /// where a handler reaches the view model. `@MainActor` alone gives
    /// "conformance crosses into main actor-isolated code and can cause data
    /// races". `@preconcurrency` alone gives "has no effect", which this build
    /// turns into an error, with the first error still standing. Only both
    /// together compile. `CameraCapture.Coordinator` needs neither, because
    /// `UIImagePickerControllerDelegate` *is* declared `NS_SWIFT_UI_ACTOR`.
    ///
    /// The failure selector is spelled `didFailWithError:` and must not be
    /// "corrected" to `didFailWith:`. VisionKit's apinotes does carry that
    /// rename, but under `Classes: - Name: VNDocumentCameraViewController`, so
    /// it renames a method on the class — which declares none — and leaves the
    /// protocol requirement alone. Every method in this protocol is optional,
    /// so the wrong spelling is silent: the handler simply never fires.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        private let onFinish: ([Data]) -> Void
        private let onFailure: (any Error) -> Void

        init(onFinish: @escaping ([Data]) -> Void, onFailure: @escaping (any Error) -> Void) {
            self.onFinish = onFinish
            self.onFailure = onFailure
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [Data] = []
            pages.reserveCapacity(scan.pageCount)
            for number in 0..<scan.pageCount {
                // One pool per page: the decoded bitmap and the encoder's
                // buffers go away before the next page is asked for.
                let encoded = autoreleasepool {
                    scan.imageOfPage(at: number).jpegData(compressionQuality: 1)
                }
                guard let encoded else {
                    // Never a silent drop: a scan of five pages that hands back
                    // four is a notebook missing a page nobody was told about.
                    onFailure(PageFault.pageWouldNotEncode(number + 1))
                    return
                }
                pages.append(encoded)
            }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: any Error
        ) {
            onFailure(error)
        }
    }
}
