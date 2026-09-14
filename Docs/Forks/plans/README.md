# The plans: what runs in parallel, what waits

Ten plans sit in this directory. This file says how they relate, so a
reader can pick one up without reading the other three first. Each plan
still owns its own detail; where this file and a plan disagree, the plan
is wrong and the fix is here first, then there.

| Plan | One line | Size | Seam change | Format change |
|---|---|---|---|---|
| `tool-picker.md` | Our own tool strip, presets and recents in `UserDefaults`, `RGBA8` colour parser | medium | none | none |
| `page-size-and-paper.md` | Size and paper chosen at page and notebook creation, one new `appendPage` intention | medium | none | none |
| `page-navigator.md` | Thumbnail grid, reorder, delete, add; in-memory thumbnail cache on the renderer | large | none | none |
| `text-editing.md` | Live `UITextView` in the canvas, text as a tool, one typesetting builder | largest | yes | none |
| `undo.md` | History entries become page revisions with both sides; layers and text sessions join the stack; page delete purges | medium | two one-way commands | none |
| `selection.md` | Objects get a caller: tap under the lasso selects an image or PDF clipping, a frame with handles moves, scales, rotates, one report at the drop; ink lasso is already PencilKit's | medium | one report | none |
| `export.md` | One renderer function draws pages into a PDF context; PNG through `flattened`; `ShareLink` and print; nothing written to disk | small | none | none |
| `loose-ends.md` | Nine one-commit items over existing intentions, plus a defect: every notebook opens on page 1 | small | none | none |
| `organisation.md` | A page mark that carries its title, the outline as the marked pages, folder colour and symbol in `.folder.json`, drag and drop between folder cells | medium | none | index to 3, folder sidecar to 2 |
| `capture.md` | A camera photo as a layer and a VisionKit scan as N pages, both reusing the photo picker's back half from `Data` inwards | small | none | none |
| `pencil-gestures.md` | Scribble to erase, recognised by the notebook after the stroke commits and applied as a restore; one enum, one pure function, bindings from triggers to effects in the ink popover; reviewed twice 2026-09-14; six steps ending in a double-circle trigger | medium | none | none |

## Order

Three can start today, in parallel. One waits.

```
tool-picker ───────────┐
page-size-and-paper ───┼──▶ text-editing
page-navigator ────────┘
```

**Wave 1, parallel.** `tool-picker`, `page-size-and-paper`, `page-navigator`.
They share files but not functions. The merge cost is a rebase of the
`EditorView` toolbar `HStack` and the `Docs/Contract.md` hunks, both
trivial.

**Wave 2.** `text-editing`, after all three. The hard dependency is on
`tool-picker`. The other two are soft, one bump site and one policy, both
listed below. Text editing is also the plan with the most open questions
and the only one that changes the seam, so it is last for its own reasons
too.

Why `tool-picker` comes before `text-editing` rather than the reverse.
Both rewrite `EditorTool`. Text editing needs a tool that is not a
`PKTool`, a colour type, a strip to put a text button in, and a place to
remember the last text style. Tool picker builds all four and is the
smaller plan. Landing text editing first would mean inventing each of them
twice. The reverse order costs text editing one rewrite of its `TNEditor`
and `TuberNotesApp` sections, recorded in that plan's cross-plan section.

**Wave 3, 2026-09-11, after `undo.md` landed on `v2-mvp`.** `selection.md`,
`export.md`, and `loose-ends.md` are independent of each other and can run
in parallel. `export.md` touches nothing the other two do except the
`EditorView` toolbar and `EditorViewModel`, textual only. `selection.md`
and `loose-ends.md` hand two items across: deleting an object belongs to
`selection.md`; moving a link belongs to `loose-ends.md` (commit 9), and
`selection.md`'s overlay is its caller. `selection.md` and `export.md`
each carry Contract hunks; `loose-ends.md` carries none. Each plan's
section 8 records the simplicity review it answered.

