import Foundation
import Observation
import TNCore
import TNModel
import TNNotebook

/// Which eraser the person last used. Kept across mode switches, so the
/// eraser button restores what it was rather than a fixed default.
package enum EraserMode: String, Sendable, Codable {
    case object, pixel
}

/// Which run of the bar's swatches: the theme choice it belongs to, and
/// whether it is the pen's or the highlighter's.
///
/// The choice, not the theme it resolves to, so following the system is
/// one run by day and after dark, and each preset picked by name is its own.
package struct SwatchKey: Hashable, Sendable, Codable {
    /// The pen's run is the pencil's and the text tool's too.
    package enum Run: String, Hashable, Sendable, Codable {
        case pen, highlighter
    }

    package let choice: ThemeChoice
    package let run: Run

    package init(_ choice: ThemeChoice, _ run: Run) {
        self.choice = choice
        self.run = run
    }
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
    /// One of the two places a saved record may be short of this build: a
    /// map without a kind is still a map, and `ToolPalette.init` gives the
    /// missing kind its built-in preset rather than resetting the rest.
    package var inks: [InkKind: InkPreset]
    package var eraserMode: EraserMode
    package var pixelEraserWidth: ToolWidth
    package var recentColors: [ToolColor]
    package var text: TextPreset
    /// Which Pencil gesture does what. A trigger absent from the map is off.
    package var gestures: GestureBindings
    /// Only the runs a person has changed. A key the map lacks is read as
    /// its seed, so a theme joining the table adds nothing here.
    package var swatches: [SwatchKey: [ToolColor]]

    package init(
        lastKind: ToolPalette.Kind,
        inks: [InkKind: InkPreset],
        eraserMode: EraserMode,
        pixelEraserWidth: ToolWidth,
        recentColors: [ToolColor],
        text: TextPreset,
        gestures: GestureBindings,
        swatches: [SwatchKey: [ToolColor]]
    ) {
        self.lastKind = lastKind
        self.inks = inks
        self.eraserMode = eraserMode
        self.pixelEraserWidth = pixelEraserWidth
        self.recentColors = recentColors
        self.text = text
        self.gestures = gestures
        self.swatches = swatches
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
        gestures: [.scribble: .erase],
        swatches: [:]
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
/// eraser mode, the colours they have drawn with, the bar's swatches, and
/// which kind of tool a new tab opens on.
///
/// One writer. Views read it and the view model calls its methods. Every
/// field holds the attributes of a tool, never a tool, so the slots cannot
/// disagree with their keys.
@MainActor @Observable package final class ToolPalette {
    /// Which kind of tool a new tab opens on, and what the bar's caps ask
    /// for. Lasso is not a member: a tab that opened on lasso is a tab you
    /// cannot write in. The tool itself is rebuilt from the slots by
    /// `currentTool`.
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
    /// The colours drawn with and the colours the tray closed on: most
    /// recent first, at most `recentLimit`, no duplicates.
    package var recentColors: [ToolColor] { record.recentColors }
    /// The style and alignment the text tool last typed with.
    package var text: TextPreset { record.text }
    /// Which Pencil gesture does what, for every ink kind at once. A
    /// trigger absent from the map is off. Nobody copies this: the editor
    /// binding asks for it on every stroke that lands.
    package var gestures: GestureBindings { record.gestures }

    /// Eight, the length of the colour tray's recents run (decided U3).
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
    package var currentTool: EditorTool { tool(for: lastKind) }

    /// The tool a kind restores, built from its slot.
    package func tool(for kind: Kind) -> EditorTool {
        switch kind {
        case .ink(let ink): tool(for: ink)
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

    /// The colour a session of the colour tray closed on, recorded as one
    /// drawn with is. Once per session, however many colours the wheel
    /// passed through on the way to it (decided U3, round two).
    package func picked(_ color: ToolColor) { used(color) }

    // MARK: The swatches

    /// The run the bar offers under `key`, in order: the one a person left
    /// there, or else its seed. Reading writes nothing.
    package func swatches(for key: SwatchKey, in theme: Theme) -> [ToolColor] {
        if let run = record.swatches[key] { return run }
        switch key.run {
        case .pen: return theme.palette.prefix(4).map { ToolColor(rgba: $0) }
        case .highlighter: return ToolColor.highlighterRow
        }
    }

    /// Replaces one swatch in the run `key` names and no other. The first
    /// replacement under a key writes the rest of its seed with it.
    package func replaceSwatch(at index: Int, with color: ToolColor, for key: SwatchKey, in theme: Theme) {
        var run = swatches(for: key, in: theme)
        TNPrecondition.require(run.indices.contains(index), "swatch \(index) of a run of \(run.count)")
        // A seed rewritten with its own colour is a run nobody changed, and
        // writing it would pin it against a retuned row.
        guard run[index] != color else { return }
        run[index] = color
        record.swatches[key] = run
    }

    /// Binds a gesture, or unbinds it when `effect` is nil.
    package func bind(_ trigger: GestureTrigger, to effect: GestureEffect?) {
        guard gestures[trigger] != effect else { return }
        record.gestures[trigger] = effect
    }
}
