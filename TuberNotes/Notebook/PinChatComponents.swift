import SwiftUI

/// Presentation-only building blocks for the normal Pin Chat experience.
/// These views deliberately know nothing about persistence, provider routing,
/// spatial coordinates, or conversation-tree construction.

struct PinChatContextHeader: View {
    let layerName: String
    let pageLabel: String?
    let pinContext: String?
    let branchCount: Int
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onClose) {
                Label("Back to notebook", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to notebook")

            VStack(alignment: .leading, spacing: 3) {
                Text("Pin Chat")
                    .font(.headline)

                HStack(spacing: 6) {
                    Text(layerName)
                    if let pageLabel {
                        Text("·")
                        Text(pageLabel)
                    }
                    if branchCount > 0 {
                        Text("·")
                        Text("\(branchCount) \(branchCount == 1 ? "branch" : "branches")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)

                if let pinContext, !pinContext.isEmpty {
                    Text(pinContext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel("Pin context: \(pinContext)")
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin-chat-header")
    }
}

struct PinChatTurnView: View {
    let userPrompt: String?
    let assistantMarkdown: String
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let userPrompt, !userPrompt.isEmpty {
                HStack(alignment: .top) {
                    Spacer(minLength: 52)
                    Text(verbatim: userPrompt)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(.primary)
                        .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You: \(userPrompt)")
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.08), in: Circle())
                MarkdownMessageView(source: assistantMarkdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityHint("Assistant response")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin-chat-turn")
    }
}

struct PinChatPendingTurnView: View {
    let userPrompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 40)
                Text(verbatim: userPrompt)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.primary)
                    .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
            }
            HStack(spacing: 8) {
                ProgressView()
                Text("Assistant is responding…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin-chat-pending-turn")
    }
}

struct PinChatBranchRow: View {
    let promptPreview: String
    let responsePreview: String
    let pageLabel: String?
    let descendantCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .indigo)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(promptPreview)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !responsePreview.isEmpty {
                        Text(responsePreview)
                            .font(.caption)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 5) {
                        if let pageLabel { Text(pageLabel) }
                        if descendantCount > 0 {
                            if pageLabel != nil { Text("·") }
                            Text("\(descendantCount) \(descendantCount == 1 ? "reply" : "replies")")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.72) : .secondary)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            .padding(12)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.indigo : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(promptPreview)
        .accessibilityValue(branchAccessibilityValue)
        .accessibilityHint("Opens this conversation branch")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("pin-chat-branch")
    }

    private var branchAccessibilityValue: String {
        [
            pageLabel,
            responsePreview.isEmpty ? nil : responsePreview,
            descendantCount > 0 ? "\(descendantCount) replies" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

struct PinChatComposer: View {
    @Binding var text: String
    let continuationLabel: String?
    let isSending: Bool
    let canSend: Bool
    let failureMessage: String?
    let onSend: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let continuationLabel, !continuationLabel.isEmpty {
                Label(continuationLabel, systemImage: "arrowshape.turn.up.left.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Continuing from \(continuationLabel)")
            }

            if let failureMessage, !failureMessage.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                    Button("Retry", action: onRetry)
                        .font(.caption.weight(.semibold))
                        .disabled(isSending)
                }
                .accessibilityElement(children: .contain)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    continuationLabel == nil ? "Ask a question…" : "Ask a follow-up…",
                    text: $text,
                    axis: .vertical
                )
                    .lineLimit(1...6)
                    .focused($isComposerFocused)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
                    .submitLabel(.send)
                    .onSubmit {
                        guard sendIsEnabled else { return }
                        onSend()
                    }
                    .accessibilityLabel("Message")
                    .accessibilityHint(continuationLabel == nil ? "Starts a new conversation" : "Sends a follow-up")

                if isSending {
                    Button(action: onCancel) {
                        Image(systemName: "stop.fill")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityLabel("Cancel response")
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!sendIsEnabled)
                    .accessibilityLabel("Send message")
                }
            }

            if isSending {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Assistant is responding…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Assistant is responding")
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin-chat-composer")
    }

    private var sendIsEnabled: Bool {
        canSend && !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
