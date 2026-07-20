import CoreGraphics
import Foundation

/// User-visible events emitted by the Pins subsystem. Persistence remains coordinator-owned.
enum PinOverlayEvent: Equatable {
    case expanded(annotationID: UUID)
    case collapsed(annotationID: UUID)
    case conversationRequested(annotationID: UUID)
    case citationSelected(annotationID: UUID, citationID: UUID)
}

/// A resolved label position paired with the host-projected target anchor.
///
/// `anchor` is never adjusted by Pins. Only `labelFrame` participates in edge avoidance and
/// collision resolution.
struct PinOverlayPlacement: Identifiable, Equatable {
    let id: UUID
    let anchor: CGPoint
    let labelFrame: CGRect
}

enum PinOverlayLayout {
    static let edgePadding: CGFloat = 12
    static let markerClearance: CGFloat = 24

    static func placements(
        for annotations: [PageAnnotation],
        expandedAnnotationID: UUID?,
        in size: CGSize,
        projectAnchor: (PageNormalizedPoint) -> CGPoint
    ) -> [PinOverlayPlacement] {
        var occupiedFrames: [CGRect] = []

        return annotations.map { annotation in
            let anchor = projectAnchor(annotation.target)
            let labelSize = labelSize(
                isExpanded: annotation.id == expandedAnnotationID,
                containerSize: size
            )
            let bounds = CGRect(origin: .zero, size: size).insetBy(
                dx: min(edgePadding, size.width / 2),
                dy: min(edgePadding, size.height / 2)
            )
            let candidates = candidateFrames(
                around: anchor,
                labelSize: labelSize,
                containerSize: size
            ).map { clamp($0, to: bounds) }

            let chosen = candidates.enumerated().min { lhs, rhs in
                let lhsScore = placementScore(
                    frame: lhs.element,
                    anchor: anchor,
                    occupiedFrames: occupiedFrames,
                    tieBreak: lhs.offset
                )
                let rhsScore = placementScore(
                    frame: rhs.element,
                    anchor: anchor,
                    occupiedFrames: occupiedFrames,
                    tieBreak: rhs.offset
                )
                return lhsScore < rhsScore
            }?.element ?? CGRect(origin: .zero, size: labelSize)

            occupiedFrames.append(chosen)
            return PinOverlayPlacement(id: annotation.id, anchor: anchor, labelFrame: chosen)
        }
    }

    static func projectedAnchors(
        for annotations: [PageAnnotation],
        projectAnchor: (PageNormalizedPoint) -> CGPoint
    ) -> [UUID: CGPoint] {
        Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, projectAnchor($0.target)) })
    }

    private static func labelSize(isExpanded: Bool, containerSize: CGSize) -> CGSize {
        let availableWidth = max(0, containerSize.width - (edgePadding * 2))
        let availableHeight = max(0, containerSize.height - (edgePadding * 2))
        let desired = isExpanded ? CGSize(width: 304, height: 208) : CGSize(width: 208, height: 48)
        return CGSize(
            width: min(desired.width, availableWidth),
            height: min(desired.height, availableHeight)
        )
    }

    private static func candidateFrames(
        around anchor: CGPoint,
        labelSize: CGSize,
        containerSize: CGSize
    ) -> [CGRect] {
        let prefersRight = anchor.x <= containerSize.width / 2
        let prefersBelow = anchor.y <= containerSize.height / 2
        let right = CGRect(
            x: anchor.x + markerClearance,
            y: anchor.y - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        let left = CGRect(
            x: anchor.x - markerClearance - labelSize.width,
            y: anchor.y - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        let below = CGRect(
            x: anchor.x - labelSize.width / 2,
            y: anchor.y + markerClearance,
            width: labelSize.width,
            height: labelSize.height
        )
        let above = CGRect(
            x: anchor.x - labelSize.width / 2,
            y: anchor.y - markerClearance - labelSize.height,
            width: labelSize.width,
            height: labelSize.height
        )

        let horizontal = prefersRight ? [right, left] : [left, right]
        let vertical = prefersBelow ? [below, above] : [above, below]
        return horizontal + vertical
    }

    private static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return frame }
        let x = min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width))
        let y = min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
    }

    private static func placementScore(
        frame: CGRect,
        anchor: CGPoint,
        occupiedFrames: [CGRect],
        tieBreak: Int
    ) -> CGFloat {
        let overlapArea = occupiedFrames.reduce(CGFloat.zero) { partialResult, occupied in
            let intersection = frame.intersection(occupied)
            guard !intersection.isNull else { return partialResult }
            return partialResult + (intersection.width * intersection.height)
        }
        let anchorObscuredPenalty: CGFloat = frame.insetBy(dx: -6, dy: -6).contains(anchor) ? 1_000_000 : 0
        let labelCenter = CGPoint(x: frame.midX, y: frame.midY)
        let distance = hypot(labelCenter.x - anchor.x, labelCenter.y - anchor.y)
        return anchorObscuredPenalty + (overlapArea * 100) + distance + CGFloat(tieBreak) / 100
    }
}

