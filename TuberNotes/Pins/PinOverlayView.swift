import SwiftUI

struct PinOverlayView: View {
    typealias AnchorProjector = (PageNormalizedPoint) -> CGPoint

    let annotations: [PageAnnotation]
    let projectAnchor: AnchorProjector
    let onEvent: ((PinOverlayEvent) -> Void)?
    private let usesNormalizedFitProjection: Bool
    private let allowsConversationRequests: Bool
    private let labelBehavior: PinLabelBehavior

    /// Stable coordinate space for pin drags. Measuring translation in the
    /// dragged pin's own (moving) local space fed the drag back into itself and
    /// made moves jitter; this space does not move with the pin.
    static let dragSpaceName = "pin-overlay-drag-space"

    @State private var expandedAnnotationID: UUID?
    @State private var draggedTargets: [UUID: PageNormalizedPoint] = [:]
    @State private var draggedLabelOffsets: [UUID: CGSize] = [:]

    init(
        annotations: [PageAnnotation],
        projectAnchor: @escaping AnchorProjector,
        initiallyExpandedAnnotationID: UUID? = nil,
        allowsConversationRequests: Bool = true,
        labelBehavior: PinLabelBehavior = .adaptive,
        onEvent: ((PinOverlayEvent) -> Void)? = nil
    ) {
        self.annotations = annotations
        self.projectAnchor = projectAnchor
        self.onEvent = onEvent
        self.usesNormalizedFitProjection = false
        self.allowsConversationRequests = allowsConversationRequests
        self.labelBehavior = labelBehavior
        _expandedAnnotationID = State(initialValue: initiallyExpandedAnnotationID)
    }

    var body: some View {
        GeometryReader { proxy in
            let effectiveProjector: AnchorProjector = usesNormalizedFitProjection
                ? { point in
                    CGPoint(
                        x: point.x * proxy.size.width,
                        y: point.y * proxy.size.height
                    )
                }
                : projectAnchor
            let displayedAnnotations = annotations.map { annotation in
                guard let target = draggedTargets[annotation.id] else { return annotation }
                var displayed = annotation
                displayed.target = target
                return displayed
            }
            let resolvedPlacements = PinOverlayLayout.placements(
                for: displayedAnnotations,
                expandedAnnotationID: expandedAnnotationID,
                in: proxy.size,
                labelBehavior: labelBehavior,
                projectAnchor: effectiveProjector
            )
            let placements = resolvedPlacements.map { placement in
                guard let offset = draggedLabelOffsets[placement.id] else { return placement }
                return placement.keepingLabelOffset(offset, in: proxy.size)
            }
            let annotationsByID = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, $0) })

            ZStack(alignment: .topLeading) {
                ForEach(placements, id: \.id) { placement in
                    if let annotation = annotationsByID[placement.id] {
                        let showsLabel = expandedAnnotationID == placement.id
                        if showsLabel {
                            PinConnector(anchor: placement.anchor, labelFrame: placement.labelFrame)
                        }
                        PinAnchor(
                            annotation: annotation,
                            isExpanded: annotation.id == expandedAnnotationID,
                            canMove: canMovePins,
                            onToggle: { toggle(annotation) },
                            onMoveChanged: { translation in
                                updateDraggedTarget(
                                    for: annotation,
                                    from: placement,
                                    translation: translation,
                                    in: proxy.size,
                                    projectAnchor: effectiveProjector
                                )
                            },
                            onMoveEnded: { translation in
                                commitMove(
                                    of: annotation,
                                    translation: translation,
                                    in: proxy.size,
                                    projectAnchor: effectiveProjector
                                )
                            },
                            onConversationRequested: conversationAction(for: annotation)
                        )
                            .position(placement.anchor)
                        if showsLabel {
                            PinCard(
                                annotation: annotation,
                                isExpanded: annotation.id == expandedAnnotationID,
                                isCompact: labelBehavior == .pageAnchoredCompact,
                                onDismiss: { toggle(annotation) },
                                onConversationRequested: conversationAction(for: annotation),
                                onCitationSelected: { citation in
                                    onEvent?(.citationSelected(annotationID: annotation.id, citationID: citation.id))
                                }
                            )
                            .frame(
                                width: placement.labelFrame.width,
                                height: placement.labelFrame.height,
                                alignment: .topLeading
                            )
                            .position(x: placement.labelFrame.midX, y: placement.labelFrame.midY)
                        }
                    }
                }
            }
            .coordinateSpace(name: PinOverlayView.dragSpaceName)
        }
        .allowsHitTesting(!annotations.isEmpty)
        .onChange(of: annotations.map(\.id)) { _, annotationIDs in
            draggedTargets = draggedTargets.filter { annotationIDs.contains($0.key) }
            draggedLabelOffsets = draggedLabelOffsets.filter { annotationIDs.contains($0.key) }
            guard let expandedAnnotationID, !annotationIDs.contains(expandedAnnotationID) else { return }
            self.expandedAnnotationID = nil
        }
    }

    private func toggle(_ annotation: PageAnnotation) {
        if expandedAnnotationID == annotation.id {
            expandedAnnotationID = nil
            onEvent?(.collapsed(annotationID: annotation.id))
        } else {
            expandedAnnotationID = annotation.id
            onEvent?(.expanded(annotationID: annotation.id))
        }
    }

    private var canMovePins: Bool {
        usesNormalizedFitProjection && onEvent != nil
    }

    private func conversationAction(for annotation: PageAnnotation) -> (() -> Void)? {
        guard allowsConversationRequests,
              annotation.status == .complete,
              onEvent != nil
        else { return nil }
        return { onEvent?(.conversationRequested(annotationID: annotation.id)) }
    }

    private func updateDraggedTarget(
        for annotation: PageAnnotation,
        from placement: PinOverlayPlacement,
        translation: CGSize,
        in size: CGSize,
        projectAnchor: AnchorProjector
    ) {
        if draggedLabelOffsets[annotation.id] == nil {
            draggedLabelOffsets[annotation.id] = CGSize(
                width: placement.labelFrame.midX - placement.anchor.x,
                height: placement.labelFrame.midY - placement.anchor.y
            )
        }
        let original = projectAnchor(annotation.target)
        let target = PinOverlayLayout.pageNormalizedPoint(
            forOverlayPoint: CGPoint(
                x: original.x + translation.width,
                y: original.y + translation.height
            ),
            in: size
        )
        // Per-frame drag updates must not animate; implicit animations made
        // the dot rubber-band behind the finger.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draggedTargets[annotation.id] = target
        }
    }

    private func commitMove(
        of annotation: PageAnnotation,
        translation: CGSize,
        in size: CGSize,
        projectAnchor: AnchorProjector
    ) {
        let original = projectAnchor(annotation.target)
        let target = draggedTargets[annotation.id] ?? PinOverlayLayout.pageNormalizedPoint(
            forOverlayPoint: CGPoint(
                x: original.x + translation.width,
                y: original.y + translation.height
            ),
            in: size
        )
        draggedTargets[annotation.id] = nil
        draggedLabelOffsets[annotation.id] = nil
        guard let target else { return }
        onEvent?(.moved(annotationID: annotation.id, target: target))
    }
}

