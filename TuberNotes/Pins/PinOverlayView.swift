import SwiftUI

struct PinOverlayView: View {
    typealias AnchorProjector = (PageNormalizedPoint) -> CGPoint

    let annotations: [PageAnnotation]
    let projectAnchor: AnchorProjector
    let onEvent: ((PinOverlayEvent) -> Void)?
    private let usesNormalizedFitProjection: Bool

    @State private var expandedAnnotationID: UUID?

    init(
        annotations: [PageAnnotation],
        projectAnchor: @escaping AnchorProjector,
        initiallyExpandedAnnotationID: UUID? = nil,
        onEvent: ((PinOverlayEvent) -> Void)? = nil
    ) {
        self.annotations = annotations
        self.projectAnchor = projectAnchor
        self.onEvent = onEvent
        self.usesNormalizedFitProjection = false
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
            let placements = PinOverlayLayout.placements(
                for: annotations,
                expandedAnnotationID: expandedAnnotationID,
                in: proxy.size,
                projectAnchor: effectiveProjector
            )

            ZStack(alignment: .topLeading) {
                ForEach(placements) { placement in
                    if let annotation = annotations.first(where: { $0.id == placement.id }) {
                        PinConnector(anchor: placement.anchor, labelFrame: placement.labelFrame)
                        PinAnchor(
                            annotation: annotation,
                            isExpanded: annotation.id == expandedAnnotationID,
                            onToggle: { toggle(annotation) },
                            onConversationRequested: {
                                onEvent?(.conversationRequested(annotationID: annotation.id))
                            }
                        )
                            .position(placement.anchor)
                        PinCard(
                            annotation: annotation,
                            isExpanded: annotation.id == expandedAnnotationID,
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
        .allowsHitTesting(!annotations.isEmpty)
        .onChange(of: annotations.map(\.id)) { _, annotationIDs in
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
}

extension PinOverlayView {
    /// Temporary adapter for the coordinator-owned scaffold. It still uses canonical annotations and
    /// performs only the scaffold's normalized-fit projection.
    @available(*, deprecated, message: "Supply PageAnnotation values and a host-owned anchor projector")
    init(pins: [Pin], onEvent: ((PinOverlayEvent) -> Void)? = nil) {
        self.annotations = pins
        self.projectAnchor = { point in CGPoint(x: point.x, y: point.y) }
        self.onEvent = onEvent
        self.usesNormalizedFitProjection = true
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
    let onToggle: () -> Void
    let onConversationRequested: () -> Void

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .fill(style.color.opacity(0.20))
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(style.color)
                    .frame(width: 18, height: 18)
                Image(systemName: style.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.65, maximumDistance: 12) {
            guard isExpanded else { return }
            onConversationRequested()
        }
        .shadow(color: style.color.opacity(0.30), radius: 4, y: 2)
        .accessibilityLabel(annotation.teaser)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Tap to collapse, or touch and hold for follow-up" : "Expands this Pin")
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityIdentifier("pin-anchor-\(annotation.id.uuidString)")
    }

    private var style: PinVisualStyle { PinVisualStyle(kind: annotation.kind) }
}

private struct PinCard: View {
    let annotation: PageAnnotation
    let isExpanded: Bool
    let onCitationSelected: (Citation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: style.symbol)
                    .foregroundStyle(style.color)
                    .frame(width: 18)
                Text(annotation.teaser)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 48)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(annotation.teaser)
            .accessibilityValue(statusAccessibilityValue)
            .accessibilityIdentifier("pin-card-\(annotation.id.uuidString)")

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
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(style.color.opacity(0.40), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
    }

    @ViewBuilder
    private var statusBody: some View {
        switch annotation.status {
        case .streaming:
            VStack(alignment: .leading, spacing: 9) {
                Text(annotation.body.isEmpty ? "Preparing explanation…" : annotation.body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
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
            Text(annotation.body.isEmpty ? "No additional explanation." : annotation.body)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        case .failed:
            Label(
                annotation.body.isEmpty ? "This Pin could not be completed." : annotation.body,
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
            if let url = citation.url {
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
