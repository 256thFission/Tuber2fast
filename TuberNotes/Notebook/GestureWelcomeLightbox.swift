import SwiftUI

/// First-run orientation for the notebook's existing gesture vocabulary.
/// This view explains behavior only; gesture recognition stays with the
/// canvas, toolbar, and Pencil interaction owners.
struct GestureWelcomeLightbox: View {
    static let dismissedStorageKey = "tuber.gestureWelcome.dismissed.v1"

    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    private let items = [
        GestureGuideItem(
            gesture: "Pencil · hold",
            title: "Write & straighten",
            detail: "Write naturally with Apple Pencil. With straight-line snapping on, pause at the end of a stroke to straighten it.",
            systemImage: "pencil.tip"
        ),
        GestureGuideItem(
            gesture: "Pinch · drag",
            title: "Zoom & move",
            detail: "Pinch to zoom. When zoomed in, drag the page with one finger—or two when Finger Drawing is on.",
            systemImage: "hand.draw"
        ),
        GestureGuideItem(
            gesture: "Swipe · pull & hold",
            title: "Turn & add pages",
            detail: "At page fit, swipe in your chosen page direction. On the last page, pull forward and hold to add one.",
            systemImage: "book.closed"
        ),
        GestureGuideItem(
            gesture: "Press · slide",
            title: "Shape your tools",
            detail: "Hold a writing tool and slide for width. Hold the color and slide across your favorites.",
            systemImage: "slider.horizontal.3"
        ),
        GestureGuideItem(
            gesture: "Circle · drag",
            title: "Select or ask",
            detail: "Choose a lasso and circle content. Move the selection, or use the sparkle lasso to ask for guidance.",
            systemImage: "lasso"
        ),
        GestureGuideItem(
            gesture: "Double-tap · squeeze",
            title: "Use Pencil shortcuts",
            detail: "On a supported Apple Pencil, double-tap follows your Pencil preference; when enabled, squeeze opens the tool palette.",
            systemImage: "wand.and.stars"
        ),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(isVisible ? 0.5 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)

                lightbox
                    .frame(
                        width: max(min(proxy.size.width - 32, 780), 300),
                        height: max(min(proxy.size.height - 32, 730), 360)
                    )
                    .scaleEffect(isVisible ? 1 : 0.96)
                    .opacity(isVisible ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("gesture-welcome-lightbox")
        .onAppear {
            if reduceMotion {
                isVisible = true
            } else {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    isVisible = true
                }
            }
        }
    }

    private var lightbox: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(items) { item in
                        GestureGuideCard(item: item)
                    }
                }
                .padding(22)
            }

            Divider()

            footer
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 36, y: 18)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.gradient)
                Image(systemName: "scribble.variable")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Welcome to TuberNotes")
                    .font(.title2.weight(.bold))
                Text("A few gestures keep the page clear and your tools close.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close gesture guide")
            .accessibilityIdentifier("gesture-welcome-close")
        }
        .padding(24)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                footerNote
                Spacer(minLength: 12)
                startButton
            }

            VStack(alignment: .leading, spacing: 12) {
                footerNote
                startButton
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var footerNote: some View {
        Text("Change page direction, Finger Drawing, and Pencil shortcuts in notebook settings.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var startButton: some View {
        Button("Got it", action: dismiss)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Dismisses the gesture guide")
            .accessibilityIdentifier("gesture-welcome-start")
    }

    private func dismiss() {
        guard isVisible else { return }
        if reduceMotion {
            onDismiss()
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            isVisible = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            onDismiss()
        }
    }
}

private struct GestureGuideItem: Identifiable {
    let gesture: String
    let title: String
    let detail: String
    let systemImage: String

    var id: String { title }
}

private struct GestureGuideCard: View {
    let item: GestureGuideItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.gesture.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(Color.accentColor)
                Text(item.title)
                    .font(.headline)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