**Wave 4, 2026-09-12, after wave 3 merged into `v2-mvp` at `2a8fbf8`.**
`organisation.md` and `capture.md` are independent and run in parallel.
They share two files textually and nothing semantically: the
`EditorView` toolbar, where organisation adds a mark button and capture
adds two rows to the Insert menu that is already there, and
`EditorViewModel`, where each adds its own methods. Neither changes the
seam. Capture changes no rule at all; organisation carries four
one-phrase Contract hunks. Each plan's section 8 records the three
reviews it answered, two for simplicity on different models and one
adversarial.

Two facts from wave 4 worth carrying forward, because they cost time to
find and will cost it again. Every decoder in this codebase is strict and
refuses unknown keys (`Modules/TNFormat/Codecs.swift:56-72`), so any new
durable field is a format version bump and never an addition; and
`Docs/Contract.md:14-16`, "no data to keep", is what makes such a bump
legal without a migrator. Apply that sentence consistently or a reviewer
will catch you applying it twice in one plan and refusing it once.

## Shared files

Where two plans touch one file. "Region" says whether the edits overlap.

| File | Plans | Region |
|---|---|---|
| `TuberNotesApp/EditorView.swift` | all four | toolbar `HStack`: picker replaces `tools`, page-size rewires "Add page", navigator adds a button, text adds a button and strip. Textual conflict, no semantic one, except picker and text (below). |
| `Modules/TNEditor/EditorViewModel.swift` | all four | picker: `init`, `tool`, intentions. page-size: `addPage(size:...)`, `pagesWithAssetPaper`. navigator: mirrors, `movePage`, `deletePage`, `addPage(after:)`. text: `tool` case, `addTextBox` deleted. Distinct methods. |
| `Modules/TNEditor/EditorTool.swift` | picker, text | **same type.** Picker rewrites it; text adds a case. See conflict 1. |
| `Modules/TNNotebook/Notebook.swift` | page-size, navigator, text | page-size: `appendPage`. navigator: `contentVersions`, `decode`, `thumbnail`, `deletePage`. text: `insertLayer`, `textEditing`, `renderGeneration`. Distinct methods; one bump-site handoff (conflict 3). |
| `Modules/TNRender/Renderer.swift` | navigator, text | navigator factors the compose step and adds caches; text changes `drawText`. Distinct functions. |
| `Modules/TNCanvas/PagedCanvasController.swift` | navigator, text | navigator drops reports from a retiring canvas; text routes commands. Distinct, one policy to align (conflict 4). |
| `TuberNotesApp/Workspace.swift` | picker, navigator | picker adds the palette; navigator adds the memory-warning purge. Both additive. Both put the PR on the device-evidence list. |
| `TuberNotesTests/ContractStructureTests.swift` | picker, text | picker: `fileIOAllowlist`, a `PKToolPicker` scan. text: `uiFrameworkModules`, `filesPlacedByDesign`. Different tables. |
| `TNTests/EditorBindingTests.swift` | navigator, text | both extend `RecordingSurface` and add cases. Additive. |
| `Modules/TNModel/Layer.swift` | picker, text | picker: `TextRun.isValid` parses through `RGBA8`. text: `TextRun.init(string:style:)`. Additive, but see conflict 2. |
| `Docs/Contract.md` | all four | Custody table (three add rows, picker splits one), Rendering (two adjacent sentences), Undo (two different sentences), Structure (two different sentences), Durable form (two nearby sentences). Every hunk is Phillip's `CONTRACT:` commit, so they serialize on him regardless. |
| `Docs/Queue.md` | all four | each removes its own Parity gaps line. |

Files only one plan touches, for completeness: `Seam.swift` (text only),
`PageState.swift` (text only), `NotebookChange.swift` (text only),
`NotebookIndex.swift` and `LibraryStore.swift` (page-size only),
`PageCanvasController.swift` (text only).

## Conflicts

Numbered so a plan can cite them.