private enum PinOverlayCoordinateSpace {
    static let name = "pin-overlay-drag"
}

private extension PinOverlayPlacement {
    func keepingLabelOffset(_ offset: CGSize, in size: CGSize) -> PinOverlayPlacement {
        let proposedOrigin = CGPoint(
            x: anchor.x + offset.width - labelFrame.width / 2,
            y: anchor.y + offset.height - labelFrame.height / 2
        )
        let padding = PinOverlayLayout.edgePadding
        let clampedOrigin = CGPoint(
            x: min(max(proposedOrigin.x, padding), max(padding, size.width - padding - labelFrame.width)),
            y: min(max(proposedOrigin.y, padding), max(padding, size.height - padding - labelFrame.height))
        )
        return PinOverlayPlacement(
            id: id,
            anchor: anchor,
            labelFrame: CGRect(
                origin: clampedOrigin,
                size: labelFrame.size
            )
        )
    }
}

extension PinOverlayView {
    /// Temporary adapter for the coordinator-owned scaffold. It still uses canonical annotations and
    /// performs only the scaffold's normalized-fit projection.
    @available(*, deprecated, message: "Supply PageAnnotation values and a host-owned anchor projector")
    init(
        pins: [Pin],
        allowsConversationRequests: Bool = false,
        labelBehavior: PinLabelBehavior = .adaptive,
        onEvent: ((PinOverlayEvent) -> Void)? = nil
    ) {
        self.annotations = pins
        self.projectAnchor = { point in CGPoint(x: point.x, y: point.y) }
        self.onEvent = onEvent
        self.usesNormalizedFitProjection = true
        self.allowsConversationRequests = allowsConversationRequests
        self.labelBehavior = labelBehavior
        _expandedAnnotationID = State(initialValue: nil)
    }
}

