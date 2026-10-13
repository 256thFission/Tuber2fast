import TNModel
import UIKit

/// The selected object's frame: a border, four corner handles, a rotate knob
/// above the top edge, and one pan recognizer whose mode is decided at
/// `.began` by where it landed. Locked, it is the border and a lock badge:
/// no handles, no drag, and the menu offers Unlock and nothing else. Around
/// a link or a text box it is the border alone, and every drag moves.
///
/// It has no pixels of its own. The object the frame surrounds is the
/// composite beneath it, which the notebook re-renders only when a drag ends,
/// so during a drag the frame moves and the picture does not. That is the
/// price of keeping every piece of selection state here instead of giving the
/// notebook a lifted layer, and it is what the device check is for.
///
/// Framed in page space as a subview of the canvas view, like
/// `TextEditingView`: the scroll view pans and zooms it, and nothing of ours
/// follows the viewport per frame.
@MainActor
final class LayerSelectionView: UIView {
    /// Which corner a drag grabbed, in unit-square coordinates.
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// The corner's position in the source unit square.
        var unit: (u: Double, v: Double) {
            switch self {
            case .topLeft: (0, 0)
            case .topRight: (1, 0)
            case .bottomLeft: (0, 1)
            case .bottomRight: (1, 1)
            }
        }

