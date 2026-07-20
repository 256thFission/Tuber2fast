import SwiftUI

public extension View {
    /// Mounts PointBackKit over any page-aware canvas. The receiver remains host-owned.
    func pointBack(
        host: any CanvasHost,
        agent: any AgentClient,
        configuration: PointBackConfiguration = .init(),
        onEvent: @escaping @MainActor (PointBackEvent) -> Void = { _ in }
    ) -> some View {
        modifier(PointBackModifier(
            host: host,
            agent: agent,
            configuration: configuration,
            onEvent: onEvent
        ))
    }
}

private struct PointBackModifier: ViewModifier {
    private let host: any CanvasHost
    private let configuration: PointBackConfiguration
    @StateObject private var controller: PointBackController
    @State private var didSeed = false
    @State private var didAutomateFollowUp = false

    init(
        host: any CanvasHost,
        agent: any AgentClient,
        configuration: PointBackConfiguration,
        onEvent: @escaping @MainActor (PointBackEvent) -> Void
    ) {
        self.host = host
        self.configuration = configuration
        _controller = StateObject(wrappedValue: PointBackController(
            host: host,
            agent: agent,
            onEvent: onEvent
        ))
    }

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
                .overlay {
                    PointBackCanvasOverlay(host: host, controller: controller)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)

            if let threadID = controller.presentedConversationID,
               let conversation = controller.conversations[threadID] {
                Divider()
                ConversationSidebar(
                    conversation: conversation,
                    status: controller.conversationStatus[threadID] ?? "Ask a follow-up",
                    onSend: { controller.submitFollowUp($0, threadID: threadID) },
                    onCancel: { controller.cancelFollowUp(threadID: threadID) },
                    onRetry: { controller.retryFollowUp(threadID: threadID) },
                    onDismiss: controller.dismissConversation
                )
                .frame(width: 410)
                .background(Color.secondary.opacity(0.08))
                .accessibilityIdentifier("pointback-conversation-sidebar")
            }
        }
        .task {
            guard !didSeed, let path = configuration.seededLassoPath else { return }
            didSeed = true
            try? await Task.sleep(for: .milliseconds(300))
            await controller.receiveNormalizedPath(path)
            if let intent = configuration.automaticIntent {
                controller.submit(intent)
            }
        }
        .onChange(of: controller.phase) { _, phase in
            guard case .completed = phase,
                  !didAutomateFollowUp,
                  let question = configuration.automaticFollowUpQuestion,
                  let pin = controller.pins.first else { return }
            didAutomateFollowUp = true
            controller.openConversation(for: pin.id)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                controller.submitFollowUp(question, threadID: pin.threadID)
            }
        }
    }
}

private struct PointBackCanvasOverlay: View {
    let host: any CanvasHost
    @ObservedObject var controller: PointBackController
    @State private var liveWindowPath: [CGPoint] = []

    var body: some View {
        GeometryReader { proxy in
            let globalFrame = proxy.frame(in: .global)
            ZStack(alignment: .topLeading) {
                PortableLassoInput { localPath in
                    let windowPath = localPath.map {
                        CGPoint(x: $0.x + globalFrame.minX, y: $0.y + globalFrame.minY)
                    }
                    liveWindowPath = windowPath
                    Task { await controller.receiveWindowPath(windowPath) }
                }
                .allowsHitTesting(controller.presentedConversationID == nil)
                .accessibilityIdentifier("pointback-lasso-overlay")
                selectedGlow(globalFrame: globalFrame)
                pins(globalFrame: globalFrame, size: proxy.size)
                controls(globalFrame: globalFrame, size: proxy.size)
            }
            .clipped()
        }
    }

