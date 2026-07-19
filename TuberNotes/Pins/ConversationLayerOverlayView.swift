import SwiftUI

struct ConversationLayerOverlayView: View {
    let layers: [ConversationLayer]
    @Binding var selectedLayerID: UUID?

    private var selectedLayer: ConversationLayer? {
        layers.first { $0.id == selectedLayerID } ?? layers.first
    }

    var body: some View {
        ZStack {
            PinOverlayView(pins: selectedLayer?.conversations ?? [])

            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.indigo)
                        .accessibilityHidden(true)

                    Text("Conversation layers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Divider()
                        .frame(height: 20)

                    ForEach(layers) { layer in
                        layerButton(layer)
                    }
                }
                .padding(6)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(.black.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

                Spacer()
            }
        }
        .onAppear {
            selectFirstLayerIfNeeded()
        }
        .onChange(of: layers) { _, _ in
            selectFirstLayerIfNeeded()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-layer-overlay")
    }

    private func layerButton(_ layer: ConversationLayer) -> some View {
        let isSelected = layer.id == selectedLayer?.id

        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                selectedLayerID = layer.id
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: layer.symbolName)
                    .font(.caption.weight(.semibold))
                Text(layer.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(layer.conversations.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .foregroundStyle(isSelected ? Color.indigo : Color.secondary)
                    .background(
                        isSelected ? Color.white.opacity(0.86) : Color.secondary.opacity(0.10),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.indigo : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(layer.name) layer, \(layer.conversations.count) conversations")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("conversation-layer-\(layer.id.uuidString)")
    }

    private func selectFirstLayerIfNeeded() {
        guard !layers.isEmpty,
              !layers.contains(where: { $0.id == selectedLayerID }) else { return }
        selectedLayerID = layers[0].id
    }
}