**1. Who owns `EditorTool`, and what the strip shows.** `tool-picker`
makes `tool` `private(set)` behind intentions, converts it to a `PKTool` in
`didSet`, says `CanvasEnvironment` keeps carrying a `PKTool` and nothing
else, and lists "a text tool in the strip" as out of scope. `text-editing`
adds `case text(TextStyle, TextAlignment)`, renames `pkTool` to
`canvasTool`, changes `CanvasEnvironment` to carry a `CanvasTool`, has the
strip assign `editor.tool` directly, and adds a text button to the
`EditorView` block that `tool-picker` deletes. Resolution: `tool-picker`
lands as written. `text-editing` then adds `.text` to `EditorTool` and to
`EditorToolButton`, adds `selectText()` and `setTextStyle(_:)` intentions
beside `setColor(_:)`, puts its style controls in the text button's popover
the way ink widths live in the pen popover, and widens `CanvasEnvironment`
at that point. `ToolPalette.Kind` gains `.text` and a text style slot
(decision 2 below), and `used(_:)` stays on the ink report (decision 3).
Both plans now say this in their cross-plan sections.

**2. Two colour representations.** `tool-picker` adds `RGBA8` in `TNModel`
so `TextRun.color` has one parser. `text-editing` gives `TextStyle.color` a
`String` and moves `Renderer.color(_:)` onto `TextStyle`, which is a second
parser. Resolution: `TextStyle.color` is an `RGBA8`; `TextRun.style`
parses through `RGBA8(hex:)` and `TextRun.init(string:style:)` formats
through `RGBA8.hex`. `Renderer.color(_:)` becomes a `CGColor` accessor on
`RGBA8`, or on `TextStyle` built from the bytes, and never re-parses. The
text plan's data shape section is corrected.

**3. The `contentVersion` bump sites.** `page-navigator` enumerates every
notebook mutation that must bump a page's version and names
`endTextEditing` as a future site. `text-editing` also splits `addLayer`
into `insertLayer` plus an async shell, so the bump the navigator puts in
`addLayer` moves into `insertLayer`, and step two's `.layersRestored` is a
fourth site. Resolution: whichever lands second adds the bumps and extends
the navigator's `NotebookTests` list, which is the invariant's only
enforcement. With the order above, that is `text-editing`.

**4. Reports from a canvas that has been let go.** `page-navigator`
decides that a report from a canvas in `retiring` is a dead letter and the
runtime does not forward it. `text-editing` says a `textEditingEnded` for a
page no longer `.ready` is logged at the notebook, not trapped. Two
policies for one situation. Resolution: the navigator's, because it keeps
the contract sentence that a canvas sending state for a page the notebook
does not hold is a bug. `pageDidChangeInk` and the text forwarder both
drop for a page in `retiring`; the notebook keeps its trap. The text plan
now says so.

**5. Not a conflict, but easy to misread.** `page-navigator`'s "add page
after" and `page-size-and-paper`'s setup sheet. The navigator says it
presents the sheet if page-size has landed and otherwise inherits the
current page's paper with a label saying so. Either order works. The bump
at creation lives in the `appendPage` body both plans share.

**6. Not a conflict.** `page-navigator`'s `contentVersion` and
`text-editing`'s `renderGeneration` are two counters on the same page and
look like one. They are not. Content version changes when the page's
picture should change; render generation changes per render, including the
begin-editing render that alters no content. Keep both.

## Cross-plan decisions, Phillip, 2026-09-10

Each plan's own open questions stand. These three were cross-plan and
are closed.

1. Order: sequence. `tool-picker` lands, then `text-editing` builds on
   it. No shared `EditorTool` shape is agreed ahead of time.
2. The last text style joins `ToolPalette` as a remembered kind. One
   text slot beside the ink presets, `lastKind` gains `.text`, added in
   the text-editing PR. A new tab opens on text if text was last.
3. Colours typed with are not recent colours. `ToolPalette.used(_:)` is
   called from the ink report only; `recentColors` stays a row of ink
   colours. The text popover shows defaults and the well, no recents.
