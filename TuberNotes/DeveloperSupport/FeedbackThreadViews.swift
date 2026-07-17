import PencilKit
import SwiftUI

#if DEBUG
struct FeedbackThreadBar: View {
    @ObservedObject var session: FeedbackThreadSession
    @State private var isCollapsed = false
    @State private var settledOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        if let feedbackThread = session.activeFeedbackThread {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Label(feedbackThread.title, systemImage: "text.bubble")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(feedbackThread.state == .open ? "Your turn" : "Response sent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    contextForwardButton
                    Button {
                        withAnimation(.snappy) { isCollapsed.toggle() }
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCollapsed ? "Expand feedback context" : "Collapse feedback context")
                }

                if !isCollapsed {
                    quickContext(feedbackThread)
                }
            }
            .padding(14)
            .frame(maxWidth: isCollapsed ? 360 : 520, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.65), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .offset(x: settledOffset.width + dragOffset.width, y: settledOffset.height + dragOffset.height)
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        settledOffset.width += value.translation.width
                        settledOffset.height += value.translation.height
                    }
            )
            .accessibilityIdentifier("feedback-thread-bar")
            .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
            .fullScreenCover(isPresented: $session.isPresentingFullThread) {
                FeedbackThreadView(session: session)
            }
        }
    }

    @ViewBuilder
    private func quickContext(_ feedbackThread: FeedbackThread) -> some View {
        if feedbackThread.reviewRun != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Asynchronous review")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(session.selectedReviewStep?.title ?? "Review complete")
                    .font(.body.weight(.semibold))
                Text(session.reviewProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Review") { session.isPresentingFullThread = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
            }
        } else if let turn = session.currentTurn {
            VStack(alignment: .leading, spacing: 8) {
                Text(turn.body ?? "Current feedback turn")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if let interaction = turn.interaction, interaction.kind == .singleChoice,
                   session.activeQuestion?.id == turn.id {
                    HStack(spacing: 8) {
                        ForEach(interaction.options ?? []) { option in
                            Button(option.label) {
                                session.answer(turn, optionID: option.id, comment: "")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else if feedbackThread.state == .open {
                    HStack(spacing: 8) {
                        TextField("Reply to this turn", text: draftReply)
                            .textFieldStyle(.roundedBorder)
                        Button("Send") {
                            session.sendReply(session.draftReply)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(session.draftReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Text("Your response is read-only while the model is working.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if session.isLiveComparison {
            HStack(spacing: 8) {
                if session.isResettingComparison {
                    ProgressView().controlSize(.small)
                    Text("Resetting").font(.caption.weight(.semibold))
                } else {
                    comparisonButton("A", variant: "a")
                    comparisonButton("B", variant: "b")
                    Button("Reset") { session.resetComparison() }
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.semibold))
                }
            }
        }

        if feedbackThread.reviewRun == nil {
            HStack(spacing: 8) {
                Button("View Full Thread") { session.isPresentingFullThread = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                Spacer()
                Button("Blocked") { session.setState(.blocked) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button("Resolve") { session.setState(.resolved) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
    }

    @ViewBuilder
    private var contextForwardButton: some View {
        if session.queuedCandidate != nil {
            Button { session.skipForward() } label: {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.indigo)
            .accessibilityLabel("Skip to next queued feedback thread")
        }
    }

    private func comparisonButton(_ label: String, variant: String) -> some View {
        Button(label) { session.selectVariant(variant) }
            .buttonStyle(.bordered)
            .tint(session.activeVariant == variant ? .accentColor : .secondary)
            .font(.caption.weight(.bold))
    }

    private var draftReply: Binding<String> {
        Binding(get: { session.draftReply }, set: { session.draftReply = $0 })
    }
}

struct FeedbackThreadView: View {
    @ObservedObject var session: FeedbackThreadSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let feedbackThread = session.activeFeedbackThread, feedbackThread.reviewRun != nil {
                    ReviewRunContent(session: session, feedbackThread: feedbackThread)
                } else if let feedbackThread = session.activeFeedbackThread {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                header(feedbackThread)
                                ForEach(feedbackThread.messages) { message in
                                    messageView(message, feedbackThreadID: feedbackThread.id)
                                        .id(message.id)
                                }
                                pendingAttachmentDraft
                                interactionComposer
                                threadActions
                            }
                            .padding(20)
                        }
                        .onAppear { if let last = feedbackThread.messages.last { proxy.scrollTo(last.id) } }
                    }
                } else {
                    ContentUnavailableView("No active feedback", systemImage: "text.bubble")
                }
            }
            .navigationTitle(session.activeReviewRun == nil ? "Feedback Thread" : "Review Run")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Capture & Annotate", systemImage: "pencil.and.scribble") {
                        session.isPresentingFullThread = false
                        if session.activeReviewRun == nil {
                            session.requestCapture()
                        } else {
                            session.requestCapture(reviewStepID: session.selectedReviewStep?.id)
                        }
                    }
                    .disabled(
                        session.activeFeedbackThread == nil
                        || (session.activeReviewRun != nil && session.selectedReviewStep?.allowsAttachment != true)
                        || session.selectedReviewStep?.isTerminal == true
                    )
                }
            }
        }
        .accessibilityIdentifier("feedback-thread-view")
    }

    private func header(_ value: FeedbackThread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value.title).font(.title2.bold())
            HStack {
                Text(value.state == .open ? "Ready for your response" : "Your response was sent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(value.messages.count) messages").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func messageView(_ message: FeedbackMessage, feedbackThreadID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.author == .human ? "You" : "TuberNotes Review").font(.caption.bold())
                Spacer()
                Text(message.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            if let body = message.body { Text(body).textSelection(.enabled) }
            ForEach(message.attachments) { attachment in
                FeedbackAttachmentPreview(attachment: attachment, feedbackThreadID: feedbackThreadID)
            }
            if let selectedOptionID = message.selectedOptionID {
                Text("Selected: \(selectedOptionID)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.author == .human ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var pendingAttachmentDraft: some View {
        if let capture = session.pendingCapture,
           capture.feedbackThreadID == session.activeFeedbackThread?.id {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(uiImage: capture.annotatedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Pending annotated screenshot")
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Attached to this reply", systemImage: "paperclip")
                            .font(.headline)
                        Text("Complete the reply below, then send both as one message.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Remove Attachment", role: .destructive) {
                            session.removePendingCapture()
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("pending-feedback-attachment")
        }
    }

    @ViewBuilder
    private var interactionComposer: some View {
        if let question = session.activeQuestion, question.interaction?.kind == .singleChoice {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose one").font(.headline)
                ForEach(question.interaction?.options ?? []) { option in
                    Button {
                        session.draftSelectedOptionID = option.id
                    } label: {
                        Label(option.label, systemImage: session.draftSelectedOptionID == option.id ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.plain)
                }
                if question.interaction?.allowsComment != false {
                    TextField("Optional comment", text: draftChoiceComment, axis: .vertical).textFieldStyle(.roundedBorder)
                }
                Button("Send Answer") {
                    guard let selectedOptionID = session.draftSelectedOptionID else { return }
                    session.answer(question, optionID: selectedOptionID, comment: session.draftChoiceComment)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.draftSelectedOptionID == nil)
            }
            .padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if session.isLiveComparison {
            VStack(alignment: .leading, spacing: 10) {
                Text("A/B preference").font(.headline)
                Picker("Preference", selection: draftPreference) {
                    ForEach(FeedbackThreadSession.Preference.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Optional comment", text: draftPreferenceComment, axis: .vertical).textFieldStyle(.roundedBorder)
                Button("Send Preference") {
                    session.submitPreference(session.draftPreference, comment: session.draftPreferenceComment)
                }.buttonStyle(.borderedProminent)
            }
            .padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if session.activeQuestion?.interaction?.kind == .freeText || session.activeFeedbackThread?.state == .open {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Reply", text: draftReply, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
                Button("Send Reply") {
                    session.sendReply(session.draftReply)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.draftReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.pendingCapture == nil)
                .accessibilityIdentifier(session.pendingCapture == nil ? "send-feedback-reply" : "send-reply-with-attachment")
            }
        } else {
            Text("Awaiting the model. Your submitted response is read-only.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var threadActions: some View {
        HStack {
            Button("Blocked") { session.setState(.blocked) }.buttonStyle(.bordered)
            Button("Resolve") { session.setState(.resolved) }.buttonStyle(.borderedProminent)
        }
    }

    private var draftReply: Binding<String> {
        Binding(get: { session.draftReply }, set: { session.draftReply = $0 })
    }

    private var draftChoiceComment: Binding<String> {
        Binding(get: { session.draftChoiceComment }, set: { session.draftChoiceComment = $0 })
    }

    private var draftPreference: Binding<FeedbackThreadSession.Preference> {
        Binding(get: { session.draftPreference }, set: { session.draftPreference = $0 })
    }

    private var draftPreferenceComment: Binding<String> {
        Binding(get: { session.draftPreferenceComment }, set: { session.draftPreferenceComment = $0 })
    }
}

private struct ReviewRunContent: View {
    @ObservedObject var session: FeedbackThreadSession
    let feedbackThread: FeedbackThread

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text(feedbackThread.title).font(.title2.bold()).padding(.bottom, 4)
                    Text(session.reviewProgress).font(.caption).foregroundStyle(.secondary)
                    ForEach(session.activeReviewRun?.steps ?? []) { step in
                        Button { session.selectReviewStep(step.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: icon(for: step.state))
                                    .foregroundStyle(color(for: step.state))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.title).font(.subheadline.weight(.semibold))
                                    Text(label(for: step.state)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(
                                session.selectedReviewStep?.id == step.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .frame(width: 300)

            Divider()

            ScrollView {
                if let step = session.selectedReviewStep {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Review point", selection: reviewPointSelection) {
                            ForEach(session.activeReviewRun?.steps ?? []) { point in
                                Label(point.title, systemImage: icon(for: point.state))
                                    .tag(point.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(session.activeReviewRun?.state != .active)
                        .accessibilityIdentifier("review-point-picker")

                        Text(step.title).font(.title.bold())
                        Text(step.humanInstruction).font(.title3)

                        if step.state == .locked {
                            Label("Complete the prerequisite checks first.", systemImage: "lock")
                                .foregroundStyle(.secondary)
                        } else if step.state == .blocked, let reason = step.blockedReason {
                            Label(reason, systemImage: "exclamationmark.octagon")
                                .foregroundStyle(.orange)
                        } else if step.isTerminal {
                            Label("Recorded as \(label(for: step.state)).", systemImage: icon(for: step.state))
                                .foregroundStyle(color(for: step.state))
                        } else {
                            responseControls(step)
                        }

                        ForEach(step.attachments) { attachment in
                            VStack(alignment: .leading, spacing: 6) {
                                FeedbackAttachmentPreview(attachment: attachment, feedbackThreadID: feedbackThread.id)
                                if !step.isTerminal {
                                    Button("Remove Annotation", role: .destructive) {
                                        session.removeReviewAttachment(attachment.id)
                                    }
                                    .font(.caption.weight(.semibold))
                                }
                            }
                        }

                        if session.activeReviewRun?.state == .active {
                            Divider().padding(.top, 8)
                            Button("Finish Review") { session.submitReviewRun() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(!session.canFinishReview)
                                .accessibilityIdentifier("finish-review-run")
                            if !session.canFinishReview {
                                Text("Finish becomes available when every check has a recorded outcome.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Label("Review submitted", systemImage: "checkmark.seal.fill")
                                .font(.headline).foregroundStyle(.green)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(28)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("review-run-view")
    }

    @ViewBuilder
    private func responseControls(_ step: ReviewStep) -> some View {
        if step.responseKind == "choice" {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(step.options) { option in
                    Button { session.selectReviewOption(option.id) } label: {
                        Label(option.label, systemImage: step.selectedOptionID == option.id ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if step.allowsComment {
            TextField("Comment", text: reviewComment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
        }

        if step.allowsAttachment {
            Button("Capture & Annotate", systemImage: "pencil.and.scribble") {
                session.isPresentingFullThread = false
                session.requestCapture(reviewStepID: step.id)
            }
            .buttonStyle(.bordered)
        }

        HStack(spacing: 10) {
            Button("Pass") { session.completeReviewStep(.passed) }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(step.responseKind == "choice" && step.selectedOptionID == nil)
            Button("Fail") { session.completeReviewStep(.failed) }
                .buttonStyle(.borderedProminent).tint(.red)
            Button("Blocked") { session.completeReviewStep(.blocked) }
                .buttonStyle(.bordered).tint(.orange)
            Button("Skip") { session.completeReviewStep(.skipped) }
                .buttonStyle(.bordered)
        }
    }

    private var reviewComment: Binding<String> {
        Binding(
            get: { session.selectedReviewStep?.comment ?? "" },
            set: { session.updateReviewComment($0) }
        )
    }

    private var reviewPointSelection: Binding<String> {
        Binding(
            get: { session.selectedReviewStep?.id ?? "" },
            set: { session.selectReviewStep($0) }
        )
    }

    private func icon(for state: ReviewStepState) -> String {
        switch state {
        case .locked: "lock.fill"
        case .ready: "circle"
        case .inProgress: "circle.dotted"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "forward.circle.fill"
        case .blocked: "exclamationmark.octagon.fill"
        }
    }

    private func color(for state: ReviewStepState) -> Color {
        switch state {
        case .passed: .green
        case .failed: .red
        case .blocked: .orange
        default: .secondary
        }
    }

    private func label(for state: ReviewStepState) -> String {
        switch state {
        case .inProgress: "In progress"
        default: state.rawValue.capitalized
        }
    }
}

private struct FeedbackAttachmentPreview: View {
    let attachment: FeedbackAttachment
    let feedbackThreadID: String

    var body: some View {
        if let annotated = UIImage(contentsOfFile: annotatedPath) {
            VStack(alignment: .leading) {
                labeledImage(annotated, label: "Annotated")
                Label("Clean original retained for collection", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let caption = attachment.caption { Text(caption).font(.caption) }
            }
        } else {
            Label("Screenshot \(attachment.id)", systemImage: "photo")
        }
    }

    private func labeledImage(_ image: UIImage, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.bold()).foregroundStyle(.secondary)
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var annotatedPath: String {
        FeedbackThreadStore.rootURL
            .appendingPathComponent(feedbackThreadID, isDirectory: true)
            .appendingPathComponent(attachment.annotatedPath).path
    }

}

struct FeedbackAnnotationView: View {
    @ObservedObject var session: FeedbackThreadSession
    @State private var drawing = PKDrawing()

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if let image = session.capturedImage {
                    ZStack {
                        Color.black.opacity(0.9).ignoresSafeArea()
                        Image(uiImage: image).resizable().scaledToFit()
                        FeedbackPencilCanvas(drawing: $drawing)
                            .aspectRatio(image.size, contentMode: .fit)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Draw on the screenshot, then attach it to a reply.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .navigationTitle("Annotate Viewport")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { session.cancelCapture() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Attach") { session.attachCapture(drawing: drawing) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("attach-feedback-annotation")
                }
            }
        }
        .accessibilityIdentifier("feedback-annotation-view")
    }
}

private struct FeedbackPencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 5)
        canvas.delegate = context.coordinator
        let toolPicker = PKToolPicker()
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
        context.coordinator.toolPicker = toolPicker
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }
    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<PKDrawing>
        var toolPicker: PKToolPicker?
        init(drawing: Binding<PKDrawing>) { self.drawing = drawing }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { drawing.wrappedValue = canvasView.drawing }
    }
}
#endif
