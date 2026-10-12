# Tool picker parity with GoodNotes

A plan, not code. Branch `v2-rewrite`. Every claim below is grounded in a
file it names; where the code moves, the file wins.

**In short.** Our own tool strip instead of `PKToolPicker`, because the
picker would be a second writer of the tool across three live canvases.
`EditorTool` becomes pen, pencil, highlighter with a preset each, two
erasers, lasso. Presets, colour recents, and the last tool live in
`UserDefaults` behind a two-method store, which is a named exception to
the file I/O rule. One colour parser, `RGBA8`, shared with `TextRun`.
Runs in parallel with `page-size-and-paper.md` and `page-navigator.md`,
and `text-editing.md` builds on it; `README.md` in this directory has the
order.

## 0. The two decisions this plan rests on

**Our own toolbar, not `PKToolPicker`.** `PKToolPicker` observes a
first-responder `PKCanvasView` and writes `canvasView.tool` itself. That is
a second writer of the tool. The window keeps up to three live canvases
(`SlotLayout.liveRadius = 1`), and `PagedCanvasController.apply` is the one
place that fans a tool out to all of them and to every canvas built later
(`applyContent`). A picker that set the tool on the first responder would
leave the other two stale, and a page turn would change which canvas it
drives. Against parity: GoodNotes shows a fixed row of tools, three preset
slots each, a colour strip with recents, and a tap-on-the-selected-tool
popover; `PKToolPicker` gives Apple's layout and one width slider. What we
lose is Pencil double tap (section 6).

