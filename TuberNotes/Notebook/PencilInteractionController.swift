import UIKit

/// Routes Apple Pencil double-tap and Pencil Pro squeeze preferences into the
/// notebook's current tool model without owning any document state.
@MainActor
final class PencilInteractionController: NSObject, UIPencilInteractionDelegate {
    var onToggleEraser: (() -> Void)?
    var onSwapPreviousTool: (() -> Void)?
    var onShowColorPalette: ((CGPoint) -> Void)?
    var onSqueeze: ((CGPoint) -> Void)?
    var fallbackPoint: (() -> CGPoint)?

    var isDoubleTapEnabled = true
    var isSqueezeEnabled = true

    private(set) lazy var interaction: UIPencilInteraction = {
        if #available(iOS 17.5, *) {
            return UIPencilInteraction(delegate: self)
        }
        let interaction = UIPencilInteraction()
        interaction.delegate = self
        return interaction
    }()

    static var prefersHoverPreview: Bool {
        if #available(iOS 17.5, *) {
            return UIPencilInteraction.prefersHoverToolPreview
        }
        return false
    }

    private func handlePreferredTap(at point: CGPoint) {
        guard isDoubleTapEnabled else { return }
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            onToggleEraser?()
        case .switchPrevious:
            onSwapPreviousTool?()
        case .showColorPalette:
            onShowColorPalette?(point)
        case .ignore:
            break
        default:
            break
        }
    }

    /// iOS 17.0–17.4 fallback. When both delegate forms are implemented on a
    /// newer OS, UIKit delivers the richer interaction object below.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        handlePreferredTap(at: fallbackPoint?() ?? .zero)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveTap tap: UIPencilInteraction.Tap
    ) {
        handlePreferredTap(at: tap.hoverPose?.location ?? fallbackPoint?() ?? .zero)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        guard isSqueezeEnabled,
              squeeze.phase == .began,
              UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
        onSqueeze?(squeeze.hoverPose?.location ?? fallbackPoint?() ?? .zero)
    }
}
