import Foundation
import Observation
import TNCore
import TNNotebook

/// Which eraser the person last used. Kept across mode switches, so the
/// eraser button restores what it was rather than a fixed default.
package enum EraserMode: String, Sendable, Codable {
    case object, pixel
}

/// The whole palette as one value, for the store.
///
/// One value, not five keys: a partial write can only ever lose the lot,
/// which the built-in default covers, rather than leave two fields
/// disagreeing about which tool is in hand. The decoder is the synthesized
/// one, so a record missing any key is unreadable whole and the palette
/// opens on `builtIn`.
package struct ToolPaletteRecord: Equatable, Sendable, Codable {
    package var lastKind: ToolPalette.Kind
    /// The one place a saved record may be short of this build: a map
    /// without a kind is still a map, and `ToolPalette.init` gives the
    /// missing kind its built-in preset rather than resetting the rest.
    package var inks: [InkKind: InkPreset]
    package var eraserMode: EraserMode
    package var pixelEraserWidth: ToolWidth
    package var recentColors: [ToolColor]
    package var text: TextPreset
    /// Which Pencil gesture does what. A trigger absent from the map is off.
    package var gestures: GestureBindings

    package init(
        lastKind: ToolPalette.Kind,
        inks: [InkKind: InkPreset],
        eraserMode: EraserMode,
        pixelEraserWidth: ToolWidth,
        recentColors: [ToolColor],
        text: TextPreset,
        gestures: GestureBindings
    ) {
        self.lastKind = lastKind
        self.inks = inks
        self.eraserMode = eraserMode
        self.pixelEraserWidth = pixelEraserWidth
        self.recentColors = recentColors
        self.text = text
        self.gestures = gestures
    }

    /// What a first launch opens on, and what an unreadable preference
    /// falls back to.
    package static let builtIn = ToolPaletteRecord(
        lastKind: .ink(.pen),
        inks: [
            .pen: InkPreset(color: .black, width: .medium),
            .pencil: InkPreset(color: .black, width: .medium),
            .highlighter: InkPreset(color: .yellow, width: .medium),
        ],
        eraserMode: .object,
        pixelEraserWidth: .medium,
        recentColors: [],
        text: .body,
        // Scribble ships bound: the point of a gesture is not visiting the
        // toolbar to switch it on.
        gestures: [.scribble: .erase]
    )
}

/// Persistence for the palette. `TNEditor` names it; the app conforms.
///
/// A protocol rather than the API itself, because `UserDefaults` inside a
/// module would widen what `TNEditor` is: the binding and the editor view
/// model. The one production conformer is the app's
/// `PreferenceDefaults<ToolPaletteRecord>`.
package protocol ToolPaletteStore: Sendable {
    func load() -> ToolPaletteRecord?
    func save(_ record: ToolPaletteRecord)
}

/// What the person keeps between notebooks: a preset per ink kind, an
/// eraser mode, the colours they have drawn with, and which kind of tool a
/// new tab opens on.
///
/// One writer. Views read it and the view model calls its methods. Every
/// field holds the attributes of a tool, never a tool, so the slots cannot
/// disagree with their keys.
@MainActor @Observable package final class ToolPalette {
    /// Which kind of tool a new tab opens on. Lasso is not a member: a tab
    /// that opened on lasso is a tab you cannot write in. The tool itself
    /// is rebuilt from the slots by `currentTool`.
    package enum Kind: Equatable, Sendable, Codable {
        case ink(InkKind)
        case eraser
        case text
    }

    /// Everything the palette keeps, written to the store whole each time
    /// it changes, so one change is one write.
    private(set) var record: ToolPaletteRecord {
        didSet { store.save(record) }
    }

    package var lastKind: Kind { record.lastKind }
    package var inks: [InkKind: InkPreset] { record.inks }
    package var eraserMode: EraserMode { record.eraserMode }
    package var pixelEraserWidth: ToolWidth { record.pixelEraserWidth }
    /// Simply the colours drawn with: most recent first, at most
    /// `recentLimit`, no duplicates. A colour becomes recent when a stroke
    /// lands in it, not when it is picked. Whoever draws a row of swatches
    /// out of this and the theme's own is the one responsible for not
    /// showing the same swatch twice.
    package var recentColors: [ToolColor] { record.recentColors }
    /// The style and alignment the text tool last typed with.
    package var text: TextPreset { record.text }
    /// Which Pencil gesture does what, for every ink kind at once. A
    /// trigger absent from the map is off. Nobody copies this: the editor
    /// binding asks for it on every stroke that lands.
    package var gestures: GestureBindings { record.gestures }

    /// Eight, the length of the colour tray's recents run (decided U3). The
    /// bar's four swatches take theirs from the front.
    package static let recentLimit = 8

    @ObservationIgnored private let store: any ToolPaletteStore

    package init(store: any ToolPaletteStore) {
        self.store = store
        var record = store.load() ?? .builtIn
        record.inks = ToolPaletteRecord.builtIn.inks.merging(record.inks) { _, saved in saved }
        self.record = record
    }

    // MARK: The tools it names

    /// The tool `lastKind` names, built from the slots.
    package var currentTool: EditorTool {
        switch lastKind {
        case .ink(let kind): tool(for: kind)
        case .eraser: eraserTool
        case .text: textTool
        }
    }

    package var textTool: EditorTool { .text(text.style, text.alignment) }

    package func tool(for kind: InkKind) -> EditorTool {
        guard let preset = inks[kind] else {
            TNPrecondition.fail("the palette has no slot for \(kind), which builtIn and init's merge guarantee")
        }
        return .ink(kind, preset)
    }

    package var eraserTool: EditorTool {
        switch eraserMode {
        case .object: .eraseObject
        case .pixel: .erasePixel(pixelEraserWidth)
        }
    }

    // MARK: What it is told

    package func remember(_ tool: EditorTool) {
        // Changed on a copy and assigned once: a tool is a slot and a kind,
        // and two assignments would be two writes.
        var next = record
        switch tool {
        case .ink(let kind, let preset):
            next.inks[kind] = preset
            next.lastKind = .ink(kind)
        case .eraseObject:
            next.eraserMode = .object
            next.lastKind = .eraser
        case .erasePixel(let width):
            next.eraserMode = .pixel
            next.pixelEraserWidth = width
            next.lastKind = .eraser
        case .text(let style, let alignment):
            // A colour typed with is never a recent; `used(_:)` is the ink
            // report's and no text report calls it.
            next.text = TextPreset(style: style, alignment: alignment)
            next.lastKind = .text
        case .lasso:
            // Lasso has nothing to remember and is not a `Kind`, so there
            // is nothing to write and no reason to touch the store.
            return
        }
        record = next
    }

    /// A colour a stroke landed in, whatever it is.
    ///
    /// The colours on offer belong to the theme, and the theme can change.
    /// A colour refused for sitting on this theme's row would be missing
    /// from the next theme's, and a preference would be rewritten by a
    /// choice of chrome, so nothing is refused here.
    package func used(_ color: ToolColor) {
        // Called once per stroke, from the ink report. Drawing on and on in
        // one colour must not write the preference on every stroke, which
        // is work on the report path for no change at all.
        guard recentColors.first != color else { return }
        record.recentColors = Array(([color] + recentColors.filter { $0 != color }).prefix(Self.recentLimit))
    }

    /// Binds a gesture, or unbinds it when `effect` is nil.
    package func bind(_ trigger: GestureTrigger, to effect: GestureEffect?) {
        guard gestures[trigger] != effect else { return }
        record.gestures[trigger] = effect
    }
}