private struct PinConnector: View {
    let anchor: CGPoint
    let labelFrame: CGRect

    var body: some View {
        Path { path in
            path.move(to: anchor)
            path.addLine(to: closestPoint(on: labelFrame, to: anchor))
        }
        .stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .accessibilityHidden(true)
    }

    private func closestPoint(on rect: CGRect, to point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}

private struct PinAnchor: View {
    let annotation: PageAnnotation
    let isExpanded: Bool
    let canMove: Bool
    let onToggle: () -> Void
    let onMoveChanged: (CGSize) -> Void
    let onMoveEnded: (CGSize) -> Void
    let onConversationRequested: (() -> Void)?
    @State private var isHoldingForConversation = false
    @State private var touchExceededTapDistance = false
    @State private var isDraggingPin = false
    @State private var isTrackingTouch = false
    @State private var didCompleteHold = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if isHoldingForConversation {
                PinHoldProgressCue()
            }
            Circle()
                .fill(style.color.opacity(isExpanded ? 0.28 : 0.18))
                .frame(width: isExpanded ? 34 : 32, height: isExpanded ? 34 : 32)
            Circle()
                .fill(style.color)
                .frame(width: isExpanded ? 22 : 20, height: isExpanded ? 22 : 20)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.72), lineWidth: 1)
                }
            Image(systemName: style.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .gesture(touchGesture)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                holdTask?.cancel()
                holdTask = nil
                isHoldingForConversation = false
                touchExceededTapDistance = false
                isDraggingPin = false
                isTrackingTouch = false
                didCompleteHold = false
            }
        }
        .shadow(color: style.color.opacity(0.30), radius: 4, y: 2)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(MarkdownTextProjection.plainText(from: annotation.teaser, limit: 160))
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityAction {
            onToggle()
        }
        .accessibilityIdentifier(accessibilityID)
        .onDisappear {
            holdTask?.cancel()
        }
    }

    private var touchGesture: some Gesture {
        // Translation is measured in the overlay's fixed coordinate space, not
        // the pin's own local space — the pin repositions in response to this
        // gesture, and a moving reference frame made dragging jitter and lag.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(PinOverlayView.dragSpaceName))
            .onChanged { value in
                beginTouchIfNeeded()
                let distance = hypot(value.translation.width, value.translation.height)
                if isDraggingPin {
                    onMoveChanged(value.translation)
                } else if distance > 12 {
                    touchExceededTapDistance = true
                    isHoldingForConversation = false
                    holdTask?.cancel()
                    if canMove {
                        isDraggingPin = true
                        onMoveChanged(value.translation)
                    }
                } else if !touchExceededTapDistance {
                    isHoldingForConversation = onConversationRequested != nil
                }
            }
            .onEnded { value in
                endTouch(translation: value.translation)
            }
    }

    private func beginTouchIfNeeded() {
        guard !isTrackingTouch else { return }
        isTrackingTouch = true
        touchExceededTapDistance = false
        isDraggingPin = false
        didCompleteHold = false
        guard let onConversationRequested else { return }
        isHoldingForConversation = true
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled,
                  isTrackingTouch,
                  !touchExceededTapDistance
            else { return }
            didCompleteHold = true
            isHoldingForConversation = false
            onConversationRequested()
        }
    }

    private func endTouch(translation: CGSize) {
        let completedDrag = isDraggingPin
        let shouldToggle = !didCompleteHold && !touchExceededTapDistance
        holdTask?.cancel()
        holdTask = nil
        isHoldingForConversation = false
        isTrackingTouch = false
        touchExceededTapDistance = false
        isDraggingPin = false
        didCompleteHold = false
        if completedDrag {
            onMoveEnded(translation)
        } else if shouldToggle {
            onToggle()
        }
    }

    private var accessibilityHint: String {
        let tapAction = isExpanded ? "Tap to collapse" : "Tap to expand"
        if canMove, onConversationRequested != nil {
            return "\(tapAction), drag to move, or hold for full chat"
        }
        if canMove { return "\(tapAction), or drag to move" }
        if onConversationRequested != nil { return "\(tapAction), or hold for full chat" }
        return tapAction
    }

    private var accessibilityID: String { "pin-anchor-\(annotation.id.uuidString)" }
    private var style: PinVisualStyle { PinVisualStyle(kind: annotation.kind) }
}

private struct PinHoldProgressCue: View {
    @State private var traceProgress: CGFloat = 0.06
    @State private var horizontalNudge: CGFloat = -2

