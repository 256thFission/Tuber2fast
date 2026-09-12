import SwiftUI
import TNLibrary

/// What a colour and a symbol are called. The durable names are English
/// already, but a raw value is not a label: `FolderSymbol.school` is stored
/// as `graduationcap.fill`, which is not a word anyone wants read out. This
/// is the one home for both lists, as `PageNames` is for sizes and paper.
enum FolderStyleNames {
    static func color(_ color: FolderColor) -> String {
        switch color {
        case .neutral: "Default"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        }
    }

    static func symbol(_ symbol: FolderSymbol) -> String {
        switch symbol {
        case .folder: "Folder"
        case .star: "Star"
        case .heart: "Heart"
        case .book: "Book"
        case .briefcase: "Briefcase"
        case .school: "School"
        }
    }
}

/// A folder's colour and symbol: a row of swatches over a grid of glyphs,
/// with the folder as it will look above them. The sheet chooses; the store
/// writes.
struct FolderStyleSheet: View {
    @Environment(\.dismiss) private var dismiss

    let name: String
    let apply: (FolderDecoration) -> Void

    @State private var color: FolderColor
    @State private var symbol: FolderSymbol

    /// Opens on what the folder already carries, which for a folder whose
    /// sidecar could not be read is the plain pair it is drawn as.
    init(name: String, decoration: FolderDecoration?, apply: @escaping (FolderDecoration) -> Void) {
        self.name = name
        self.apply = apply
        let opened = decoration ?? .plain
        _color = State(initialValue: opened.color)
        _symbol = State(initialValue: opened.symbol)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        LibraryFolderGlyph(decoration: chosen)
                            .frame(width: 92, height: 92)
                        Spacer()
                    }
                }
                Section("Colour") {
                    swatches
                }
                Section("Symbol") {
                    symbols
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        apply(chosen)
                        dismiss()
                    }
                }
            }
        }
    }

    private var chosen: FolderDecoration { FolderDecoration(color: color, symbol: symbol) }

    private var swatches: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 12)], spacing: 12) {
            ForEach(FolderColor.allCases, id: \.self) { candidate in
                Button {
                    color = candidate
                } label: {
                    Circle()
                        .fill(LibraryStyle.color(of: candidate))
                        .frame(width: 34, height: 34)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: 2)
                                .opacity(candidate == color ? 1 : 0)
                                .padding(-4)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(FolderStyleNames.color(candidate))
            }
        }
        .padding(.vertical, 6)
    }

    private var symbols: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 12)], spacing: 12) {
            ForEach(FolderSymbol.allCases, id: \.self) { candidate in
                Button {
                    symbol = candidate
                } label: {
                    Image(systemName: candidate.rawValue)
                        .font(.title2)
                        .foregroundStyle(LibraryStyle.color(of: color))
                        .frame(width: 52, height: 44)
                        .background(
                            candidate == symbol ? Color.accentColor.opacity(0.18) : .clear,
                            in: .rect(cornerRadius: 10)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(FolderStyleNames.symbol(candidate))
            }
        }
        .padding(.vertical, 6)
    }
}
