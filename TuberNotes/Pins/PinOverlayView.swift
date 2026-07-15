import SwiftUI

struct PinOverlayView: View {
    let pins: [Pin]

    var body: some View {
        GeometryReader { proxy in
            ForEach(pins) { pin in
                PinBadge(pin: pin)
                    .position(
                        x: pin.pagePosition.x * proxy.size.width,
                        y: pin.pagePosition.y * proxy.size.height
                    )
                    .accessibilityIdentifier("pin-\(pin.id.uuidString)")
            }
        }
        .allowsHitTesting(true)
    }
}

private struct PinBadge: View {
    let pin: Pin
    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .foregroundStyle(.yellow)
                Text(isExpanded ? pin.detail : pin.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(isExpanded ? 4 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(.indigo.opacity(0.94), in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
    }
}