    @ViewBuilder
    private func selectedGlow(globalFrame: CGRect) -> some View {
        if let selection = controller.selection,
           selection.pageID == host.currentPageID {
            let points = selection.lassoPath.compactMap {
                host.projectToWindow($0, on: selection.pageID).map {
                    CGPoint(x: $0.x - globalFrame.minX, y: $0.y - globalFrame.minY)
                }
            }
            Path { path in
                for (index, point) in points.enumerated() {
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                path.closeSubpath()
            }
            .fill(.indigo.opacity(0.10))
            .stroke(.indigo, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            .shadow(color: .indigo.opacity(0.55), radius: 8)
            .allowsHitTesting(false)
            .accessibilityIdentifier("pointback-selection-glow")
        }
    }

    @ViewBuilder
    private func pins(globalFrame: CGRect, size: CGSize) -> some View {
        ForEach(Array(controller.pins.enumerated()), id: \.element.id) { index, pin in
            if pin.pageID == host.currentPageID,
               let projected = host.projectToWindow(pin.target, on: pin.pageID) {
                let anchor = CGPoint(
                    x: projected.x - globalFrame.minX,
                    y: projected.y - globalFrame.minY
                )
                PinPresentation(
                    pin: pin,
                    anchor: anchor,
                    containerSize: size,
                    verticalOffset: CGFloat(index) * 8,
                    isExpanded: controller.expandedPinID == pin.id,
                    onToggle: { controller.togglePin(pin.id) },
                    onFollowUp: { controller.openConversation(for: pin.id) }
                )
            }
        }
    }

    @ViewBuilder
    private func controls(globalFrame: CGRect, size: CGSize) -> some View {
        if controller.presentedConversationID == nil {
            switch controller.phase {
            case .selected:
                InvestigationActionStrip(
                    onSubmit: controller.submit,
                    onCancel: controller.cancelSelection
                )
                .position(controlPosition(globalFrame: globalFrame, size: size))
            case .submitting, .receiving:
                StatusCard(status: controller.status, primaryTitle: "Cancel", primary: controller.cancelInvestigation)
                    .position(controlPosition(globalFrame: globalFrame, size: size))
            case let .failed(_, recoverable):
                StatusCard(
                    status: controller.status,
                    primaryTitle: recoverable ? "Retry" : nil,
                    primary: controller.retryInvestigation
                )
                .position(controlPosition(globalFrame: globalFrame, size: size))
            case .completed:
                EmptyView()
            case .idle, .capturing:
                Label("Magic Lasso", systemImage: "lasso.badge.sparkles")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: size.width / 2, y: 26)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("pointback-lasso-mode")
            }
        }
    }

    private func controlPosition(globalFrame: CGRect, size: CGSize) -> CGPoint {
        guard let selection = controller.selection else { return CGPoint(x: size.width / 2, y: 90) }
        let center = PagePoint(
            x: min(max(selection.pageBounds.x + selection.pageBounds.width / 2, 0.24), 0.76),
            y: selection.pageBounds.y >= 0.14
                ? selection.pageBounds.y - 0.075
                : min(selection.pageBounds.y + selection.pageBounds.height + 0.075, 0.92)
        )
        guard let window = host.projectToWindow(center, on: selection.pageID) else {
            return CGPoint(x: size.width / 2, y: 90)
        }
        return CGPoint(
            x: min(max(window.x - globalFrame.minX, 190), max(190, size.width - 190)),
            y: min(max(window.y - globalFrame.minY, 62), max(62, size.height - 62))
        )
    }
}

private struct PinPresentation: View {
    let pin: Pin
    let anchor: CGPoint
    let containerSize: CGSize
    let verticalOffset: CGFloat
    let isExpanded: Bool
    let onToggle: () -> Void
    let onFollowUp: () -> Void
    @State private var holdProgress = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: anchor)
                path.addLine(to: CGPoint(x: labelFrame.minX, y: labelFrame.midY))
            }
            .stroke(.secondary.opacity(0.55), lineWidth: 1.5)

            Button(action: onToggle) {
                ZStack {
                    Circle().fill(styleColor.opacity(0.20)).frame(width: 30, height: 30)
                    Circle().fill(styleColor).frame(width: 18, height: 18)
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    if holdProgress {
                        Circle().trim(from: 0, to: 0.78)
                            .stroke(.indigo, style: .init(lineWidth: 3, lineCap: .round))
                            .frame(width: 42, height: 42)
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .position(anchor)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in onFollowUp() })
            .accessibilityLabel(pin.teaser)
            .accessibilityHint(isExpanded ? "Tap to collapse. Hold or use Follow Up." : "Expands this Pin")
            .accessibilityIdentifier("pointback-pin-anchor-\(pin.id.uuidString)")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(styleColor)
                    Text(pin.teaser).font(.subheadline.weight(.semibold)).lineLimit(isExpanded ? 2 : 1)
                    Spacer(minLength: 0)
                }
                if isExpanded {
                    Divider()
                    Text(pin.body.isEmpty ? "Preparing explanation…" : pin.body)
                        .font(.body)
                        .lineLimit(5)
                    Button(action: onFollowUp) {
                        Label("Follow Up", systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint("Opens the conversation tethered to this Pin")
                    Text("Hold the Pin or tap Follow Up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pointback-follow-up-affordance")
                }
            }
            .padding(10)
            .frame(width: labelFrame.width, height: labelFrame.height, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(styleColor.opacity(0.4)) }
            .position(x: labelFrame.midX, y: labelFrame.midY)
            .onTapGesture(perform: onToggle)
        }
    }

    private var labelFrame: CGRect {
        let width: CGFloat = isExpanded ? 304 : 208
        let height: CGFloat = isExpanded ? 190 : 48
        let toRight = anchor.x < containerSize.width - width - 40
        let desiredX = toRight ? anchor.x + 26 : anchor.x - width - 26
        let x = min(max(12, desiredX), max(12, containerSize.width - width - 12))
        let y = min(max(12, anchor.y - height / 2 + verticalOffset), max(12, containerSize.height - height - 12))
        return CGRect(x: x, y: y, width: min(width, containerSize.width - 24), height: min(height, containerSize.height - 24))
    }

    private var styleColor: Color {
        switch pin.kind {
        case .confirmation: .green
        case .issue: .red
        case .explanation: .indigo
        case .source: .blue
        case .uncertainty: .orange
        case .suggestion: .purple
        }
    }

    private var symbol: String {
        switch pin.kind {
        case .confirmation: "checkmark"
        case .issue: "exclamationmark"
        case .explanation: "sparkles"
        case .source: "book.closed.fill"
        case .uncertainty: "questionmark"
        case .suggestion: "lightbulb.fill"
        }
    }
}

