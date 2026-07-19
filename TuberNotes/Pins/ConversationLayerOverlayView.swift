import SwiftUI

struct ConversationLayerOverlayView: View {
    @Binding var layers: [ConversationLayer]
    @Binding var selectedLayerID: UUID?

    private var selectedLayer: ConversationLayer? {
        visibleLayers.first { $0.id == selectedLayerID } ?? visibleLayers.first
    }

    private var visibleLayers: [ConversationLayer] {
        layers.filter(\.isVisible)
    }

    var body: some View {
        ZStack {
            PinOverlayView(pins: selectedLayer?.conversations ?? [])

            VStack {
                ConversationLayerPickerView(
                    layers: $layers,
                    selectedLayerID: $selectedLayerID
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

                Spacer()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-layer-overlay")
    }
}

struct ConversationLayerPickerView: View {
    @Binding var layers: [ConversationLayer]
    @Binding var selectedLayerID: UUID?

    private var selectedLayer: ConversationLayer? {
        visibleLayers.first { $0.id == selectedLayerID } ?? visibleLayers.first
    }

    private var visibleLayers: [ConversationLayer] {
        layers.filter(\.isVisible)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.3.layers.3d")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)

            Text("Agentic layers")
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
        .onAppear {
            selectFirstLayerIfNeeded()
        }
        .onChange(of: layers) { _, _ in
            selectFirstLayerIfNeeded()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentic-layer-picker")
    }

    private func layerButton(_ layer: ConversationLayer) -> some View {
        let isSelected = layer.id == selectedLayer?.id

        return HStack(spacing: 2) {
            Button {
                guard layer.isVisible else { return }
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
                .padding(.leading, 11)
                .padding(.trailing, 5)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .opacity(layer.isVisible ? 1 : 0.48)
            }
            .buttonStyle(.plain)
            .disabled(!layer.isVisible)
            .accessibilityLabel("\(layer.name) layer, \(layer.conversations.count) conversations")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button {
                toggleVisibility(of: layer.id)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.caption.weight(.semibold))
                    .frame(width: 30, height: 34)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(layer.isVisible ? "Hide" : "Show") \(layer.name) layer")
            .accessibilityIdentifier("conversation-layer-visibility-\(layer.id.uuidString)")
        }
        .padding(.trailing, 4)
        .background(isSelected ? Color.indigo : Color.clear, in: Capsule())
        .accessibilityIdentifier("conversation-layer-\(layer.id.uuidString)")
    }

    private func selectFirstLayerIfNeeded() {
        guard !visibleLayers.contains(where: { $0.id == selectedLayerID }) else { return }
        selectedLayerID = visibleLayers.first?.id
    }

    private func toggleVisibility(of id: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy(duration: 0.22)) {
            layers[index].isVisible.toggle()
            selectFirstLayerIfNeeded()
        }
    }
}
