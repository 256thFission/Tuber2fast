import SwiftUI
import TNEditor
import TNLibrary
import TNModel

/// A name, a first page, and the paper it is drawn with. The sheet chooses;
/// the library creates, and names a blank field.
struct NewNotebookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macaron) private var theme

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
        MacaronPanel(title: "New notebook", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 10) {
                MacaronHeading(text: "Name")
                MacaronField(prompt: "New notebook", text: $name)
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
            MacaronButton(title: "Create", fill: theme.accent, isEnabled: geometry != nil) {
                if let geometry { create(name, geometry, paper) }
                dismiss()
            }
        }
    }

    private var geometry: PageGeometry? { size.geometry(orientation) }
}

/// A name, and nothing else. A panel rather than an alert, so both
/// creations are the same gesture.
struct NewFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macaron) private var theme

    let create: (String) -> Void

    @State private var name = ""

    var body: some View {
        MacaronPanel(title: "New folder", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 10) {
                MacaronHeading(text: "Name")
                MacaronField(prompt: "New folder", text: $name)
            }

            MacaronButton(title: "Create", fill: theme.accent) {
                create(name)
                dismiss()
            }
        }
    }
}
