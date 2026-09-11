import TNModel
import UIKit

/// The live text box: a `UITextView` over the composite for the session's
/// duration, framed in page space at the layer's rect with no inset, so it
/// wraps where `Renderer.drawText` wraps.
///
/// TextKit 1, deliberately: its `NSLayoutManager` breaks lines and places
/// baselines the way `CTFramesetter` does for these fonts, and TextKit 2's
/// fragment rounding is the one known divergence between the two engines.
/// `TuberNotesTests/TextFidelityTests` is the evidence either way.
@MainActor
final class TextEditingView: UITextView, UITextViewDelegate {
    /// What the caret types with where no run is under it. Opening a box
    /// with runs continues the last run's style; an empty box takes the
    /// tool's.
    private(set) var typingStyle: TextStyle
    private(set) var alignment: TextAlignment

    let moveRecognizer = UIPanGestureRecognizer()
    let resizeRecognizer = UIPanGestureRecognizer()

    /// Drawn in page space, so they scale with zoom and are large at 10x.
    /// Accepted.
    private let moveHandle = UIView()
    private let resizeHandle = UIView()
    private static let handleSize = CGSize(width: 44, height: 10)
    private static let cornerSize: CGFloat = 12

    init(text: TextLayer, typing: TextStyle) {
        self.typingStyle = text.runs.last?.style ?? typing
        self.alignment = text.alignment
        // A TextKit 1 stack built by hand: the designated initializer is the
        // one that takes a container, and a container with an NSLayoutManager
        // is what selects TextKit 1.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: text.rect.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(
            frame: CGRect(x: text.rect.x, y: text.rect.y, width: text.rect.width, height: text.rect.height),
            textContainer: container
        )
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        isScrollEnabled = false
        backgroundColor = .clear
        clipsToBounds = false
        layer.borderWidth = 1
        layer.borderColor = UIColor.systemBlue.cgColor
        attributedText = TextTypesetting.attributed(text.runs, alignment: text.alignment)
        typingAttributes = TextTypesetting.attributes(for: typingStyle, alignment: text.alignment)
        delegate = self

        for handle in [moveHandle, resizeHandle] {
            handle.backgroundColor = .systemBlue
            handle.layer.cornerRadius = 3
            addSubview(handle)
        }
        moveHandle.addGestureRecognizer(moveRecognizer)
        resizeHandle.addGestureRecognizer(resizeRecognizer)
        moveRecognizer.addTarget(self, action: #selector(handleMove(_:)))
        resizeRecognizer.addTarget(self, action: #selector(handleResize(_:)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TextEditingView is created in code only")
    }

    /// The fidelity test snapshots the text alone; the border and handles
    /// are not part of what the renderer draws.
    func hideChrome() {
        layer.borderWidth = 0
        moveHandle.isHidden = true
        resizeHandle.isHidden = true
    }

    /// One line of the typing style: the floor for width and height, and
    /// the unit the box grows by.
    var lineHeight: CGFloat {
        CGFloat(TextTypesetting.lineHeight(of: typingStyle))
    }

    /// The whole value, as the notebook stores it. Runs are not merged here;
    /// the notebook merges.
    var committedLayer: TextLayer {
        TextLayer(
            rect: PageRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            runs: TextTypesetting.runs(of: attributedText, typing: typingStyle),
            alignment: alignment
        )
    }

    /// The selection if there is one, else what the caret types with. The
    /// alignment is the box's, so it applies to every paragraph regardless.
    func applyStyle(_ style: TextStyle, alignment: TextAlignment) {
        typingStyle = style
        self.alignment = alignment
        let attributes = TextTypesetting.attributes(for: style, alignment: alignment)
        if selectedRange.length > 0 {
            textStorage.setAttributes(attributes, range: selectedRange)
        }
        if let paragraph = attributes[.paragraphStyle] {
            textStorage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: textStorage.length))
        }
        typingAttributes = attributes
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let handle = Self.handleSize
        moveHandle.frame = CGRect(x: (bounds.width - handle.width) / 2, y: -handle.height - 4, width: handle.width, height: handle.height)
        let corner = Self.cornerSize
        resizeHandle.frame = CGRect(x: bounds.width - corner / 2, y: bounds.height - corner / 2, width: corner, height: corner)
    }

    /// The handles lie outside the bounds; without this a touch on one
    /// never reaches it.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) || moveHandle.frame.contains(point) || resizeHandle.frame.contains(point)
    }

    // MARK: - Move and resize

    /// `translation(in: self)` is in this view's own coordinate space, which
    /// is unzoomed page space because the scroll view zooms the content
    /// this view sits in. The hosted test pins that at a zoom other than 1.
    @objc private func handleMove(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        move(by: recognizer.translation(in: self))
        recognizer.setTranslation(.zero, in: self)
    }

    @objc private func handleResize(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        resize(by: recognizer.translation(in: self))
        recognizer.setTranslation(.zero, in: self)
    }

    func move(by delta: CGPoint) {
        frame.origin.x += delta.x
        frame.origin.y += delta.y
    }

    /// Never below one line in either direction, so the committed rect is
    /// always valid without a clamp anywhere else.
    func resize(by delta: CGPoint) {
        let floor = lineHeight
        frame.size.width = max(floor, frame.width + delta.x)
        frame.size.height = max(floor, frame.height + delta.y)
        setNeedsLayout()
    }

    // MARK: - UITextViewDelegate

    /// The box grows with its text: a synchronous layout query inside
    /// UIKit's own callback, which the Structure rule allows.
    func textViewDidChange(_ textView: UITextView) {
        let fits = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let grown = ceil(fits.height)
        if grown > frame.height {
            frame.size.height = grown
            setNeedsLayout()
        }
    }
}
