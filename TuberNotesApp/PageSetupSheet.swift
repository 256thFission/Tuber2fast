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
        case .none: "None"
        case .blank: "Blank"
        case .lined: "Lined"
        case .grid: "Grid"
        case .dotted: "Dotted"
        }
    }

    /// What creating without the sheet would make. Portrait is left unsaid,
    /// as the sizes are stated portrait; landscape would otherwise be a
    /// caption that disagrees with the page it names.
    static func setup(_ setup: NotebookSetup?) -> String {
        let matched = PageSize.matching(setup?.geometry ?? .letter)
        let turned = matched.orientation == .landscape ? " \(orientation(.landscape))" : ""
        return "\(size(matched.size))\(turned), \(paper(setup?.paper ?? .blank))"
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
        Section("Size") {
            Picker("Size", selection: choice) {
                ForEach(PageSize.named, id: \.self) { named in
                    Text(PageNames.size(named)).tag(SizeChoice.named(named))
                }
                Text(PageNames.customSize).tag(SizeChoice.custom)
            }
            if isCustom {
                LabeledContent("Width") {
                    TextField("Width", text: $customWidth)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .onChange(of: customWidth) { _, _ in pushCustom() }
                }
                LabeledContent("Height") {
                    TextField("Height", text: $customHeight)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .onChange(of: customHeight) { _, _ in pushCustom() }
                }
                Text("Each edge is \(Self.bounds) points.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Orientation") {
            Picker("Orientation", selection: $orientation) {
                ForEach(PageOrientation.allCases, id: \.self) { orientation in
                    Text(PageNames.orientation(orientation)).tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .disabled(orientationReason != nil)
            if let orientationReason {
                Text(orientationReason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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

    let create: (String, PageGeometry, DrawnPaper) -> Void

    @State private var name = ""
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
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("New notebook", text: $name)
                }
                PageSetupControls(size: $size, orientation: $orientation)
                Section("Paper") {
                    Picker("Paper", selection: $paper) {
                        ForEach(DrawnPaper.allCases, id: \.self) { paper in
                            Text(PageNames.paper(paper)).tag(paper)
                        }
                    }
                }
            }
            .navigationTitle("New notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if let geometry { create(LibraryView.nameOrDefault(name, "New notebook"), geometry, paper) }
                        dismiss()
                    }
                    // An out-of-bounds custom size is refused here, before
                    // anything is created.
                    .disabled(geometry == nil)
                }
            }
        }
    }

    private var geometry: PageGeometry? { size.geometry(orientation) }
}

/// A name, and nothing else. The same shape as `NewNotebookSheet` rather
/// than an alert, so both creations are the same gesture.
struct NewFolderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let create: (String) -> Void

    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("New folder", text: $name)
                }
            }
            .navigationTitle("New folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        create(LibraryView.nameOrDefault(name, "New folder"))
                        dismiss()
                    }
                }
            }
        }
    }
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
        NavigationStack {
            Form {
                PageSetupControls(
                    size: $size,
                    orientation: $orientation,
                    orientationDisabledBecause: takesAssetAspect
                        ? "Paper from an image takes that image's aspect." : nil
                )
                Section("Paper") {
                    Picker("Paper", selection: $choice) {
                        Text("Same as this page").tag(NewPagePaperChoice.sameAsThisPage)
                        ForEach(DrawnPaper.allCases, id: \.self) { paper in
                            Text(PageNames.paper(paper)).tag(NewPagePaperChoice.drawn(paper))
                        }
                        Text("Photo").tag(NewPagePaperChoice.photo)
                        Text("This page, flattened").tag(NewPagePaperChoice.flattened)
                        ForEach(editor.pagesWithAssetPaper, id: \.page) { source in
                            Text("Paper from page \(source.number)")
                                .tag(NewPagePaperChoice.from(source.page))
                        }
                    }
                }
            }
            .navigationTitle("Add page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        add(choice, size, orientation)
                        dismiss()
                    }
                    .disabled(size.geometry(orientation) == nil)
                }
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
