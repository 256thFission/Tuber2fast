# Notebook gallery + pages + tool bar

New product-facing feature set added on top of your existing spatial-canvas app.

## What was added

- **Gallery page** (`LibraryView.swift`) — grid of notebook covers saved locally to the app. Create, rename (context menu), delete (context menu). Tapping a cover opens it.
- **Local persistence** (`NotebookStore.swift`) — one JSON file per notebook in `Documents/Notebooks/<uuid>.json`, following the same `Codable` + `FileManager` pattern as your `PenFixtureStore`. Drawings are stored as serialized `PKDrawing` data inside each page.
- **Pages + page flipping** (`NotebookViewModel.swift`, `PageFlipOverlay.swift`) — a notebook is an ordered list of pages. **Long-press the page** to open a navigator with prev/next arrows, a swipe gesture, and tappable thumbnails. Add/delete pages from there too.
- **Thin menu bar** (`NotebookToolbar.swift`) — a floating capsule with: home button, the four writing utensils (pen / pencil / marker / eraser), an ink-color picker, a light/dark/system toggle, an add-page button, and a tappable page indicator (also opens the navigator).
- **Editor screen** (`NotebookView.swift`) — white ruled paper + a clean PencilKit canvas (`NotebookCanvas.swift`) that isn't entangled with the DEBUG fixture-recording canvas.

## Files

| File | Role |
|------|------|
| `Notebook.swift` | Models: `Notebook`, `NotebookPage`, `NotebookCover`, `WritingTool`, `InkColor`, `AppAppearance` |
| `NotebookStore.swift` | Local file persistence (`ObservableObject`, `NotebookStore.shared`) |
| `NotebookViewModel.swift` | Per-notebook page/tool state + debounced saving |
| `NotebookCanvas.swift` | `UIViewRepresentable` PencilKit surface for a page |
| `NotebookToolbar.swift` | The thin floating menu bar |
| `PageFlipOverlay.swift` | Long-press page navigator (arrows, swipe, thumbnails) |
| `LibraryView.swift` | The gallery + cover cards + create/rename/delete |
| `NotebookView.swift` | The page editor screen + ruled paper background |
| `TuberNotesApp.swift` | **Replaces** your existing entry point (see below) |

## Wiring

1. Add all the `.swift` files to your target.
2. Replace your current `TuberNotesApp.swift` with the one here. It now opens the **gallery** on normal launch, and still shows your existing `RootView(scenario:)` whenever the app is launched by the agent harness (any of `TUBER_SCENARIO`, `TUBER_RECORD_PEN_FIXTURE`, `TUBER_PEN_FIXTURE`, or `--scenario`). Your agent tests keep working unchanged.
3. None of your existing files were modified.

## Design decisions worth knowing

- **Appearance** is stored in `@AppStorage("tuber.appearance")` and applied at the app root with `.preferredColorScheme`. The toolbar and the library toggle share that key, so they stay in sync automatically.
- **Ink & paper.** The page is always white so pencil work stays legible; the light/dark toggle themes the app chrome (library, nav bars, backgrounds), not the paper. Because of that, the default `.ink` color is a fixed near-black rather than `.label`, so it never disappears on a white page in dark mode.
- **Long-press vs. drawing.** The long-press recognizer lives on the canvas with `cancelsTouchesInView = false` and simultaneous recognition, so it opens the navigator without blocking strokes. If you want a Pencil-only drawing surface (finger reserved purely for navigation), change `drawingPolicy = .anyInput` to `.pencilOnly` in `NotebookCanvas.swift`.
- **Saving** is debounced (~0.6s) while drawing and forced (`persistNow`) on page change, add/delete page, home, and view disappear.

## Notes / things you may want to tweak

- **Couldn't be compiled here** — this was written against your codebase's conventions but not built in Xcode. Expect to resolve minor issues on first build.
- **iPhone toolbar width.** The capsule hugs its content; with 11 controls it's comfortable on iPad but tight on small iPhones. If you support iPhone, consider wrapping the toolbar `HStack` in a horizontal `ScrollView` or collapsing tools behind a `Menu`.
- **Thumbnails** render each page's `PKDrawing` bounds to a `UIImage`. Fine for typical notebooks; if pages get very dense you may want to cache the images.
- **Pins.** The new page model doesn't carry `Pin`s yet. If you want the spatial `Pin` overlay on notebook pages, add `var pins: [Pin]` to `NotebookPage` (it'll need `Pin: Codable`) and drop your `PinOverlayView` into `NotebookView.pageArea`.
