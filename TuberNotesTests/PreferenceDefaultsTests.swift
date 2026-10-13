import Foundation
import Testing
@testable import TNEditor
@testable import TNLibrary
@testable import TNModel
@testable import TuberNotes

/// A domain of its own per use, torn down after it, so a run leaves the
/// machine holding nothing it did not start with.
private func withStore(_ body: (PreferenceDefaults<ThemeChoice>, UserDefaults) -> Void) {
    let name = "tn.themeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    body(PreferenceDefaults(key: "tn.theme", defaults), defaults)
    defaults.removePersistentDomain(forName: name)
}

/// One preference, the theme choice, written and read back whole.
@Suite("A preference")
struct PreferenceDefaultsTests {
    @Test("An unset preference is no choice at all")
    func absent() {
        withStore { themes, _ in
            #expect(themes.load() == nil)
        }
    }

    @Test("Every choice the app can make comes back as itself")
    func roundTrip() {
        let choices = [ThemeChoice.system] + Theme.presets.map { ThemeChoice.preset($0.id) }
        for choice in choices {
            withStore { themes, _ in
                themes.save(choice)
                #expect(themes.load() == choice)
            }
        }
    }

    @Test("Bytes that are not a choice are not repaired into one")
    func rubbish() {
        withStore { themes, defaults in
            defaults.set(Data([0x00, 0x01]), forKey: "tn.theme")
            #expect(themes.load() == nil)
        }
    }

    @Test("A saved palette whose text style names another face opens on the built-in")
    @MainActor
    func paletteNamingAnotherFace() throws {
        let name = "tn.paletteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let palettes = PreferenceDefaults<ToolPaletteRecord>(key: "tn.toolPalette", defaults)
        var saved = ToolPaletteRecord.builtIn
        saved.lastKind = .text
        palettes.save(saved)
        #expect(ToolPalette(store: palettes).record == saved)

        let bytes = try #require(defaults.data(forKey: "tn.toolPalette"))
        var plist = try #require(try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        var text = try #require(plist["text"] as? [String: Any])
        var style = try #require(text["style"] as? [String: Any])
        #expect(style["font"] as? String == "system")
        style["font"] = "Georgia"
        text["style"] = style
        plist["text"] = text
        defaults.set(try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0), forKey: "tn.toolPalette")
        #expect(palettes.load() == nil)
        #expect(ToolPalette(store: palettes).record == .builtIn)
    }
}

/// What the app opens on, which is the launch argument first and the
/// preference second.
@Suite("The launch theme")
@MainActor
struct LaunchThemeTests {
    @Test("-TNTheme names a theme by its id, or the system by `system`")
    func namedTheme() {
        withStore { themes, _ in
            themes.save(.preset(Theme.presets[1].id))
            for preset in Theme.presets {
                let choice = Workspace.launchChoice(["TuberNotes", "-TNTheme", preset.id.rawValue], themes)
                #expect(choice == .preset(preset.id))
            }
            #expect(Workspace.launchChoice(["TuberNotes", "-TNTheme", "system"], themes) == .system)
        }
    }

    @Test("Without the argument the preference decides, and without one the system does")
    func fallsBackToThePreference() {
        withStore { themes, _ in
            #expect(Workspace.launchChoice(["TuberNotes"], themes) == .system)
            themes.save(.preset(Theme.presets[1].id))
            #expect(Workspace.launchChoice(["TuberNotes"], themes) == .preset(Theme.presets[1].id))
        }
    }

    @Test("A saved choice naming a theme this build has no row for opens on the system")
    func unknownSavedIdentity() {
        withStore { themes, _ in
            themes.save(.preset(ThemeID(rawValue: "noSuchTheme")))
            #expect(Workspace.launchChoice(["TuberNotes"], themes) == .system)
            #expect(Workspace.launchChoice(["TuberNotes", "-TNTheme", "noSuchTheme"], themes) == .system)
        }
    }

    @Test("A theme argument with nothing after it is not an argument")
    func danglingArgument() {
        withStore { themes, _ in
            #expect(Workspace.launchChoice(["TuberNotes", "-TNTheme"], themes) == .system)
        }
    }

    /// A typo, the next flag read as the id, and the name the picker shows.
    @Test("A theme argument that is no preset's id is dropped, and the preference decides")
    func unknownThemeNameFallsBack() {
        let remembered = ThemeChoice.preset(Theme.presets[1].id)
        let unknown = ["noSuchTheme", "-TNSeed", Theme.presets[1].name]
        withStore { themes, _ in
            for value in unknown {
                #expect(Workspace.launchChoice(["TuberNotes", "-TNTheme", value], themes) == .system)
            }
            themes.save(remembered)
            for value in unknown {
                #expect(Workspace.launchChoice(["TuberNotes", "-TNTheme", value], themes) == remembered)
            }
        }
    }
}

#if DEBUG
/// What a screenshot launch opens on, read from its arguments.
@Suite("The launch scene")
struct LaunchSceneTests {
    @Test("No arguments open nothing")
    func empty() {
        let scene = LaunchScene(["TuberNotes"])
        #expect(scene == LaunchScene([]))
        #expect(scene.sheet == nil && scene.section == nil && scene.layout == nil && scene.dialog == nil)
        #expect(!scene.tray && !scene.seed && !scene.opensEditor)
    }

    @Test("Each hook takes its value, and the flags stand alone")
    func everyHook() {
        let scene = LaunchScene([
            "TuberNotes", "-TNSeed", "-TNSheet", "export", "-TNLibrary", "trash",
            "-TNLayout", "list", "-TNDialog", "insert", "-TNTray",
        ])
        #expect(scene.sheet == .export)
        #expect(scene.section == .trash)
        #expect(scene.layout == .list)
        #expect(scene.dialog == .insert)
        #expect(scene.tray && scene.seed)
        #expect(LaunchScene(["-TNLibrary", "documents"]).section == .documents)
        #expect(LaunchScene(["-TNLayout", "grid"]).layout == .grid)
    }

    @Test("A value no case has, or a missing one, opens nothing")
    func unknownValues() {
        let scene = LaunchScene(["-TNSheet", "stickers", "-TNLibrary", "favorites", "-TNLayout", "-TNSeed", "-TNDialog"])
        #expect(scene.sheet == nil && scene.section == nil && scene.layout == nil && scene.dialog == nil)
        #expect(scene.seed)
    }

    @Test("Settings is the library's sheet; every other sheet, the dialog and the tray are the editor's")
    func whichSurface() {
        #expect(!LaunchScene(["-TNSheet", "settings"]).opensEditor)
        #expect(LaunchScene(["-TNSheet", "addPage"]).opensEditor)
        #expect(LaunchScene(["-TNDialog", "insert"]).opensEditor)
        #expect(LaunchScene(["-TNTray"]).opensEditor)
        #expect(!LaunchScene(["-TNSeed", "-TNLayout", "list"]).opensEditor)
    }
}
#endif
