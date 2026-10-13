import SwiftUI
import TNEditor
import TNLibrary
import TNModel

/// What the catalogue is called. `PageSize` and `DrawnPaper` carry no names
/// on purpose: a display name is the app's, and this is its one home.
enum PageNames {
    static func size(_ size: PageSize) -> String {
        switch size {
        case .letter: "US Letter"
        case .a4: "A4"
        case .a5: "A5"
        case .iPadPro13: "iPad Pro 13\""
        case .square: "Square"
        case .custom: customSize
        }
    }

    /// Its own constant because the picker offers Custom before there are two
    /// numbers to make a `PageSize.custom` out of.
    static let customSize = "Custom"

    static func orientation(_ orientation: PageOrientation) -> String {
        switch orientation {
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        }
    }

    static func paper(_ paper: DrawnPaper) -> String {
        switch paper {
        case .blank: "Blank"
        case .lined: "Lined"
        case .grid: "Grid"
        case .dotted: "Dotted"
        }
    }
}

/// One paper, shown as the page it makes: white paper, radius 10, the 3pt
/// derived outline, and its rules drawn small in the token that owns rule
/// lines. Held is sunk, which is the whole of the chosen state.
private struct PaperCap: View {
    let paper: DrawnPaper
    let isHeld: Bool
    var isEnabled = true
    let select: () -> Void

    @Environment(\.macaron) private var theme

    var body: some View {
        VStack(spacing: Macaron.rowGap) {
            Keycap(
                fill: theme.paper,
                size: CGSize(width: Macaron.shell, height: Macaron.shell),
                radius: Macaron.chipRadius,
                isHeld: isHeld,
                isEnabled: isEnabled,
                action: select
            ) {
                marks
            }
            Text(PageNames.paper(paper))
                .font(Macaron.body(11))
                .foregroundStyle(theme.outline(of: theme.chrome).color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PageNames.paper(paper))
        .accessibilityAddTraits(isHeld ? [.isButton, .isSelected] : .isButton)
    }

    private var marks: some View {
        let rule = theme.secondary.color
        return Canvas { context, size in
            let step = size.width / 4
            var path = Path()
            switch paper {
            case .blank:
                break
            case .lined:
                for row in 1..<4 {
                    path.move(to: CGPoint(x: 0, y: step * CGFloat(row)))
                    path.addLine(to: CGPoint(x: size.width, y: step * CGFloat(row)))
                }
            case .grid:
                for index in 1..<4 {
                    path.move(to: CGPoint(x: 0, y: step * CGFloat(index)))
                    path.addLine(to: CGPoint(x: size.width, y: step * CGFloat(index)))
                    path.move(to: CGPoint(x: step * CGFloat(index), y: 0))
                    path.addLine(to: CGPoint(x: step * CGFloat(index), y: size.height))
                }
            case .dotted:
                for row in 1..<4 {
                    for column in 1..<4 {
                        path.addEllipse(
                            in: CGRect(x: step * CGFloat(column) - 1, y: step * CGFloat(row) - 1, width: 2, height: 2)
                        )
                    }
                }
            }
            if paper == .dotted {
                context.fill(path, with: .color(rule))
            } else {
                context.stroke(path, with: .color(rule), lineWidth: 1.5)
            }
        }
        .frame(width: Macaron.chip, height: Macaron.chip)
    }
}

/// The size and orientation rows both creation sheets show. The size is the
/// caller's state; this only edits it.
struct PageSetupControls: View {
    @Binding var size: PageSize
    @Binding var orientation: PageOrientation

    /// Why the orientation the user picks would not be the one they get, or
    /// nil when it is theirs to choose. A custom size states its own reason;
    /// this is for the caller's, such as asset paper taking the asset's
    /// aspect.
    let orientationDisabledBecause: String?

    /// The text as typed, not a number: a half-typed edge is not a size, and
    /// parsing it back out of `size` would fight the person typing.
    @State private var customWidth: String
    @State private var customHeight: String

    @Environment(\.macaron) private var theme

