# Notebook gallery + pages + tool bar

Product-facing feature set added on top of your existing spatial-canvas app.
Drop the eight `Notebook*` / `LibraryView` / `PageFlipOverlay` files into a new
`Notebook/` group, and replace `App/TuberNotesApp.swift` with the one here.

## What's in it

- **Gallery** (`LibraryView.swift`) — grid of notebook covers saved locally. Create, rename, delete.
- **Local persistence** (`NotebookStore.swift`) — one JSON file per notebook in `Documents/Notebooks/`, same `Codable` + `FileManager` style as `PenFixtureStore`. Drawings stored as serialized `PKDrawing` per page.
- **GoodNotes-style vertical pages** (`NotebookCanvas.swift`) — each page is a fixed portrait sheet (`NotebookPageLayout.size`, ~Letter ratio) with ruled lines + a margin line drawn *inside* the scrolling canvas. Drawings are stored in fixed page-space, so they're device-independent (thumbnails/exports stay consistent).
- **Page flipping** — long-press the page for the navigator (arrows, swipe, thumbnails), **plus dedicated back/forward buttons in the menu bar**.
- **Thin menu bar** (`NotebookToolbar.swift`) — home · page back/forward · pen / pencil / highlighter / eraser · color · size · add page · page indicator.
- **Standard color picking** — tap the color dot for a 16-swatch palette **and** a system `ColorPicker` for any custom color.
- **Pen & highlighter resizing** — the size button opens a slider with a live preview. Each tool keeps its **own** width (pen, pencil, highlighter are independent).

## Folder placement (matches your feature-based layout)

Create one new group `Notebook/` alongside `Pins/`, `SpatialCanvas/`, etc.:

```
Notebook/
  Notebook.swift
  NotebookStore.swift
  NotebookViewModel.swift
  NotebookCanvas.swift
  NotebookToolbar.swift
  PageFlipOverlay.swift
  LibraryView.swift
  NotebookView.swift
App/
  TuberNotesApp.swift   ← replaces the existing one
```

`README-notebooks.md` is not a source file — keep it out of the target.

## Input model — important

The page uses `drawingPolicy = .pencilOnly`, which is what makes the GoodNotes
feel work: **Apple Pencil draws, a single finger scrolls/pans the tall page.**
If you need finger drawing (e.g. testing in the Simulator with no Pencil), change
one line in `NotebookCanvas.swift` to `.anyInput` — but note that with `.anyInput`
a single finger draws instead of scrolling, so a tall page becomes harder to
navigate by touch.

## Light/dark

Removed, per request. The page is always white paper with your chosen ink color;
the app otherwise follows the system appearance for its chrome.

## Design notes

- Saving is debounced (~0.6s) while drawing, forced on page change / add / delete / home / disappear.
- Highlighter renders at 40% alpha so it reads as a highlight over ink.
- Agent harness preserved: `TuberNotesApp` still shows your existing `RootView(scenario:)` when launched with `TUBER_SCENARIO` / `TUBER_RECORD_PEN_FIXTURE` / `TUBER_PEN_FIXTURE` / `--scenario`; normal launches open the gallery.

## Caveats

- **Not compiled in Xcode here** — written to your conventions but expect to shake out a minor issue on first build.
- **iPhone toolbar width**: the bar hugs its content; with page-nav + tools + color + size it's comfortable on iPad but tight on small iPhones. If you ship iPhone, wrap the toolbar `HStack` in a horizontal `ScrollView` or fold tools behind a `Menu`.
- **Pins** aren't on notebook pages yet; the README's earlier note on adding `var pins: [Pin]` to `NotebookPage` still applies.
