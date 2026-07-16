import PencilKit
import SwiftUI

#if DEBUG
struct FeedbackThreadBar: View {
    @ObservedObject var session: FeedbackThreadSession
    @State private var isCollapsed = true
    @State private var settledOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        if let feedbackThread = session.activeFeedbackThread {
            HStack(spacing: 10) {
                Button {
                    session.isPresentingFullThread = true
                } label: {
                    Label(feedbackThread.title, systemImage: "text.bubble")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                Text(feedbackThread.state.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                if session.isLiveComparison && !isCollapsed {
                    Divider().frame(height: 22)
                    comparisonButton("A", variant: "a")
                    comparisonButton("B", variant: "b")
                    Button("Reset") { session.resetComparison() }
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.semibold))
                }

                Button {
                    withAnimation(.snappy) { isCollapsed.toggle() }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand feedback bar" : "Collapse feedback bar")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.orange.opacity(0.65), lineWidth: 1) }
            .contentShape(Capsule())
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

    private func comparisonButton(_ label: String, variant: String) -> some View {
        Button(label) { session.selectVariant(variant) }
            .buttonStyle(.bordered)
            .tint(session.activeVariant == variant ? .accentColor : .secondary)
            .font(.caption.weight(.bold))
    }
}

struct FeedbackThreadView: View {
    @ObservedObject var session: FeedbackThreadSession
    @Environment(\.dismiss) private var dismiss
    @State private var reply = ""
    @State private var selectedOptionID: String?
    @State private var choiceComment = ""
    @State private var preference = FeedbackThreadSession.Preference.none
    @State private var preferenceComment = ""

    var body: some View {
        NavigationStack {
            Group {
                if let feedbackThread = session.activeFeedbackThread {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                header(feedbackThread)
                                ForEach(feedbackThread.messages) { message in
                                    messageView(message, feedbackThreadID: feedbackThread.id)
                                        .id(message.id)
                                }
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
            .navigationTitle("Feedback Thread")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Capture & Annotate", systemImage: "pencil.and.scribble") {
                        session.isPresentingFullThread = false
                        session.requestCapture()
                    }
                    .disabled(session.activeFeedbackThread == nil)
                }
            }
        }
        .accessibilityIdentifier("feedback-thread-view")
    }

    private func header(_ value: FeedbackThread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value.title).font(.title2.bold())
            Text(value.objective).foregroundStyle(.secondary)
            HStack {
                Text(value.state.rawValue).font(.caption.monospaced())
                Text(value.scenario).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text("\(value.messages.count) messages").font(.caption)
            }
        }
    }

    private func messageView(_ message: FeedbackMessage, feedbackThreadID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.author.rawValue.capitalized).font(.caption.bold())
                Text("#\(message.sequence)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(message.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            if let body = message.body { Text(body).textSelection(.enabled) }
            if let interaction = message.interaction {
                Text(interaction.kind.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ForEach(message.attachments) { attachment in
                FeedbackAttachmentPreview(attachment: attachment, feedbackThreadID: feedbackThreadID)
            }
            if message.selectedOptionID != nil || message.inReplyTo != nil {
                Text([message.selectedOptionID, message.inReplyTo].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.author == .human ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var interactionComposer: some View {
        if let question = session.activeQuestion, question.interaction?.kind == .singleChoice {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose one").font(.headline)
                ForEach(question.interaction?.options ?? []) { option in
                    Button {
                        selectedOptionID = option.id
                    } label: {
                        Label(option.label, systemImage: selectedOptionID == option.id ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.plain)
                }
                if question.interaction?.allowsComment != false {
                    TextField("Optional comment", text: $choiceComment, axis: .vertical).textFieldStyle(.roundedBorder)
                }
                Button("Send Answer") {
                    guard let selectedOptionID else { return }
                    session.answer(question, optionID: selectedOptionID, comment: choiceComment)
                    self.selectedOptionID = nil
                    choiceComment = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedOptionID == nil)
            }
            .padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if session.isLiveComparison {
            VStack(alignment: .leading, spacing: 10) {
                Text("A/B preference").font(.headline)
                Picker("Preference", selection: $preference) {
                    ForEach(FeedbackThreadSession.Preference.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Optional comment", text: $preferenceComment, axis: .vertical).textFieldStyle(.roundedBorder)
                Button("Send Preference") {
                    session.submitPreference(preference, comment: preferenceComment)
                    preferenceComment = ""
                }.buttonStyle(.borderedProminent)
            }
            .padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if session.activeQuestion?.interaction?.kind == .freeText || session.activeFeedbackThread?.state == .open {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Reply", text: $reply, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
                Button("Send Reply") {
                    session.sendReply(reply)
                    reply = ""
                }.buttonStyle(.borderedProminent).disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
}

private struct FeedbackAttachmentPreview: View {
    let attachment: FeedbackAttachment
    let feedbackThreadID: String

    var body: some View {
        if let annotated = UIImage(contentsOfFile: annotatedPath) {
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    if let clean = UIImage(contentsOfFile: cleanPath) {
                        labeledImage(clean, label: "Clean")
                    }
                    labeledImage(annotated, label: "Annotated")
                }
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

    private var cleanPath: String {
        FeedbackThreadStore.rootURL
            .appendingPathComponent(feedbackThreadID, isDirectory: true)
            .appendingPathComponent(attachment.cleanPath).path
    }
}

struct FeedbackAnnotationView: View {
    @ObservedObject var session: FeedbackThreadSession
    @State private var drawing = PKDrawing()
    @State private var caption = ""

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
                TextField("Optional caption", text: $caption).textFieldStyle(.roundedBorder).padding().background(.bar)
            }
            .navigationTitle("Annotate Viewport")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { session.cancelCapture() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") { session.sendCapture(drawing: drawing, caption: caption) }.buttonStyle(.borderedProminent)
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
        return canvas
    }
    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<PKDrawing>
        init(drawing: Binding<PKDrawing>) { self.drawing = drawing }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { drawing.wrappedValue = canvasView.drawing }
    }
}
#endif