    init(
        size: Binding<PageSize>,
        orientation: Binding<PageOrientation>,
        orientationDisabledBecause: String? = nil
    ) {
        _size = size
        _orientation = orientation
        self.orientationDisabledBecause = orientationDisabledBecause
        let opened: PageGeometry
        if case .custom(let width, let height) = size.wrappedValue {
            opened = PageGeometry(width: width, height: height)
        } else {
            opened = .letter
        }
        _customWidth = State(initialValue: Self.typed(opened.width))
        _customHeight = State(initialValue: Self.typed(opened.height))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                MacaronHeading(text: "Size")
                MacaronRun {
                    ForEach(PageSize.named, id: \.self) { named in
                        MacaronButton(
                            title: PageNames.size(named),
                            isHeld: choice.wrappedValue == .named(named)
                        ) {
                            choice.wrappedValue = .named(named)
                        }
                    }
                    MacaronButton(title: PageNames.customSize, isHeld: isCustom) {
                        choice.wrappedValue = .custom
                    }
                }
                if isCustom {
                    HStack(spacing: Macaron.columnGap) {
                        edge("Width", text: $customWidth)
                        edge("Height", text: $customHeight)
                    }
                    Text("Each edge is \(Self.bounds) points.")
                        .font(Macaron.body(11))
                        .foregroundStyle(theme.outline(of: theme.chrome).color)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                MacaronHeading(text: "Orientation")
                MacaronRun {
                    ForEach(PageOrientation.allCases, id: \.self) { candidate in
                        MacaronButton(
                            title: PageNames.orientation(candidate),
                            isHeld: orientation == candidate,
                            isEnabled: orientationReason == nil
                        ) {
                            orientation = candidate
                        }
                    }
                }
                if let orientationReason {
                    MacaronNote(text: orientationReason)
                }
            }
        }
    }

    private func edge(_ name: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MacaronHeading(text: name)
            MacaronField(prompt: name, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .onChange(of: text.wrappedValue) { _, _ in pushCustom() }
                .frame(width: 120)
        }
    }

    /// What the picker selects. `PageSize.custom` carries the two numbers and
    /// so changes with every keystroke; a selection has to stand still.
    private enum SizeChoice: Hashable {
        case named(PageSize)
        case custom
    }

    private var isCustom: Bool {
        if case .custom = size { return true }
        return false
    }

    private var choice: Binding<SizeChoice> {
        Binding(
            get: { isCustom ? .custom : .named(size) },
            set: { selection in
                switch selection {
                case .named(let named): size = named
                case .custom: pushCustom()
                }
            }
        )
    }

    /// Text that is not a number becomes `.nan`, which fails `PageBounds` and
    /// so is refused, rather than defaulting to a size nobody typed.
    private func pushCustom() {
        size = .custom(width: Double(customWidth) ?? .nan, height: Double(customHeight) ?? .nan)
    }

    private var orientationReason: String? {
        if isCustom { return "A custom size is taken exactly as typed." }
        return orientationDisabledBecause
    }

    /// `%g` rather than interpolation: `minEdge` is derived and prints its
    /// binary tail as `137.60000000000002`.
    private static let bounds = String(format: "%g to %g", PageBounds.minEdge, PageBounds.maxEdge)

    private static func typed(_ edge: Double) -> String { String(format: "%g", edge) }
}

/// A name, a first page, and the paper it is drawn with. The sheet chooses;
/// the library creates.
struct NewNotebookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macaron) private var theme

    let create: (String, PageGeometry, DrawnPaper) -> Void

    @State private var name = "New notebook"
    @State private var size: PageSize
    @State private var orientation: PageOrientation
    @State private var paper: DrawnPaper

    /// Opens on the last notebook made here, or on Letter, portrait, blank
    /// the first time. The size is stored as a geometry, so the catalogue
    /// name is recovered from the two numbers rather than kept twice.
    init(opensOn setup: NotebookSetup?, create: @escaping (String, PageGeometry, DrawnPaper) -> Void) {
        self.create = create
        let opened = setup.map { PageSize.matching($0.geometry) } ?? (size: .letter, orientation: .portrait)
        _size = State(initialValue: opened.size)
        _orientation = State(initialValue: opened.orientation)
        _paper = State(initialValue: setup?.paper ?? .blank)
    }

    var body: some View {
        MacaronPanel(title: "New notebook", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 10) {
                MacaronHeading(text: "Name")
                MacaronField(prompt: "Name", text: $name)
            }

            PageSetupControls(size: $size, orientation: $orientation)

            VStack(alignment: .leading, spacing: 10) {
                MacaronHeading(text: "Paper")
                HStack(alignment: .top, spacing: Macaron.columnGap) {
                    ForEach(DrawnPaper.allCases, id: \.self) { candidate in
                        PaperCap(paper: candidate, isHeld: paper == candidate) { paper = candidate }
                    }
                }
            }

            // An out-of-bounds custom size is refused here, before anything
            // is created.
            MacaronButton(
                title: "Create",
                fill: theme.accent,
                isEnabled: !name.isEmpty && geometry != nil
            ) {
                if let geometry { create(name, geometry, paper) }
                dismiss()
            }
        }
    }

    private var geometry: PageGeometry? { size.geometry(orientation) }
}