        var opposite: Corner {
            switch self {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomLeft: .topRight
            case .bottomRight: .topLeft
            }
        }
    }

    /// What the pan in flight is doing. Fixed at `.began` by where the touch
    /// landed, so a drag that wanders over a handle does not change meaning
    /// halfway through.
    private enum DragMode {
        case move
        case scale(Corner)
        case rotate(startTouchAngle: Double, startRotation: Double)
    }

    let layerID: LayerID

    /// The placement the notebook holds, restated by every `setLayers`.
    private(set) var accepted: PageSpaceTransform
    /// The placement this drag is building. The frame shows `working` and
    /// reports it once, at the pan's end.
    private(set) var working: PageSpaceTransform

    let panRecognizer = UIPanGestureRecognizer()
    let tapRecognizer = UITapGestureRecognizer()

    /// The pan ended or was cancelled; `working` is the whole transform to
    /// report. One report per drag, by construction.
    var onDragEnded: (@MainActor (PageSpaceTransform) -> Void)?
    /// Delete, chosen from the frame's edit menu.
    var onDeleteRequested: (@MainActor () -> Void)?
    /// Lock or Unlock, chosen from the same menu; the value is the one asked
    /// for. The frame changes nothing itself: the composite that answers
    /// restates the flag through `setLocked`.
    var onLockRequested: (@MainActor (Bool) -> Void)?

    /// The flag the notebook holds, restated by every `setLayers`.
    private(set) var isLocked: Bool

    /// The layer is placed by a rect, which moves and never resizes or
    /// rotates, so the frame has no handle and no knob.
    let movesOnly: Bool

    /// The theme the frame draws in, restated by every theme change.
    private(set) var theme: Theme

    /// Neither extent may fall below this. `Layer.validated()` refuses a
    /// determinant near zero, and a floor here is what keeps a handle from
    /// ever reaching one — the same shape as `TextEditingView.resize`
    /// flooring at a line.
    static let minimumExtent: Double = 8

    private static let handleSize: CGFloat = 15
    private static let handleRadius: CGFloat = 5
    private static let knobSize: CGFloat = 14
    private static let knobOffset: CGFloat = 24
    private static let lineWidth: CGFloat = 3
    private static let dashPattern: [NSNumber] = [9, 7]
    /// How much of the accent the box lays over what it surrounds.
    private static let fillAlpha: CGFloat = 0.10

    private var handles: [Corner: UIView] = [:]
    private let box = CAShapeLayer()
    private let knob = UIView()
    private let badge = UIImageView(image: UIImage(systemName: "lock.fill"))
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var drag: DragMode?

    init(layer: LayerID, transform: PageSpaceTransform, locked: Bool, movesOnly: Bool, theme: Theme) {
        self.layerID = layer
        self.accepted = transform
        self.working = transform
        self.isLocked = locked
        self.movesOnly = movesOnly
        self.theme = theme
        super.init(frame: .zero)

        isOpaque = false
        backgroundColor = .clear
        // The anchor is the bounds origin, so `position` is the placement's
        // translation and nothing has to compensate for a centre.
        self.layer.anchorPoint = .zero
        // Added before the handles, so it sits under them however the
        // subviews' own layers stack.
        box.lineWidth = Self.lineWidth
        box.lineDashPattern = Self.dashPattern
        // Not view-backed, so its path and frame would implicitly animate and
        // trail the handles for a quarter second on every resize step.
        box.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        self.layer.addSublayer(box)

        for corner in Corner.allCases {
            let handle = UIView()
            handle.layer.cornerRadius = Self.handleRadius
            handle.layer.borderWidth = Self.lineWidth
            addSubview(handle)
            handles[corner] = handle
        }
        knob.layer.cornerRadius = Self.knobSize / 2
        knob.layer.borderWidth = Self.lineWidth
        addSubview(knob)
        badge.contentMode = .scaleAspectFit
        addSubview(badge)
        applyTheme()

        panRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        addGestureRecognizer(panRecognizer)
        tapRecognizer.addTarget(self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapRecognizer)
        addInteraction(editMenu)

        applyLock()
        place()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LayerSelectionView is created in code only")
    }

    // MARK: - Placement

    /// Bounds are the object's own extents; the residual affine — the
    /// placement with those extents divided out — is the rotation. So the
    /// view is the object's own rectangle rotated into place, and its
    /// handles keep page-point sizes at any rotation.
    private func place() {
        let extents = working.unitExtents
        guard extents.width > 0, extents.height > 0 else { return }
        bounds = CGRect(x: 0, y: 0, width: extents.width, height: extents.height)
        layer.setAffineTransform(CGAffineTransform(
            a: working.a / extents.width, b: working.b / extents.width,
            c: working.c / extents.height, d: working.d / extents.height,
            tx: 0, ty: 0
        ))
        layer.position = CGPoint(x: working.tx, y: working.ty)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        box.frame = bounds
        // The page's overlay scale is set on the view and its subviews, and
        // a sublayer is neither, so the box has to be told the same number
        // or its dashes are drawn at one-to-one and go soft under zoom.
        box.contentsScale = layer.contentsScale
        // Stroked on the bounds rather than inside them, so the line's own
        // centre is where the object's edge actually is.
        box.path = CGPath(rect: bounds, transform: nil)
        let size = Self.handleSize
        for (corner, handle) in handles {
            let unit = corner.unit
            handle.frame = CGRect(
                x: bounds.width * unit.u - size / 2,
                y: bounds.height * unit.v - size / 2,
                width: size, height: size
            )
        }
        knob.frame = CGRect(
            x: (bounds.width - Self.knobSize) / 2,
            y: -Self.knobOffset - Self.knobSize,
            width: Self.knobSize, height: Self.knobSize
        )
        badge.frame = CGRect(x: 4, y: 4, width: Self.knobSize, height: Self.knobSize)
    }

    /// The handles and the knob lie outside the bounds; without this a touch
    /// on one never reaches the view at all. Locked, or moving only, there is
    /// nothing outside the bounds to reach.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if bounds.contains(point) { return true }
        if isLocked || movesOnly { return false }
        if knob.frame.contains(point) { return true }
        return handles.values.contains { $0.frame.contains(point) }
    }

    // MARK: - Lock

    /// The notebook restated the flag. A drag cannot start on a locked
    /// frame; one in flight when a lock lands ends by reporting a transform
    /// the notebook refuses, and `adopt` answers that as it answers any
    /// refusal.
    func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        applyLock()
    }

    private func applyLock() {
        for handle in handles.values { handle.isHidden = isLocked || movesOnly }
        knob.isHidden = isLocked || movesOnly
        badge.isHidden = !isLocked
        panRecognizer.isEnabled = !isLocked
        applyTheme()
    }

    /// Every colour the frame draws is the accent or is derived from it, so
    /// the frame belongs to the theme and never borrows the ink it sits over.
    /// Locked, the box drops to the accent's own outline tint: the document
    /// names no locked treatment, and that is the dimmer end of the one
    /// colour the lasso is allowed. The frame sits on the paper, so the tint
    /// is the outline over the paper, which after dark is not the chrome's.
    private func applyTheme() {
        let accent = theme.accent.uiColor
        let tint = theme.outlineOnPaper(of: theme.accent).uiColor
        box.fillColor = accent.withAlphaComponent(Self.fillAlpha).cgColor
        box.strokeColor = (isLocked ? tint : accent).cgColor
        for handle in handles.values {
            handle.backgroundColor = accent
            handle.layer.borderColor = tint.cgColor
        }
        knob.backgroundColor = accent
        knob.layer.borderColor = tint.cgColor
        badge.tintColor = tint
    }

    // MARK: - Told

    /// The theme changed. The frame stays up; only its colours change.
    func apply(_ theme: Theme) {
        self.theme = theme
        applyTheme()
    }

    /// The notebook restated the placement, or refused the one reported. A
    /// restatement that lands while a pan is in flight records the value and
    /// leaves the drag alone: the pan's end reports, and the composite that
    /// answers it restates again.
    func adopt(_ transform: PageSpaceTransform) {
        accepted = transform
        guard !isDragging else { return }
        working = transform
        place()
    }

    // MARK: - The gesture

    /// Page points.
    func move(by delta: CGPoint) {
        working = PageSpaceTransform(
            a: working.a, b: working.b, c: working.c, d: working.d,
            tx: working.tx + delta.x, ty: working.ty + delta.y
        )
        place()
    }

    /// Uniform, about the opposite corner, along the diagonal the drag is
    /// on. Floored so neither extent can fall below `minimumExtent`.
    func scale(fromCorner corner: Corner, to point: CGPoint) {
        let fixed = pageCorner(corner.opposite)
        let dragged = pageCorner(corner)
        let current = (x: dragged.x - fixed.x, y: dragged.y - fixed.y)
        let wanted = (x: Double(point.x) - fixed.x, y: Double(point.y) - fixed.y)
        let length = current.x * current.x + current.y * current.y
        guard length > 0 else { return }
        var factor = (wanted.x * current.x + wanted.y * current.y) / length

        let extents = working.unitExtents
        guard extents.width > 0, extents.height > 0 else { return }
        let floor = max(Self.minimumExtent / extents.width, Self.minimumExtent / extents.height)
        factor = max(factor, floor)

        let a = working.a * factor, b = working.b * factor
        let c = working.c * factor, d = working.d * factor
        // The opposite corner stays where it is: the new origin is whatever
        // puts it back.
        let unit = corner.opposite.unit
        working = PageSpaceTransform(
            a: a, b: b, c: c, d: d,
            tx: fixed.x - (a * unit.u + c * unit.v),
            ty: fixed.y - (b * unit.u + d * unit.v)
        )
        place()
    }

    /// `angle` is the direction the source's width edge points in page space.
    /// The centre stays where it is.
    func rotate(to angle: CGFloat) {
        let centre = pageCentre
        let delta = Double(angle) - rotation
        let cosine = cos(delta), sine = sin(delta)
        let a = working.a * cosine - working.b * sine
        let b = working.a * sine + working.b * cosine
        let c = working.c * cosine - working.d * sine
        let d = working.c * sine + working.d * cosine
        working = PageSpaceTransform(
            a: a, b: b, c: c, d: d,
            tx: centre.x - (a + c) / 2,
            ty: centre.y - (b + d) / 2
        )
        place()
    }

    /// The direction of the transformed width edge.
    var rotation: Double { atan2(working.b, working.a) }

    var pageCentre: (x: Double, y: Double) {
        (working.tx + (working.a + working.c) / 2, working.ty + (working.b + working.d) / 2)
    }

    private func pageCorner(_ corner: Corner) -> (x: Double, y: Double) {
        let unit = corner.unit
        return working.apply(x: unit.u, y: unit.v)
    }

    /// A point in this view's own bounds space, as page space. The
    /// recognizer answers in the view's own coordinates, which the layer
    /// transform relates to page space with no zoom in it — the scroll
    /// view's scale never enters the arithmetic.
    private func pagePoint(_ local: CGPoint) -> CGPoint {
        let extents = working.unitExtents
        guard extents.width > 0, extents.height > 0 else { return local }
        let page = working.apply(x: Double(local.x) / extents.width, y: Double(local.y) / extents.height)
        return CGPoint(x: page.x, y: page.y)
    }

    /// A translation in this view's own space as a page-space delta: the
    /// residual rotation applied, and nothing else.
    private func pageDelta(_ local: CGPoint) -> CGPoint {
        let extents = working.unitExtents
        guard extents.width > 0, extents.height > 0 else { return local }
        return CGPoint(
            x: working.a / extents.width * local.x + working.c / extents.height * local.y,
            y: working.b / extents.width * local.x + working.d / extents.height * local.y
        )
    }

    /// A drag's three moments, in this view's own coordinate space.
    ///
    /// Split from the recognizer deliberately: what a drag *means* is
    /// arithmetic and is checkable here, while what a recognizer says is a
    /// touch stream the simulator does not have. The gesture below is the
    /// only production caller and adds nothing but the touch.
    func beginDrag(at local: CGPoint) {
        guard !isLocked else { return }
        drag = mode(forTouchAt: local)
    }

    /// `local` is where the touch is now; `delta` is how far it moved since
    /// the last call. Both in this view's own space.
    func continueDrag(to local: CGPoint, by delta: CGPoint) {
        switch drag {
        case .move:
            move(by: pageDelta(delta))
        case .scale(let corner):
            scale(fromCorner: corner, to: pagePoint(local))
        case .rotate(let startTouchAngle, let startRotation):
            let touch = angle(from: pageCentre, to: pagePoint(local))
            rotate(to: CGFloat(startRotation + touch - startTouchAngle))
        case nil:
            return
        }
    }

    /// The pan ended or was cancelled. One report, whole, once.
    func endDrag() {
        guard drag != nil else { return }
        drag = nil
        onDragEnded?(working)
    }

    /// Whether a drag is in flight, which is what makes a restatement from
    /// the notebook record `accepted` and leave `working` alone.
    var isDragging: Bool { drag != nil }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginDrag(at: recognizer.location(in: self))
        case .changed:
            continueDrag(to: recognizer.location(in: self), by: recognizer.translation(in: self))
            recognizer.setTranslation(.zero, in: self)
        case .ended, .cancelled, .failed:
            endDrag()
        default:
            break
        }
    }

    /// Fixed once, at `.began`. Corners are tested in a fixed order so an
    /// object small enough for its handles to overlap still answers the same
    /// way every time.
    private func mode(forTouchAt local: CGPoint) -> DragMode {
        if movesOnly { return .move }
        for corner in Corner.allCases where handles[corner]?.frame.contains(local) == true {
            return .scale(corner)
        }
        if knob.frame.contains(local) {
            return .rotate(
                startTouchAngle: angle(from: pageCentre, to: pagePoint(local)),
                startRotation: rotation
            )
        }
        return .move
    }

    private func angle(from centre: (x: Double, y: Double), to point: CGPoint) -> Double {
        atan2(Double(point.y) - centre.y, Double(point.x) - centre.x)
    }

    // MARK: - Delete

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(
            identifier: nil, sourcePoint: recognizer.location(in: self)
        ))
    }

    /// The menu's actions, and the only things a test can drive: whether
    /// `UIEditMenuInteraction` actually presents is not observable here.
    func deleteRequested() {
        onDeleteRequested?()
    }

    func lockRequested(_ locked: Bool) {
        onLockRequested?(locked)
    }

    /// Unlock alone on a locked frame; Lock and Delete otherwise. Delete is
    /// absent rather than disabled, so a locked object cannot be deleted
    /// from here at all, which is what the notebook's refusal also says.
    func menuActions() -> [UIAction] {
        if isLocked {
            return [UIAction(title: "Unlock", image: UIImage(systemName: "lock.open")) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockRequested(false) }
            }]
        }
        return [
            UIAction(title: "Lock", image: UIImage(systemName: "lock")) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockRequested(true) }
            },
            UIAction(title: "Delete", attributes: .destructive) { [weak self] _ in
                MainActor.assumeIsolated { self?.deleteRequested() }
            },
        ]
    }
}

extension LayerSelectionView: UIEditMenuInteractionDelegate {
    nonisolated func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        MainActor.assumeIsolated { UIMenu(children: menuActions()) }
    }
}
