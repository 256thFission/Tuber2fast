import CoreGraphics
import TNModel

/// The paging arithmetic of the runtime, as a value.
///
/// One slot per page, exactly one viewport wide and tall, whatever the page in
/// it measures: the page varies inside its slot, the slot never varies. That is
/// what keeps `isPagingEnabled` — which snaps on multiples of the scroll view's
/// *bounds* width — the framework's own rather than a gesture arbitration of
/// ours, and it keeps every offset in the runtime the one expression
/// `slot.width * index`.
///
/// It is a value with no view in it so the arithmetic can be read, and tested,
/// without a hosted runtime. The runtime holds no second copy: it builds one of
/// these from the scroll view's bounds every time it needs to place something.
package struct SlotLayout: Equatable, Sendable {
    /// The live window is the current slot and one either side; the decoded
    /// window is one more each side. Both radii live here, because "one
    /// expression in one place" is the rule the fork doc states for them.
    package static let liveRadius = 1
    package static let decodedRadius = 2

    /// How far past the last slot a drag must end before it counts as asking
    /// for a new page.
    ///
    /// Measured on hardware (2026-08-08, iPad Air 5) for the runtime this
    /// replaces: the rubber band damps a full natural pull to ~0.25–0.29 of the
    /// viewport width in either orientation, and 0.35 was therefore out of
    /// reach — append was simply dead. The deliberate gesture measured 0.24+ of
    /// the width, so 0.15 sits under the weakest of them and far above the
    /// overshoot an ordinary turn leaves at finger-lift.
    package static let endBoundaryFraction: CGFloat = 0.15

    package let slot: CGSize
    package let pageCount: Int

    package init(slot: CGSize, pageCount: Int) {
        self.slot = slot
        self.pageCount = pageCount
    }

    /// No slot has a size yet, or there are no pages. Every question below
    /// answers "nothing" rather than dividing by zero.
    package var isEmpty: Bool {
        !(slot.width > 0 && slot.height > 0) || pageCount <= 0
    }

    package var contentSize: CGSize {
        isEmpty ? .zero : CGSize(width: slot.width * CGFloat(pageCount), height: slot.height)
    }

    package func offsetX(at index: Int) -> CGFloat {
        slot.width * CGFloat(index)
    }

    package func frame(at index: Int) -> CGRect {
        CGRect(x: offsetX(at: index), y: 0, width: slot.width, height: slot.height)
    }

    /// The current index at rest: `round(contentOffset.x / slot width)`,
    /// clamped to the pages that exist, because a rubber-banded offset is past
    /// the last slot and still describes the last page.
    package func settledIndex(atOffsetX x: CGFloat) -> Int? {
        guard !isEmpty, x.isFinite else { return nil }
        let rounded = (x / slot.width).rounded()
        guard rounded.isFinite, abs(rounded) < CGFloat(Int.max) else { return nil }
        return min(max(Int(rounded), 0), pageCount - 1)
    }

    package func liveWindow(around index: Int) -> ClosedRange<Int>? {
        window(around: index, radius: Self.liveRadius)
    }

    package func decodedWindow(around index: Int) -> ClosedRange<Int>? {
        window(around: index, radius: Self.decodedRadius)
    }

    private func window(around index: Int, radius: Int) -> ClosedRange<Int>? {
        guard pageCount > 0, index >= 0, index < pageCount else { return nil }
        return max(0, index - radius)...min(pageCount - 1, index + radius)
    }

    /// A drag that ended here is the append gesture.
    package func isPastEnd(offsetX x: CGFloat) -> Bool {
        guard !isEmpty, x.isFinite else { return false }
        return x > offsetX(at: pageCount - 1) + Self.endBoundaryFraction * slot.width
    }
}

/// Where a page sits inside its slot: fitted to the slot's width, and on the
/// other axis centred when it is shorter than the slot and top-aligned when
/// it is taller.
///
/// Width, not both edges, because the page is read by scrolling down it.
/// A portrait page in a landscape viewport fitted on both edges is a
/// postcard in the middle of the screen with the writing surface wasted on
/// either side; fitted by width it fills the screen and the rest of the page
/// is a vertical scroll away, which is how GoodNotes presents the same page.
/// A page that is wider than tall fits by width either way.
///
/// The same scale is the canvas's zoom floor and the placeholder's rect, so a
/// page that has not been given content yet occupies exactly the rectangle the
/// page will occupy once it has, and the top of a placeholder is the top of
/// the page, where a fresh canvas opens.
package enum PageFit {
    package static func scale(_ geometry: PageGeometry, in slot: CGSize) -> CGFloat {
        guard slot.width > 0, slot.height > 0, geometry.width > 0, geometry.height > 0 else {
            return 1
        }
        return slot.width / CGFloat(geometry.width)
    }

    package static func rect(_ geometry: PageGeometry, in slot: CGSize) -> CGRect {
        let scale = scale(geometry, in: slot)
        let size = CGSize(
            width: CGFloat(geometry.width) * scale,
            height: CGFloat(geometry.height) * scale
        )
        return CGRect(
            x: 0,
            y: max(0, (slot.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }
}
