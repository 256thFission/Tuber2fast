import TNModel
import UIKit

/// What a slot shows when it has no live canvas: a page-shaped rectangle and a
/// small label.
///
/// Placeholder, never blank. Three states reach it and each is a page the user
/// can see the shape of: a page whose content has not arrived yet, a page
/// outside the live window, and a page the notebook refused (`faults` non-empty
/// on its snapshot), which names its first fault. It is never editable and it
/// never holds ink — the fault case especially, because an editable canvas over
/// unreadable bytes is how ink gets written onto a page that cannot save it.
final class PagePlaceholderView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemGray6
        layer.borderColor = UIColor.systemGray4.cgColor
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        isUserInteractionEnabled = false

        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PagePlaceholderView is created in code only")
    }

    var text: String {
        get { label.text ?? "" }
        set { label.text = newValue }
    }
}

/// The words a placeholder says. One place, so the fault taxonomy and the copy
/// stay in step.
enum PlaceholderCopy {
    /// A page the notebook has not sent content for yet.
    static let waiting = "Loading…"

    static func text(for fault: PageFault) -> String {
        switch fault {
        case .missingPageFile:
            "This page is missing."
        case .pageFileUnreadable, .pageIDMismatch, .invalidInkIndex, .duplicateLayerID:
            "This page can't be read."
        case .missingInk, .inkContainerInvalid, .inkArchiveUndecodable:
            "This page's ink can't be read."
        case .unknownPaper(let name):
            "This page uses paper this version doesn't have: \(name)."
        case .paperAssetMissing(let name):
            "This page's paper is missing: \(name)."
        case .layerRefused:
            "Something on this page can't be shown."
        }
    }
}
