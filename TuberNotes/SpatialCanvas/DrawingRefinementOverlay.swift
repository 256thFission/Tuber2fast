import PencilKit
import SwiftUI

struct DrawingRefinementOverlay: View {
    let drawing: PKDrawing
    let client: any DrawingRefinementClient
    let initialSelection: CGRect?

    @State private var isLassoActive = false
    @State private var lassoPoints: [CGPoint] = []
    @State private var selection: CGRect?
    @State private var refinedImage: UIImage?
    @State private var isRefining = false
    @State private var errorMessage: String?

    private let prompt = "Clean up this drawing while preserving its meaning and composition."

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let refinedImage, let selection {
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
                    selectionView(selection)
                }

                controls
            }
            .onAppear {
                guard selection == nil, let initialSelection else { return }
                selection = CGRect(
                    x: initialSelection.minX * proxy.size.width,
                    y: initialSelection.minY * proxy.size.height,
                    width: initialSelection.width * proxy.size.width,
                    height: initialSelection.height * proxy.size.height
                )
            }
        }
        .alert("Couldn’t refine drawing", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    isLassoActive.toggle()
                    if isLassoActive {
                        selection = nil
                        refinedImage = nil
                    }
                    lassoPoints = []
                } label: {
                    Label(isLassoActive ? "Drawing lasso…" : "AI Lasso", systemImage: "lasso.badge.sparkles")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .foregroundStyle(isLassoActive ? .white : .indigo)
                        .background(isLassoActive ? Color.indigo : Color.white.opacity(0.94), in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ai-lasso-button")
            }
            Spacer()
        }
        .padding(16)
    }

    private func selectionView(_ rect: CGRect) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.indigo.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.indigo, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                }

            Button {
                refine(rect)
            } label: {
                Group {
                    if isRefining {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Label(refinedImage == nil ? "Refine with AI" : "Refine again", systemImage: "sparkles")
                    }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(.indigo, in: Capsule())
            }
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
                refine(rect)
            } label: {
                Label("Refine with AI", systemImage: "sparkles")
            }
            .disabled(isRefining)

            if refinedImage != nil {
                Button(role: .destructive) {
                    refinedImage = nil
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
                selection = bounds
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

    private func refine(_ rect: CGRect) {
        guard !isRefining else { return }
        let scale = UIScreen.main.scale
        let image = drawing.image(from: rect, scale: scale)
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

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
