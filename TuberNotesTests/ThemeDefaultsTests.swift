import Foundation
import Testing
@testable import TNModel
@testable import TuberNotes

/// A domain of its own per use, torn down after it, so a run leaves the
/// machine holding nothing it did not start with.
private func withStore(_ body: (ThemeDefaults, UserDefaults) -> Void) {
    let name = "tn.themeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    body(ThemeDefaults(defaults), defaults)
    defaults.removePersistentDomain(forName: name)
}

/// The one boundary a theme crosses: a choice written to a preference, and
/// read back by a build that may no longer have the row it names.
@Suite("The theme preference")
struct ThemeDefaultsTests {
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

    @Test("A choice naming a theme this build has no row for opens on the system")
    func unknownIdentity() {
        withStore { themes, _ in
            themes.save(.preset(ThemeID(rawValue: "noSuchTheme")))
            #expect(themes.load() == nil)
        }
    }

    @Test("Bytes that are not a choice are not repaired into one")
    func rubbish() {
        withStore { themes, defaults in
            defaults.set(Data([0x00, 0x01]), forKey: "tn.theme")
            #expect(themes.load() == nil)
        }
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
        let unknown = ["noSuchTheme", "-TNShowSettings", Theme.presets[1].name]
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