private struct InvestigationActionStrip: View {
    let onSubmit: (InvestigationIntent) -> Void
    let onCancel: () -> Void
    @State private var question = ""

    var body: some View {
        HStack(spacing: 8) {
            Button("Explain") { onSubmit(.explain) }.buttonStyle(.borderedProminent)
            Button("Check") { onSubmit(.check) }.buttonStyle(.borderedProminent)
            TextField("Ask…", text: $question)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit { sendQuestion() }
            Button(action: sendQuestion) { Image(systemName: "arrow.up.circle.fill") }
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel, action: onCancel)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .shadow(radius: 6, y: 2)
        .accessibilityIdentifier("pointback-action-strip")
    }

    private func sendQuestion() {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        question = ""
        onSubmit(.ask(question: value))
    }
}

private struct StatusCard: View {
    let status: String
    let primaryTitle: String?
    let primary: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(status).font(.headline)
            if let primaryTitle { Button(primaryTitle, action: primary).buttonStyle(.bordered) }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .accessibilityIdentifier("pointback-status")
    }
}

private struct ConversationSidebar: View {
    let conversation: PinConversation
    let status: String
    let onSend: (String) -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Pin conversation", systemImage: "pin.fill")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close conversation")
            }
            .padding()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(conversation.turns) { turn in
                        Text(turn.text.isEmpty ? "…" : turn.text)
                            .padding(10)
                            .background(
                                turn.role == .user ? Color.indigo.opacity(0.16) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
                    }
                }
                .padding()
            }
            Text(status).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            HStack(spacing: 8) {
                TextField("Ask a follow-up", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Retry", action: onRetry)
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private func send() {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        question = ""
        onSend(value)
    }
}

#if canImport(UIKit)
import UIKit

private struct PortableLassoInput: UIViewRepresentable {
    let onCompleted: ([CGPoint]) -> Void

    func makeUIView(context: Context) -> PortableLassoInputView {
        let view = PortableLassoInputView()
        view.onCompleted = onCompleted
        return view
    }

    func updateUIView(_ view: PortableLassoInputView, context: Context) {
        view.onCompleted = onCompleted
    }
}

private final class PortableLassoInputView: UIView {
    var onCompleted: (([CGPoint]) -> Void)?
    private var points: [CGPoint] = []
    private let line = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        line.fillColor = UIColor.clear.cgColor
        line.strokeColor = UIColor.systemIndigo.cgColor
        line.lineWidth = 3
        line.lineJoin = .round
        line.shadowColor = UIColor.systemIndigo.cgColor
        line.shadowOpacity = 0.55
        line.shadowRadius = 7
        layer.addSublayer(line)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = bounds
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        points = [touch.location(in: self)]
        render()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        points.append(touch.location(in: self))
        render()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        points.append(touch.location(in: self))
        render()
        onCompleted?(points)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        points = []
        line.path = nil
    }

    private func render() {
        let path = UIBezierPath()
        for (index, point) in points.enumerated() {
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        line.path = path.cgPath
    }
}
#else
private struct PortableLassoInput: View {
    let onCompleted: ([CGPoint]) -> Void
    @State private var points: [CGPoint] = []

    var body: some View {
        Color.clear.contentShape(Rectangle()).gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in points.append(value.location) }
                .onEnded { value in
                    points.append(value.location)
                    onCompleted(points)
                    points = []
                }
        )
    }
}
#endif
