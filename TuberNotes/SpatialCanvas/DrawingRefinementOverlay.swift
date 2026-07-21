import PencilKit
import SwiftUI
import UIKit

struct DrawingRefinementOverlay: View {
    let drawing: PKDrawing
    let client: any DrawingRefinementClient
    let initialSelection: CGRect?
    let pageSize: CGSize
    @Binding var isLassoActive: Bool
    let onApply: (Data, CGRect, [CGPoint]) -> Void
    let onClose: () -> Void

    @State private var lassoPoints: [CGPoint] = []
    /// Page-normalized selection. Keeping this out of transient view pixels
    /// lets it follow the paper continuously through zoom and pan.
    @State private var selection: CGRect?
    /// Page-normalized closed lasso polygon backing `selection`. Empty when the
    /// selection came from a rect (initial selection) or an unclosed lasso.
    @State private var selectionPath: [CGPoint] = []
    @State private var refinedImage: UIImage?
    @State private var refinedImageData: Data?
    @State private var isRefining = false
    @State private var errorMessage: String?

    private let prompt = "Clean up this drawing while preserving its meaning and composition."

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let refinedImage, let selection {
                    let selection = denormalized(selection, in: proxy.size)
                    Image(uiImage: refinedImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .accessibilityIdentifier("refined-drawing")
                }

                if isLassoActive {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(lassoGesture(in: proxy.size))

                    lassoPath
                        .stroke(.indigo, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 5]))
                        .shadow(color: .white, radius: 1)
                        .allowsHitTesting(false)
                }

                if let selection {
                    selectionView(denormalized(selection, in: proxy.size), in: proxy.size)
                }
            }
            .onAppear {
                guard selection == nil, let initialSelection else { return }
                selection = initialSelection
            }
            .onChange(of: isLassoActive) { _, isActive in
                lassoPoints = []
                guard isActive else { return }
                selection = nil
                selectionPath = []
                refinedImage = nil
                refinedImageData = nil
            }
        }
        .alert("Couldn’t refine drawing", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func selectionView(_ rect: CGRect, in canvasSize: CGSize) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.indigo.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.indigo, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                }

            HStack(spacing: 8) {
                if let refinedImageData {
                    Button {
                        onApply(refinedImageData, normalized(rect, in: canvasSize), selectionPath)
                        onClose()
                    } label: {
                        Label("Apply", systemImage: "checkmark")
                    }
                    .accessibilityIdentifier("apply-refinement-button")
                }

                Button {
                    refine(rect, in: canvasSize)
                } label: {
                    Group {
                        if isRefining {
                            ProgressView().tint(.white)
                        } else {
                            Label(refinedImage == nil ? "Refine with AI" : "Refine again", systemImage: "sparkles")
                        }
                    }
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.indigo, in: Capsule())
            .buttonStyle(.plain)
            .disabled(isRefining)
            .padding(8)
            .accessibilityIdentifier("refine-with-ai-button")
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                refine(rect, in: canvasSize)
            } label: {
                Label("Refine with AI", systemImage: "sparkles")
            }
            .disabled(isRefining)

            if refinedImage != nil {
                Button(role: .destructive) {
                    refinedImage = nil
                    refinedImageData = nil
                } label: {
                    Label("Undo refinement", systemImage: "arrow.uturn.backward")
                }
            }
        } preview: {
            Text("Hold or right-click the selection")
                .padding()
        }
        .accessibilityLabel("Selected drawing region")
        .accessibilityHint("Long press or right-click for refinement actions")
        .accessibilityIdentifier("drawing-refinement-selection")
    }

    private var lassoPath: Path {
        var path = Path()
        guard let first = lassoPoints.first else { return path }
        path.move(to: first)
        lassoPoints.dropFirst().forEach { path.addLine(to: $0) }
        return path
    }

    private func lassoGesture(in canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                lassoPoints.append(value.location)
            }
            .onEnded { _ in
                guard let bounds = lassoBounds(in: canvasSize) else {
                    lassoPoints = []
                    return
                }
                selection = normalized(bounds, in: canvasSize)
                selectionPath = LassoGeometry.closedPath(
                    from: lassoPoints.map { normalizedPoint($0, in: canvasSize) }
                ) ?? []
                lassoPoints = []
                isLassoActive = false
            }
    }

    private func lassoBounds(in canvasSize: CGSize) -> CGRect? {
        guard let first = lassoPoints.first else { return nil }
        let raw = lassoPoints.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
        let padded = raw.insetBy(dx: -12, dy: -12).intersection(CGRect(origin: .zero, size: canvasSize))
        guard padded.width >= 44, padded.height >= 44 else { return nil }
        return padded
    }

    private func refine(_ rect: CGRect, in canvasSize: CGSize) {
        guard !isRefining else { return }
        let normalizedRect = normalized(rect, in: canvasSize)
        let sourceRect = CGRect(
            x: normalizedRect.minX * pageSize.width,
            y: normalizedRect.minY * pageSize.height,
            width: normalizedRect.width * pageSize.width,
            height: normalizedRect.height * pageSize.height
        )
        let scale = UIScreen.main.scale
        let inkImage = drawing.image(from: sourceRect, scale: scale)
        let renderer = UIGraphicsImageRenderer(size: inkImage.size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: inkImage.size))
            inkImage.draw(in: CGRect(origin: .zero, size: inkImage.size))
        }
        guard let imageData = image.pngData() else {
            errorMessage = DrawingRefinementError.invalidResponse.localizedDescription
            return
        }

        isRefining = true
        Task {
            do {
                let result = try await client.refine(
                    DrawingRefinementRequest(imageData: imageData, prompt: prompt)
                )
                guard let image = UIImage(data: result.imageData) else {
                    throw DrawingRefinementError.invalidResponse
                }
                await MainActor.run {
                    refinedImage = image
                    refinedImageData = result.imageData
                    isRefining = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRefining = false
                }
            }
        }
    }

    private func normalizedPoint(_ point: CGPoint, in canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: point.x / max(canvasSize.width, 1),
            y: point.y / max(canvasSize.height, 1)
        )
    }

    private func normalized(_ rect: CGRect, in canvasSize: CGSize) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGRect(
            x: rect.minX / max(canvasSize.width, 1),
            y: rect.minY / max(canvasSize.height, 1),
            width: rect.width / max(canvasSize.width, 1),
            height: rect.height / max(canvasSize.height, 1)
        )
    }

    private func denormalized(_ rect: CGRect, in canvasSize: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * canvasSize.width,
            y: rect.minY * canvasSize.height,
            width: rect.width * canvasSize.width,
            height: rect.height * canvasSize.height
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