/// Where a new page's paper comes from. One choice rather than a paper, a
/// flag for the photo picker, and a page to borrow from, which could
/// disagree with each other.
enum NewPagePaperChoice: Hashable {
    case sameAsThisPage
    case drawn(DrawnPaper)
    case photo
    case from(PageID)
    /// The current page, rendered to one picture. No payload: the source is
    /// always the page the reader is on, which the editor already knows.
    case flattened
}

/// Size, orientation, and paper for a page after the current one. The sheet
/// chooses; `EditorView` routes the choice to the intention that serves it.
struct AddPageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macaron) private var theme

    let editor: EditorViewModel
    let add: (NewPagePaperChoice, PageSize, PageOrientation) -> Void

    @State private var choice = NewPagePaperChoice.sameAsThisPage
    @State private var size: PageSize
    @State private var orientation: PageOrientation

    /// The sheet opens on the current page's size, which is what the page
    /// would have had if the toolbar had appended one without asking.
    @MainActor init(editor: EditorViewModel, add: @escaping (NewPagePaperChoice, PageSize, PageOrientation) -> Void) {
        self.editor = editor
        self.add = add
        let opened = editor.currentPageSize
        _size = State(initialValue: opened.size)
        _orientation = State(initialValue: opened.orientation)
    }

    var body: some View {
        MacaronPanel(title: "Add page", onClose: { dismiss() }) {
            PageSetupControls(
                size: $size,
                orientation: $orientation,
                orientationDisabledBecause: takesAssetAspect
                    ? "Paper from an image takes that image's aspect." : nil
            )

            VStack(alignment: .leading, spacing: 10) {
                MacaronHeading(text: "Paper")
                // The papers that are drawn show themselves; the ones that
                // come from somewhere else can only say where.
                HStack(alignment: .top, spacing: Macaron.columnGap) {
                    ForEach(DrawnPaper.allCases, id: \.self) { candidate in
                        PaperCap(paper: candidate, isHeld: choice == .drawn(candidate)) {
                            choice = .drawn(candidate)
                        }
                    }
                }
                MacaronRun {
                    MacaronButton(title: "Same as this page", isHeld: choice == .sameAsThisPage) {
                        choice = .sameAsThisPage
                    }
                    MacaronButton(title: "Photo", isHeld: choice == .photo) { choice = .photo }
                    MacaronButton(title: "This page, flattened", isHeld: choice == .flattened) {
                        choice = .flattened
                    }
                    ForEach(editor.pagesWithAssetPaper, id: \.page) { source in
                        MacaronButton(
                            title: "Paper from page \(source.number)",
                            isHeld: choice == .from(source.page)
                        ) {
                            choice = .from(source.page)
                        }
                    }
                }
            }

            MacaronButton(title: "Add", fill: theme.accent, isEnabled: size.geometry(orientation) != nil) {
                add(choice, size, orientation)
                dismiss()
            }
        }
    }

    private var takesAssetAspect: Bool {
        switch choice {
        case .photo, .from, .flattened: true
        case .sameAsThisPage, .drawn: false
        }
    }
}

/// The current page's paper, changed in place. A drawn paper applies at
/// once and closes the panel. A photo is picked after the panel has gone,
/// so the caller is told and opens the picker itself. A PDF page or a photo
/// keeps its paper, so on one every choice is shown and none is offered.
struct PagePaperSheet: View {
    @Environment(\.dismiss) private var dismiss

    let editor: EditorViewModel
    let pickPhoto: () -> Void

    var body: some View {
        let current = editor.currentPaper
        let keepsPaper = current?.isAsset == true
        MacaronPanel(title: "This page's paper", onClose: { dismiss() }) {
            HStack(alignment: .top, spacing: Macaron.columnGap) {
                ForEach(DrawnPaper.allCases, id: \.self) { candidate in
                    PaperCap(paper: candidate, isHeld: current == .drawn(candidate), isEnabled: !keepsPaper) {
                        Task { await editor.setPaper(candidate) }
                        dismiss()
                    }
                }
            }
            MacaronButton(title: "Photo", isEnabled: !keepsPaper) {
                pickPhoto()
                dismiss()
            }
            if keepsPaper {
                MacaronNote(text: "This page is a PDF page or a photo, so it keeps its paper: a change of paper can't be undone.")
            }
        }
    }
}