    var body: some View {
        ZStack {
            Circle()
                .stroke(.indigo.opacity(0.20), lineWidth: 3)
            Circle()
                .trim(from: 0, to: traceProgress)
                .stroke(.indigo, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 42, height: 42)
        .offset(x: horizontalNudge)
        .shadow(color: .indigo.opacity(0.35), radius: 4)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.linear(duration: 0.35)) {
                traceProgress = 1
            }
            withAnimation(.easeInOut(duration: 0.12).repeatForever(autoreverses: true)) {
                horizontalNudge = 2
            }
        }
    }
}

private struct PinCard: View {
    let annotation: PageAnnotation
    let isExpanded: Bool
    let isCompact: Bool
    let onDismiss: () -> Void
    let onConversationRequested: (() -> Void)?
    let onCitationSelected: (Citation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(style.color.opacity(0.22))
                        Image(systemName: style.symbol)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(style.color)
                    }
                    .frame(width: 28, height: 28)
                    Text(MarkdownTextProjection.plainText(from: annotation.teaser, limit: 120))
                        .font((isCompact ? Font.callout : Font.body).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(MarkdownTextProjection.plainText(from: annotation.teaser, limit: 160))
                .accessibilityValue(statusAccessibilityValue)
                .accessibilityIdentifier("pin-card-\(annotation.id.uuidString)")
                if let onConversationRequested {
                    Button(action: onConversationRequested) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(style.color)
                    .accessibilityLabel("Open Pin Chat")
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close Pin")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 52)

            if isExpanded {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        statusBody
                        if !annotation.citations.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sources")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(annotation.citations) { citation in
                                    CitationRow(citation: citation) {
                                        onCitationSelected(citation)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .scrollIndicators(.visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            Color(red: 0.075, green: 0.085, blue: 0.12).opacity(0.97),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 16, y: 7)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var statusBody: some View {
        switch annotation.status {
        case .streaming:
            VStack(alignment: .leading, spacing: 9) {
                if annotation.body.isEmpty {
                    Text("Preparing explanation…")
                        .font(.body)
                        .foregroundStyle(.primary)
                } else {
                    MarkdownMessageView(source: annotation.body)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Still investigating")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Explanation is still streaming")
            }
        case .complete:
            if annotation.body.isEmpty {
                Text("No additional explanation.")
                    .font(isCompact ? .callout : .body)
                    .foregroundStyle(.primary)
            } else {
                MarkdownMessageView(source: annotation.body)
                    .font(isCompact ? .callout : .body)
                    .foregroundStyle(.primary)
            }
        case .failed:
            Label(
                annotation.body.isEmpty
                    ? "This Pin could not be completed."
                    : MarkdownTextProjection.plainText(from: annotation.body, limit: 500),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.body)
            .foregroundStyle(.orange)
        }
    }

    private var style: PinVisualStyle { PinVisualStyle(kind: annotation.kind) }

    private var statusAccessibilityValue: String {
        switch annotation.status {
        case .streaming: return "Streaming"
        case .complete: return "Complete"
        case .failed: return "Failed"
        }
    }
}

private struct CitationRow: View {
    let citation: Citation
    let onSelected: () -> Void

    var body: some View {
        Group {
            if let url = safeURL {
                Link(destination: url) {
                    label
                }
                .simultaneousGesture(TapGesture().onEnded { _ in onSelected() })
            } else {
                Button(action: onSelected) {
                    label
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("citation-\(citation.id.uuidString)")
    }

    private var safeURL: URL? {
        guard let url = citation.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: citation.url == nil ? "book.closed" : "link")
                    .foregroundStyle(.indigo)
                Text(sourceTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            if let excerpt = citation.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceTitle: String {
        guard let pageNumber = citation.pageNumber else { return citation.title }
        return "\(citation.title), page \(pageNumber)"
    }

    private var accessibilityLabel: String {
        var parts = [sourceTitle]
        if let excerpt = citation.excerpt, !excerpt.isEmpty { parts.append(excerpt) }
        return parts.joined(separator: ". ")
    }
}

private struct PinVisualStyle {
    let color: Color
    let symbol: String

    init(kind: AnnotationKind) {
        switch kind {
        case .confirmation:
            color = .green
            symbol = "checkmark"
        case .issue:
            color = .red
            symbol = "exclamationmark"
        case .explanation:
            color = .indigo
            symbol = "sparkles"
        case .source:
            color = .blue
            symbol = "book.closed.fill"
        case .uncertainty:
            color = .orange
            symbol = "questionmark"
        case .suggestion:
            color = .purple
            symbol = "lightbulb.fill"
        }
    }
}