/// Standalone deterministic fixtures for previews and module-level verification.
enum PinFixtures {
    static let pageID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    static let fakePin: [PageAnnotation] = [
        annotation(
            id: "11111111-1111-1111-1111-111111111111",
            threadID: "10101010-1010-1010-1010-101010101010",
            target: PageNormalizedPoint(x: 0.62, y: 0.34),
            kind: .explanation,
            teaser: "Key substitution",
            body: "This term is replaced using the identity established on the previous line.",
            citations: [
                Citation(
                    id: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!,
                    title: "Calculus demo text",
                    pageNumber: 42,
                    url: nil,
                    excerpt: "Substitution preserves equality when applied to both sides."
                )
            ],
            status: .complete
        )
    ]

    static let multiPin: [PageAnnotation] = [
        annotation(
            id: "22222222-2222-2222-2222-222222222222",
            threadID: "20202020-2020-2020-2020-202020202020",
            target: PageNormalizedPoint(x: 0.24, y: 0.22),
            kind: .confirmation,
            teaser: "Start here",
            body: "The setup and sign convention are correct.",
            status: .complete
        ),
        annotation(
            id: "33333333-3333-3333-3333-333333333333",
            threadID: "30303030-3030-3030-3030-303030303030",
            target: PageNormalizedPoint(x: 0.69, y: 0.49),
            kind: .issue,
            teaser: "Check this sign",
            body: "The derivative contributes a negative sign here. The explanation is still arriving",
            status: .streaming
        ),
        annotation(
            id: "44444444-4444-4444-4444-444444444444",
            threadID: "40404040-4040-4040-4040-404040404040",
            target: PageNormalizedPoint(x: 0.40, y: 0.76),
            kind: .source,
            teaser: "Related definition",
            body: "This is the definition used by the second step.",
            citations: [
                Citation(
                    id: UUID(uuidString: "45454545-4545-4545-4545-454545454545")!,
                    title: "Calculus demo text",
                    pageNumber: 17,
                    url: URL(string: "https://example.com/calculus"),
                    excerpt: nil
                )
            ],
            status: .complete
        )
    ]

    static let edgePins: [PageAnnotation] = [
        annotation(id: "51515151-5151-5151-5151-515151515151", threadID: "61616161-6161-6161-6161-616161616161", target: PageNormalizedPoint(x: 0.03, y: 0.04), kind: .suggestion, teaser: "Top left", body: "The label stays inside the page while this target remains fixed.", status: .complete),
        annotation(id: "52525252-5252-5252-5252-525252525252", threadID: "62626262-6262-6262-6262-626262626262", target: PageNormalizedPoint(x: 0.97, y: 0.04), kind: .uncertainty, teaser: "Top right", body: "This step may need one more assumption.", status: .complete),
        annotation(id: "53535353-5353-5353-5353-535353535353", threadID: "63636363-6363-6363-6363-636363636363", target: PageNormalizedPoint(x: 0.03, y: 0.96), kind: .confirmation, teaser: "Bottom left", body: "This boundary condition is applied correctly.", status: .complete),
        annotation(id: "54545454-5454-5454-5454-545454545454", threadID: "64646464-6464-6464-6464-646464646464", target: PageNormalizedPoint(x: 0.97, y: 0.96), kind: .issue, teaser: "Bottom right", body: "Recheck the final exponent before simplifying.", status: .complete)
    ]

    private static func annotation(
        id: String,
        threadID: String,
        target: PageNormalizedPoint,
        kind: AnnotationKind,
        teaser: String,
        body: String,
        citations: [Citation] = [],
        status: AnnotationStatus
    ) -> PageAnnotation {
        PageAnnotation(
            id: UUID(uuidString: id)!,
            pageID: pageID,
            threadID: UUID(uuidString: threadID)!,
            target: target,
            targetRegion: nil,
            kind: kind,
            teaser: teaser,
            body: body,
            citations: citations,
            status: status
        )
    }
}

// The coordinator-owned scaffold still spells its canonical annotation array as `[Pin]`.
// This alias preserves buildability without maintaining a second product model.
@available(*, deprecated, renamed: "PageAnnotation")
typealias Pin = PageAnnotation

extension PageAnnotation {
    /// Temporary scaffold adapter. Coordinator integration should supply stable page/thread IDs and
    /// `PageNormalizedPoint` directly, then remove this initializer.
    @available(*, deprecated, message: "Use PageAnnotation with PageNormalizedPoint")
    init(id: UUID, pagePosition: CGPoint, title: String, detail: String) {
        self.init(
            id: id,
            pageID: PinFixtures.pageID,
            threadID: id,
            target: PageNormalizedPoint(x: pagePosition.x, y: pagePosition.y),
            targetRegion: nil,
            kind: .explanation,
            teaser: title,
            body: detail,
            citations: [],
            status: .complete
        )
    }
}
