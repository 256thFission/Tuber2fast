import Foundation
import Testing
@testable import TNEditor
@testable import TNModel
@testable import TNNotebook

/// A store that keeps the record in memory.
///
/// The production conformer is the app's, over `UserDefaults`. Nothing here
/// touches it: a test that wrote a real preference would leave the machine
/// it ran on holding state the next run reads back.
final class MemoryPaletteStore: ToolPaletteStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: ToolPaletteRecord?
    private var saveCount = 0
    /// Set to fail every load, which is what an unreadable preference looks
    /// like from inside the palette.
    private var isUnreadable = false

    init(_ record: ToolPaletteRecord? = nil) { self.record = record }

    func load() -> ToolPaletteRecord? {
        lock.withLock { isUnreadable ? nil : record }
    }

    func save(_ record: ToolPaletteRecord) {
        lock.withLock {
            self.record = record
            saveCount += 1
        }
    }

    var stored: ToolPaletteRecord? { lock.withLock { record } }
    /// How many times the palette has written, which is how a test says
    /// that a report changing nothing touched nothing.
    var saves: Int { lock.withLock { saveCount } }

    func makeUnreadable() { lock.withLock { isUnreadable = true } }
}

@Suite("Tool palette")
@MainActor
struct ToolPaletteTests {
    private func swatch(_ red: UInt8) -> ToolColor {
        ToolColor(rgba: RGBA8(red: red, green: 0x44, blue: 0x55, alpha: 0xFF))
    }

    // MARK: Opening

    @Test("An empty store opens on the built-in default")
    func anEmptyStoreIsTheBuiltInDefault() {
        let palette = ToolPalette(store: MemoryPaletteStore())
        #expect(palette.lastKind == .ink(.pen))
        #expect(palette.currentTool == .ink(.pen, InkPreset(color: .black, width: .medium)))
        #expect(palette.inks[.highlighter] == InkPreset(color: .yellow, width: .medium))
        #expect(palette.eraserMode == .object)
        #expect(palette.pixelEraserWidth == .medium)
        #expect(palette.recentColors.isEmpty)
    }

    @Test("A record the store cannot read is the built-in default")
    func anUnreadableRecordIsTheBuiltInDefault() {
        let store = MemoryPaletteStore()
        let first = ToolPalette(store: store)
        first.remember(.ink(.pencil, InkPreset(color: swatch(0xC4), width: .thick)))
        store.makeUnreadable()

        let second = ToolPalette(store: store)
        #expect(second.lastKind == .ink(.pen))
        #expect(second.currentTool == .ink(.pen, InkPreset(color: .black, width: .medium)))
        #expect(second.inks[.pencil] == InkPreset(color: .black, width: .medium))
    }

    @Test("A record missing a kind is the built-in default, not a patched record")
    func anIncompleteRecordIsTheBuiltInDefault() {
        // A preference written before a kind existed. Filling the hole in
        // place would leave the rest of a record nobody can vouch for; the
        // whole of it goes instead.
        let partial = ToolPaletteRecord(
            lastKind: .ink(.pen),
            inks: [.pen: InkPreset(color: swatch(0xC4), width: .thick)],
            eraserMode: .pixel,
            pixelEraserWidth: .thin,
            recentColors: [],
            text: .body,
            gestures: [:]
        )
        #expect(!partial.isComplete)
        let palette = ToolPalette(store: MemoryPaletteStore(partial))
        #expect(palette.currentTool == .ink(.pen, InkPreset(color: .black, width: .medium)))
        #expect(palette.eraserMode == .object)
    }

    @Test("A second palette over one store opens on everything the first left")
    func aSecondPaletteRestoresTheFirst() {
        let store = MemoryPaletteStore()
        let first = ToolPalette(store: store)
        first.remember(.ink(.highlighter, InkPreset(color: swatch(0x7A), width: .thin)))
        first.remember(.erasePixel(.thick))
        first.used(swatch(0x11))
        first.remember(.ink(.pencil, InkPreset(color: swatch(0xE0), width: .thick)))

        let second = ToolPalette(store: store)
        #expect(second.lastKind == .ink(.pencil))
        #expect(second.currentTool == .ink(.pencil, InkPreset(color: swatch(0xE0), width: .thick)))
        #expect(second.inks[.highlighter] == InkPreset(color: swatch(0x7A), width: .thin))
        #expect(second.eraserMode == .pixel)
        #expect(second.pixelEraserWidth == .thick)
        #expect(second.recentColors == [swatch(0x11)])
        #expect(second.eraserTool == .erasePixel(.thick))
    }

    // MARK: remember

    @Test("Remembering a pen writes the pen slot and nothing else")
    func rememberingAPenWritesOnlyThePenSlot() {
        let palette = ToolPalette(store: MemoryPaletteStore())
        let before = palette.inks

        palette.remember(.ink(.pen, InkPreset(color: swatch(0x1A), width: .thick)))

        #expect(palette.inks[.pen] == InkPreset(color: swatch(0x1A), width: .thick))
        #expect(palette.inks[.pencil] == before[.pencil])
        #expect(palette.inks[.highlighter] == before[.highlighter])
        #expect(palette.lastKind == .ink(.pen))
    }

    @Test("Remembering an eraser records the mode, and the pixel width survives the object eraser")
    func rememberingAnEraserKeepsThePixelWidth() {
        let palette = ToolPalette(store: MemoryPaletteStore())
        palette.remember(.erasePixel(.thin))
        #expect(palette.eraserMode == .pixel)
        #expect(palette.pixelEraserWidth == .thin)
        #expect(palette.lastKind == .eraser)

        palette.remember(.eraseObject)
        #expect(palette.eraserMode == .object)
        // The width the person chose is still there for the next switch back.
        #expect(palette.pixelEraserWidth == .thin)
        #expect(palette.eraserTool == .eraseObject)
    }

