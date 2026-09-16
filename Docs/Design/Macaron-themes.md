# Macaron themes — the manager and the six presets

Build-order step 8 shipped theme *switching*: four hard-coded themes behind a
context menu, a `themeIsChosen` flag, and no memory across launches. This
step turns that into a theme manager and fills it from the canvas's
**Six themes, one geometry** board.

## Data shape

- `ThemeID` — a branded string (`Codable`, `Hashable`). Never a raw `String`
  past the defaults boundary.
- `ThemePreset { id: ThemeID, name: String, theme: Theme }`.
- `Theme.presets: [ThemePreset]` — the registry, in board order. Lookup is
  `Theme.preset(_ id:) -> ThemePreset?`.
- `ThemeChoice` — the one piece of chosen state, replacing the
  `theme` + `themeIsChosen` pair:
  - `.system` — Macaron by day, Macaron Dark after dark.
  - `.preset(ThemeID)` — fixed, whatever the system says.
  - `resolve(dark: Bool) -> Theme`.
- `ThemeDefaults` (TuberNotesApp) — `load() -> ThemeChoice?`, `save(_:)`, one
  key `tn.theme`, same shape and same allowlist reasoning as
  `ToolPaletteDefaults`. An unknown persisted id loads as `nil`, so an old
  build's choice opens on `.system` rather than failing loud: it is external
  data at a boundary, not an invalid internal state.

## Custody

`Workspace` owns `choice` and the resolved `theme`. Setting `choice` saves
it and re-resolves; `RootView` reports the colour scheme to the workspace
(`workspace.colourScheme = …`) and never picks a theme itself. `Theme.current`
and the `changed` notification stay as the bridge to the UIKit canvas.

`-TNTheme <name>` keeps working and sets `.preset` for the named preset.

## The picker

The library chip's context menu becomes one entry, **Themes…**, which opens
a Macaron panel: a grid of preset cards, one per row of the registry, plus
**Follow the system** on top. A card is a keycap: the preset's `ground` as
the fill, a chrome bar across it carrying an accent dot and a secondary dot,
its name beneath in Lilita. The chosen card is sunk (`isHeld`). Tapping a
card sets `workspace.choice` and the whole app repaints; the panel stays
open so themes can be compared.

## The presets, from the board

Board values win over the document where they differ; the document says
so. The board's "Default" (`#EDEDED` / `#111111`) is the grey-grid reference
composition, not Macaron; Macaron's cream stays as §3.1 of `Macaron.md`.

| id | name | ground | chrome | accent | secondary | ink |
|---|---|---|---|---|---|---|
| macaron | Macaron | #F4EADA | #FFFFFF | #FF6A8C | #FFB347 | #141414 |
| macaronDark | Macaron Dark | #26211B | #332C24 | #FF6A8C | #FFB347 | #F4EADA (inverts) |
| switch | Switch | #E7E9EC | #F2F3F5 | #FF3C28 | #0AB9E6 | #1B1D21 |
| gameBoy | Game Boy | #9BBC0F | #C6CBA5 | #B0176B | #5C2B8A | #0F380F |
| animalCrossing | Animal Crossing | #F3EAD6 | #FFFBF0 | #8CC63F | #7EC8E3 | #7A6244 |
| kirby | Kirby | #FFE9F1 | #FFFFFF | #FF8AB5 | #7FC8F0 | #3A2233 |
| teenageEnamel | Teenage Enamel | #D9D9D6 | #EFEFEC | #FF5500 | #1A1A1A | #1A1A1A |

The invented Switch and Game Boy hexes from step 8 go; the board has real
ones now.

## Tests (TNTests/ThemeTests.swift, TNTests/ThemeChoiceTests.swift)

- Teenage Enamel's secondary is its ink, so `outline(of: secondary)` mixes
  toward paper (the escape), and every other token there takes the plain
  rule.
- Game Boy: the purple `secondary` takes the escape and both greens take the
  plain rule. (Written as `chrome` and `ground` before the build measured
  them; the board's greens clear 1.6 against `#0F380F` comfortably.)
- Every preset: `outline(of:)` of each token has contrast ≥ 1.3 against the
  token, so no theme ships an invisible line.
- Preset ids are unique; `-TNTheme` names match preset names.
- `ThemeChoice` round-trips through `ThemeDefaults`; an unknown id loads
  `nil`.

## Verification

Simulator: build, tests, one screenshot per preset via `-TNTheme`, and one
of the picker. iPad: the picker's press feel, Phillip's verdict.