**Presets, recents, and the last-used tool are app preferences, outside the
package.** `view.json` is disposable with one pinned key (`DurableKeys.view`
in `Modules/TNFormat/Codecs.swift`, tested by "view.json carries exactly its
key" in `TNTests/FormatTests.swift`), and "a field reserved for a future
feature" is forbidden. A tool is a fact about the person, not the notebook,
and GoodNotes treats it that way. So one `ToolPalette` per process, backed
by `UserDefaults`, owned by `Workspace`.

**This collides with a rule, and the plan has to say so.** The contract's
Structure section says "File I/O happens in `PosixFileSystem`,
`LibraryStore`, and `ImportReader`, and nowhere else", and
`ContractChecker.forbiddenFileIOTokens` names `UserDefaults` on purpose:
"durable state landing on disk without passing through a store, which is
the rule, not the API" (`TuberNotesTests/ContractStructureTests.swift`).
`fileIOAllowlist` has exactly three entries and `appSources()` walks every
module and `TuberNotesApp`, so a file naming `UserDefaults` fails
`fileIOIsConfinedToTheStorageActors` wherever it lives. The argument for an
exception: the rule exists so that notebook and library state has one
writer each and a known write order. A preference is neither; it has no
integrity to protect, no relationship to any other file, and losing it
costs a tap.

Where the exception lands matters. `TNEditor` is "the binding and the
editor view model"; licensing storage inside it widens what the module is.
So the palette itself is an in-memory owner in `TNEditor`, and persistence
is behind a two-method protocol whose one production conformer lives in
`TuberNotesApp/ToolPaletteDefaults.swift`, next to `ImportReader`, the
allowlist's existing app-level entry. That file is the allowlist addition,
with a comment saying it writes preferences and never notebook state, and
the Structure sentence is amended (section 5). Tests use an in-memory
conformer and never touch `UserDefaults`. If Phillip rejects the exception,
the app conformer is deleted and the palette forgets on relaunch, with no
other change to this plan.

## 1. The data shape

All in `Modules/TNEditor/EditorTool.swift` unless said otherwise. `TNEditor`
may import UIKit (`ContractStructureTests.moduleUIFrameworkPolicy`);
`TNModel` may not, which is why the UIKit-facing types are not model types.

One colour parser. `TextRun.color` is a `"#RRGGBBAA"` string
(`Modules/TNModel/Layer.swift`) and `TextRun.isValid` checks its shape by
hand. This plan does not add a second parser beside it:

```swift
// Modules/TNModel/RGBA8.swift, new. No UIKit; four bytes.
package struct RGBA8: Equatable, Sendable, Codable {
    package let red, green, blue, alpha: UInt8
    /// "#RRGGBBAA", exactly nine characters, uppercase or lowercase hex.
    package init?(hex: String)
    package var hex: String   // always uppercase "#RRGGBBAA"
}
```

`TextRun.isValid` becomes `RGBA8(hex: color) != nil`; `TextRun.color` stays
a `String` because the durable form is unchanged. The text-editing plan's
colour control, when it lands, formats through `RGBA8.hex` too.

```swift
/// A colour the picker can show and the runtime can draw. Not an enum:
/// custom colours exist. Alpha is always FF for ink: the marker's
/// translucency is PencilKit's, and a translucent pen colour on top of it
/// would dim twice. The ColorPicker well is shown with opacity off, and
/// init(_:) forces FF regardless.
package struct ToolColor: Equatable, Sendable, Codable {
    package let rgba: RGBA8                 // alpha is FF; init(_:) forces it
    /// Resolves in sRGB. A colour the picker's own well vended is always
    /// representable; a pattern or unresolved dynamic colour is a
    /// programmer error and traps through TNPrecondition.
    package init(_ color: UIColor)
    package var uiColor: UIColor { get }    // built from the four bytes, no parsing
    package static let defaults: [ToolColor]  // black, blue, red, green, and a few more
}

package enum ToolWidth: String, Sendable, Codable, CaseIterable { case thin, medium, thick }

/// The kinds carry their own width tables, so a fourth kind is one case
/// and one table here, and `ToolWidth` never learns who uses it.
package enum InkKind: String, Sendable, Codable, CaseIterable {
    case pen, pencil, highlighter
    package func points(_ width: ToolWidth) -> CGFloat
}

/// A slot's contents: what the palette remembers per kind. The attributes,
/// not a tool, so a slot cannot hold the wrong kind.
package struct InkPreset: Equatable, Sendable, Codable {
    package var color: ToolColor
    package var width: ToolWidth
}

package enum EditorTool: Equatable, Sendable {
    case ink(InkKind, InkPreset)
    /// `PKEraserTool(.vector)` deletes whole strokes and has no width, as
    /// GoodNotes' object eraser has no size. Two cases, so a width on the
    /// object eraser is unrepresentable rather than ignored.
    case eraseObject
    case erasePixel(ToolWidth)
    case lasso

    package static func pixelEraserPoints(_ width: ToolWidth) -> CGFloat
    package var pkTool: any PKTool   // ink -> PKInkingTool(.pen/.pencil/.marker, color:, width:)
                                     // eraseObject -> PKEraserTool(.vector)
                                     // erasePixel -> PKEraserTool(.bitmap, width:)
                                     // lasso -> PKLassoTool()
}
```

`.marker(color:)` with no width (today's `EditorTool`) goes away: GoodNotes
has three highlighter widths. `ToolColor` as a four-case enum goes away for
the same reason. `EditorTool` is `Equatable` and nothing more: `didSet`
compares, nothing hashes, and what is persisted is the record below, not
the tool. `InkKind.highlighter` maps to `PKInkingTool(.marker)` at `pkTool`
and nowhere else; "highlighter" is the product word and the contract's.

New file `Modules/TNEditor/ToolPalette.swift`:

```swift
/// What the person keeps between notebooks. One writer; views read it and
/// the view model calls its methods. Every field is the attributes of a
/// tool, never a tool, so the slots cannot disagree with their keys.
@MainActor @Observable package final class ToolPalette {
    /// Which kind of tool a new tab opens on. Lasso is not a member: a new
    /// tab opening on lasso is a tab you cannot write in. The tool itself
    /// is rebuilt from the slots below by `currentTool`.
    package enum Kind: Equatable, Sendable, Codable { case ink(InkKind), eraser }
    package private(set) var lastKind: Kind
    package private(set) var inks: [InkKind: InkPreset]     // every kind always present
    package private(set) var eraserMode: EraserMode         // .object | .pixel
    package private(set) var pixelEraserWidth: ToolWidth    // kept across mode switches
    /// Most recent first, at most 8, no duplicates, and never a colour that
    /// is already in `ToolColor.defaults`. A colour becomes recent when a
    /// stroke lands with it, not when it is picked: the editor calls
    /// `used(_:)` from the binding's ink report, once per tool change.
    package private(set) var recentColors: [ToolColor]

    package init(store: any ToolPaletteStore)   // a missing or undecodable record is the built-in default
    /// The tool `lastKind` names, built from the slots.
    package var currentTool: EditorTool { get }
    package func tool(for kind: InkKind) -> EditorTool
    package var eraserTool: EditorTool { get }
    package func remember(_ tool: EditorTool)   // lastKind (unless lasso) and the slot it came from; writes
    package func used(_ color: ToolColor)       // recents; writes
}

package enum EraserMode: String, Sendable, Codable { case object, pixel }

/// The whole palette as one value, for the store. Codable because the
/// store encodes it with PropertyListEncoder under one key.
package struct ToolPaletteRecord: Equatable, Sendable, Codable { ... the five fields ... }

/// Persistence for the palette. `TNEditor` names it; the app conforms.
package protocol ToolPaletteStore: Sendable {
    func load() -> ToolPaletteRecord?
    func save(_ record: ToolPaletteRecord)
}
```

`TuberNotesApp/ToolPaletteDefaults.swift` conforms with `UserDefaults`;
`TNTests` conforms with a dictionary. A malformed stored value is replaced
by the default. The contract's "nothing is clamped, adapted, corrected, or
replaced with a default" governs values the contract calls invalid, and it
never names preferences; the sentence added in section 5 makes the
preference default explicit rather than leaning on that silence.

Custody, after this plan:

| Value | Owner | Where it lives |
|---|---|---|
| The tool in hand for a tab | `EditorViewModel` | in memory, per tab; the runtime is told and keeps a copy for canvases built later |
| Presets, colour recents, last-used tool | `ToolPalette` | `UserDefaults` through `ToolPaletteStore`, never in the package |

The runtime never reports tool state upward, so it is not the owner; the
contract's Custody row currently says it is, and section 5 corrects it.
`CanvasEnvironment` keeps carrying `PKTool` and nothing else; `EditorTool`
becomes `PKTool` in `EditorViewModel.tool.didSet`. `pkTool` builds a new
object per access and `didSet`'s equality guard is the only dedup; the
runtime is told once per change, which is once.

## 2. The seam

No change. `CanvasSurface.apply(_ environment: CanvasEnvironment)` and
`struct CanvasEnvironment { let tool: PKTool }` in
`Modules/TNModel/Seam.swift` already carry every tool this plan produces.
`PagedCanvasController.apply` stores it and pushes it to every live canvas;
`applyContent` hands it to every canvas built after.
`PageCanvasController.apply(tool:)` is one assignment. Protocol diff: none.

## 3. File by file

**TNModel.** `RGBA8.swift`, new; `TextRun.isValid` parses through it.

**TNCanvas.** Nothing.

**TNEditor.**
- `EditorTool.swift`: the types in section 1, replacing `ToolColor` (enum),
  `ToolWidth.points`, and `EditorTool`. Width numbers stay "taste, not
  measurement" and the note stays, now on `InkKind.points`.
- `ToolPalette.swift`: new, as sketched, with `ToolPaletteStore` and
  `ToolPaletteRecord`. No file I/O; not on the allowlist.
- `EditorViewModel.swift`: `init(notebook:palette:onLinkActivated:)`; the
  initial `tool` is `palette.currentTool`; `tool` becomes `private(set)`,
  so the intentions are the only way to change it and the `didSet` that
  keeps `binding.apply` and adds `palette.remember(tool)` is a boundary,
  not a courtesy. Intentions so the view computes nothing: `select(kind:)`
  (restores that kind's slot), `selectEraser()` (restores the last mode
  and pixel width; the strip passes nothing), `setEraserMode(_:)` (from
  the popover's segmented control), `selectLasso()`, `setWidth(_:)`,
  `setColor(_:)`. `setWidth` on lasso or the object eraser and `setColor`
  on anything but ink are programmer errors and trap: the strip never
  offers them. The ink report path (`onDrained` after an `inkChanged`)
  calls `palette.used` with the current ink colour, once per tool change.
  A lasso selection in progress is dropped by PencilKit when the tool
  changes, as it is today; nothing here changes that.

**TuberNotesApp.**
- `ToolPaletteDefaults.swift`: new, the `UserDefaults` conformer. Added
  to `fileIOAllowlist`.
- `Workspace.swift`: owns `let palette = ToolPalette(store:
  ToolPaletteDefaults(.standard))` and passes it to every
  `EditorViewModel` it makes in `open(path:name:)`.
- `EditorView.swift`: the `tools` block, `penButton`, `toolButton`,
  `isPen`/`isMarker`/`isEraser`/`isLasso`, and `currentWidth` are removed.
  The toolbar takes a `ToolStrip`.
- `ToolStrip.swift`: new. One button per tool (pen, pencil, highlighter,
  eraser, lasso). Tapping an unselected tool selects it; tapping the
  selected one opens that button's popover, anchored to it, so the state
  is `@State var optionsFor: EditorToolButton?`, one enum case per button.
  Lasso has no popover; tapping it again does nothing. Ink popover: three
  width dots and a colour row (recents, then `ToolColor.defaults`, then a
  `ColorPicker` with `supportsOpacity: false` whose result becomes
  `ToolColor(UIColor(color))`). Eraser popover: object/pixel segmented
  control calling `setEraserMode(_:)`, and the three width dots only in
  pixel mode. Everything drawn
  comes from `editor.tool` and `workspace.palette`; everything done is one
  `editor.` call.

## 4. Tests

Hostless, `TNTests`:
- `TNModelTests`: `RGBA8(hex:)` rejects wrong length, missing `#`, and
  non-hex; round-trips uppercase; every `TextRun` the existing tests call
  valid is still valid and the invalid ones still invalid.
- `EditorToolTests.swift`, new. `pkTool` for each case: class, `inkType`,
  `color` as bytes after resolving, `width`, `eraserType`; the vector
  eraser is built without a width. `ToolColor(_ uiColor:)` forces FF
  alpha. `ToolPaletteRecord` round-trips through `PropertyListEncoder`.
- `ToolPaletteTests.swift`, new, on an in-memory `ToolPaletteStore`.
  Recents are most recent first, capped, deduplicated, and exclude the
  defaults. `remember(.lasso)` leaves `lastKind` alone. `remember` of a
  pen writes only the pen slot. A second palette on the same store
  restores everything. A garbage record restores the default.
- `EditorBindingTests.swift`: no addition. `RecordingSurface` is injected
  into `EditorBinding`, and the tool is applied by `EditorViewModel`, which
  builds the production binding (`EditorViewModel.init`,
  `Modules/TNEditor/CanvasRuntime.swift`); there is no seam to put a
  recording surface under a view model, and this plan does not add one.
- `EditorViewModelTests.swift`, new, hostless. A view model built on a
  palette whose `lastTool` is a thick red pencil has `tool` equal to it;
  two view models on one palette open with the same tool; `select(kind:)`
  restores that kind's last colour and width. This asserts `editor.tool`,
  not the environment the runtime received; that is the hosted test's job.

Hosted, `TuberNotesTests`:
- `TNCanvasTests.swift`: after `apply`, every canvas in `canvases` has that
  `canvasView.tool`, and a canvas built by a later `installContent` has it.
- `ContractStructureTests.swift`: the `fileIOAllowlist` entry for
  `TuberNotesApp/ToolPaletteDefaults.swift`; and if
  section 5's "no `PKToolPicker`" sentence is adopted, a source scan for
  the identifier in the style of the `PKCanvasView` construction-site rule.

Device, not a test: the three widths per kind under a Pencil, pixel eraser
width against a stroke, highlighter over ink. Record in the PR; the verdict
is Phillip's.

## 5. Contract sentences to change

Proposals; the rule is Phillip's to write. They go to `Docs/Contract.md`
directly because that file is itself a proposal awaiting his signature
(`Docs/Queue.md`, "Sign the contract"); there is no separate staging file
for v2.

Custody table, quoted:
> "Which pages have canvases, the scroll position, the tool | `PagedCanvasController` | in memory; rebuilt from one `setPages` and the installs that follow"

Proposed, two rows:
> "Which pages have canvases, the scroll position | `PagedCanvasController` | in memory; rebuilt from one `setPages` and the installs that follow"
> "The tool in hand | `EditorViewModel`, per tab | in memory; the runtime is told and keeps a copy for canvases built later"

And a new row:
> "Tool presets, colour recents, the last-used tool | `ToolPalette` | `UserDefaults`; never in the package"

Structure, quoted:
> "File I/O happens in `PosixFileSystem`, `LibraryStore`, and `ImportReader`, and nowhere else."

Proposed:
> "File I/O happens in `PosixFileSystem`, `LibraryStore`, and `ImportReader`, and nowhere else. The app's `ToolPaletteDefaults` writes preferences to `UserDefaults`; a preference is never notebook or library state, and an unreadable one is replaced by the built-in default."

Durable form, Geometry, quoted:
> "Pan, zoom, and view frames are never saved."

Proposed:
> "Pan, zoom, view frames, and the tool are never saved in the package."

"The canvas is told, never asks", add one sentence:
> "The tool picker is the app's. `PKToolPicker` is not used, because it would be a second writer of the tool."

`Docs/Queue.md`, Parity gaps: the tool picker line comes out when this
lands.

## 6. Deliberately out of scope

- Apple Pencil double tap and squeeze. `PKToolPicker` gave those free; ours
  needs a `UIPencilInteraction` in `TNCanvas` and a new report answered by
  an `apply`. That is a seam change and its own plan.
- User-editable width slots. Three fixed points per kind first. The
  follow-up is not an extension: `ToolWidth` is a three-case enum that
  drives the width dots and is what the record stores, so editable slots
  replace it with points per slot and a record migration under the
  malformed-record-reads-as-default rule. Deferring is right; the cost is
  stated so it is not mistaken for small.
- A shapes tool, favourites, keyboard shortcuts, pressure and tilt
  settings, pen styles. The text tool is `text-editing.md`'s; it joins the
  strip there as one more `EditorToolButton` with its own popover, and
  that plan widens `CanvasEnvironment` when it does (section 9).
- Highlighter drawn behind ink. PencilKit's marker composites over ink;
  putting it behind would need a second drawing, which is a second copy of
  ink and forbidden.
- Anything in the package. No `view.json` key, no format bump.

## 7. Open questions for Phillip

1. When two tabs are open, does picking a pen in one change the other's
   tool at once (one app-wide tool, as GoodNotes) or only on its next open
   (this plan)? Taste, not an experiment.
2. Is a highlighter that sits over ink acceptable for parity, or is
   behind-ink a requirement that changes what "highlighter" means here?
3. Is the `UserDefaults` exception acceptable, or should the palette forget
   on relaunch until a preferences store exists?

## 8. Review disposition

An adversarial review of this plan was answered on 2026-09-10. Adopted,
and folded into the sections above:

- Two eraser cases instead of one with a dead width; the object eraser
  cannot carry a width it ignores.
- Palette slots hold attributes (`InkPreset`, an eraser mode, a pixel
  width), never an `EditorTool`, so a slot cannot hold the wrong kind. The
  last tool is a `Kind`, rebuilt from the slots; "lasso is not remembered"
  is now a fact of the type, not of `remember`.
- Width tables live on `InkKind` and on the pixel eraser, not on
  `ToolWidth`.
- One colour parser, `RGBA8` in `TNModel`, shared with `TextRun`;
  `ToolColor` holds bytes and never re-parses.
- `selectEraser()` takes nothing and `setEraserMode(_:)` is separate.
- `tool` is `private(set)`.
- Persistence behind `ToolPaletteStore`; the `UserDefaults` conformer and
  the allowlist entry are the app's, not `TNEditor`'s.
- `Hashable` dropped; `Codable` only on the record.
- Section 6 says the editable-slots follow-up replaces `ToolWidth`.

Rejected, with the reason:

- "`remember` mixes recents in": it does not; recents come from `used(_:)`
  on the ink report, which is the "colours you drew with" semantic the
  review asked for. Section 1 already said so.
- "`isShowingOptions` cannot name the anchor": the plan's state is
  `optionsFor: EditorToolButton?`, one case per button.
- Renaming `highlighter` to `marker`: the product and contract word is
  highlighter; one translation at `pkTool` is the whole tax.
- Deduplicating `pkTool` allocations: `didSet` compares `EditorTool`
  values, so the runtime is told once per change already.

## 9. Cross-plan

`README.md` in this directory, conflicts 1 and 2. This plan lands as
written and `text-editing.md` builds on it: `.text` becomes a case of
`EditorTool` and of `EditorToolButton`, `selectText()` and
`setTextStyle(_:)` join the intentions, `pkTool` becomes `canvasTool`
returning a `CanvasTool`, and `CanvasEnvironment` widens then, not here.
Per `README.md` decisions 2 and 3: the text-editing PR adds `.text` to
`ToolPalette.Kind` and a `textStyle: TextStyle` slot to the palette, so
`remember(.text(style, alignment))` writes that slot and `lastKind`;
`used(_:)` stays on the ink report, so a colour typed with is never a
recent. `TextStyle.color` is an `RGBA8` from the day it exists, so the
"one colour parser" sentence in section 1 holds. Nothing here waits on
`page-size-and-paper.md` or `page-navigator.md`; the `EditorView` toolbar
and `Workspace.swift` are shared with them and rebase cleanly.