    @Test("Remembering a lasso leaves the palette alone and writes nothing")
    func rememberingALassoWritesNothing() {
        let store = MemoryPaletteStore()
        let palette = ToolPalette(store: store)
        palette.remember(.ink(.pencil, InkPreset(color: swatch(0x2B), width: .thin)))
        let written = store.stored

        palette.remember(.lasso)

        #expect(palette.lastKind == .ink(.pencil))
        #expect(store.stored == written)
    }

    @Test("Remembering text writes the text slot and the last kind, and touches no recent")
    func rememberingTextWritesTheTextSlot() {
        let store = MemoryPaletteStore()
        let palette = ToolPalette(store: store)
        palette.used(swatch(0x01))
        let bold = TextStyle(font: "system", size: 24, bold: true, italic: false, underline: false, color: RGBA8(red: 9, green: 8, blue: 7, alpha: 0xFF))

        palette.remember(.text(bold, .center))

        #expect(palette.text == TextPreset(style: bold, alignment: .center))
        #expect(palette.lastKind == .text)
        #expect(palette.currentTool == .text(bold, .center))
        #expect(palette.recentColors == [swatch(0x01)], "a colour typed with is never a recent")
        #expect(store.stored?.text == TextPreset(style: bold, alignment: .center))

        // A second palette over the store opens on text.
        #expect(ToolPalette(store: store).currentTool == .text(bold, .center))
    }

    // MARK: used

    @Test("Recents are most recent first, deduplicated, and capped")
    func recentsAreOrderedDeduplicatedAndCapped() {
        let palette = ToolPalette(store: MemoryPaletteStore())
        for index in 0..<12 { palette.used(swatch(UInt8(index))) }

        #expect(palette.recentColors.count == ToolPalette.recentLimit)
        #expect(palette.recentColors == (0..<8).reversed().map { swatch(UInt8($0 + 4)) })

        // A colour drawn with again moves to the front rather than doubling.
        palette.used(swatch(5))
        #expect(palette.recentColors.first == swatch(5))
        #expect(palette.recentColors.count == ToolPalette.recentLimit)
        #expect(Set(palette.recentColors.map(\.rgba.hex)).count == ToolPalette.recentLimit)
    }

    @Test("A colour a theme offers is recorded, and drawing on in it writes once")
    func aThemeColourIsRecordedAndRepeatingItWritesNothing() {
        let store = MemoryPaletteStore()
        let palette = ToolPalette(store: store)
        let offered = ToolColor(rgba: Theme.macaron.palette[0])

        palette.used(offered)
        #expect(palette.recentColors == [offered])
        #expect(store.saves == 1)

        // The report path runs once per stroke, and a second stroke in the
        // colour already at the front changes nothing to write.
        palette.used(offered)
        #expect(palette.recentColors == [offered])
        #expect(store.saves == 1)

        palette.used(swatch(0x01))
        #expect(palette.recentColors == [swatch(0x01), offered])
        #expect(store.saves == 2)
    }

    // MARK: Gesture bindings

    @Test("The bindings round-trip through the encoder the defaults store uses")
    func theBindingsRoundTrip() throws {
        // `ToolPaletteDefaults` encodes the whole record as a property list,
        // and a dictionary keyed by an enum is the one field whose shape on
        // disk is not obvious. Whatever shape it takes, what matters is that
        // it comes back.
        for bindings in [GestureBindings(), [.scribble: .erase]] {
            var record = ToolPaletteRecord.builtIn
            record.gestures = bindings
            let data = try PropertyListEncoder().encode(record)
            let read = try PropertyListDecoder().decode(ToolPaletteRecord.self, from: data)
            #expect(read == record)
            #expect(read.gestures == bindings)
        }
    }

    @Test("A record written before the gestures field existed reads the built-in bindings")
    func aRecordWithoutGesturesDecodes() throws {
        // A whole palette somebody keeps, not a record that cannot be used.
        let data = try PropertyListEncoder().encode(ToolPaletteRecord.builtIn)
        var plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist.removeValue(forKey: "gestures") != nil)
        let older = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let read = try PropertyListDecoder().decode(ToolPaletteRecord.self, from: older)
        #expect(read == .builtIn)
        #expect(read.gestures == [.scribble: .erase], "the built-in ships scribble bound to erase")
    }

    @Test("A record that names only the scribble reads the double circle as unbound")
    func aRecordWithoutTheDoubleCircle() throws {
        // The map is the record, not a merge with `builtIn`: `builtIn` is
        // the fallback for a record written before the field existed, and a
        // person who kept one with scribble bound has not asked for a
        // second trigger.
        var record = ToolPaletteRecord.builtIn
        record.gestures = [.scribble: .erase]
        let data = try PropertyListEncoder().encode(record)
        let read = try PropertyListDecoder().decode(ToolPaletteRecord.self, from: data)
        #expect(read.gestures[.scribble] == .erase)
        #expect(read.gestures[.doubleCircle] == nil)
    }

    @Test("Binding writes the map, nil unbinds, and a second palette opens on what was left")
    func bindingWritesAndNilUnbinds() {
        let store = MemoryPaletteStore()
        let palette = ToolPalette(store: store)
        #expect(palette.gestures == [.scribble: .erase])

        palette.bind(.scribble, to: nil)
        #expect(palette.gestures.isEmpty)
        #expect(store.stored?.gestures.isEmpty == true)
        #expect(ToolPalette(store: store).gestures.isEmpty, "a trigger unbound stays unbound")

        palette.bind(.scribble, to: .erase)
        #expect(palette.gestures == [.scribble: .erase])
        #expect(ToolPalette(store: store).gestures == [.scribble: .erase])
    }
}

