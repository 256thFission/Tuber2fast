# This round — frosted polish, straighten, centered key popup

- **Removed** the constant on-canvas lasso banner.
- **Frosted assistant sidebar.** Now a matte frosted-glass panel (material +
  top-lit sheen + fine noise grain) via the new `FrostSurface`, instead of the
  thinner translucent look. Same treatment powers the key popup and page navigator.
- **Hold-to-straighten.** Draw a stroke and pause ~0.5s before lifting — it snaps
  to a straight line from where the stroke began to where you held. Works for pen,
  pencil, and highlighter (not eraser). Toggle it under the ▦ menu → "Snap to
  straight line" (on by default). Tunables live in `HoldStraightenRecognizer`
  (`holdDuration`, `moveTolerance`).
- **Centered API-key popup.** The 🔑 icon (and the "Demo mode" note) now opens a
  frosted card in the middle of the screen (`APIKeyPopup`) with Save / Remove /
  Cancel — no more inline field in the sidebar.

Note: hold-to-straighten uses a passive gesture recognizer on the PencilKit
surface; it shouldn't interfere with drawing, but the 0.5s / 8pt thresholds may
want a little tuning once you try it on-device.

---

# Latest round — lasso AI + liquid-glass UI

## Lasso for the assistant
- New **lasso** tool in the floating bar (the ⟳ loop icon). Tap it, then draw a
  loop around anything (a molecule, a diagram). While active, the page is frozen
  and one stroke marks a region with animated marching-ants.
- Open the assistant (✨). It shows a **Region selected** chip, an optional prompt
  field ("talk about this molecule"), and the button becomes **Analyze selection**.
  The snapshot is cropped to your loop before it goes to the model, so the AI
  focuses only on what you circled. Clear the chip to go back to whole-page.
- No lasso = whole page, exactly as before.

## Liquid-glass look
- The editor now sits on a near-black backdrop; the white page floats with a soft
  neutral shadow.
- Tool bar, assistant sidebar, page strip, page navigator, and popovers are all
  frosted glass (dark scheme) with a subtle top-lit edge highlight — no colored
  glows or neon shadows. The nav bar is transparent with light glyphs.
- New file `GlassStyle.swift` holds the shared `glassCapsule()` / `glassPanel()`
  helpers and the `EditorBackdrop` — restyle everything from one place.

New file this round: `GlassStyle.swift` (put it in the `Notebook/` group).

---

# Notebook feature set

Drop the `Notebook*` / `Library*` / `Page*` / `Agent*` files into your `Notebook/`
group; `TuberNotesApp.swift` replaces the one in `App/`.

## New in this round

- **Exact ink colors.** The canvas now uses a nested zoom container with the
  PencilKit view forced to `.light` interface style, so PencilKit no longer
  remaps your colors for dark mode — the stroke matches the swatch/color dot.
- **Assistant sidebar (AI).** Toggle it from the ✨ button in the nav bar. It
  captures the current page (white paper + your ink, including whatever you
  circled) and asks a vision model to describe what it sees. Uses your existing
  `SpatialSelection` boundary. Runs in **demo mode with no key**; paste an OpenAI
  key (🔑 in the sidebar) to get real analysis.
- **Zoom.** Pinch to zoom, or use the − / % / + controls in the tool bar. The
  paper and ink scale together and stay aligned.
- **Eraser sizing.** The size control now applies to the eraser too (each tool
  keeps its own width).
- **Page templates.** Plain, Lined (Large/Medium/Small), Grid (Large/Medium/Small).
  Choose per page from the ▦ menu in the nav bar, or set the starting template
  when creating a notebook. Stored per page.
- **Top page strip.** Toggle the ▤ button for a horizontal thumbnail strip to
  jump between pages quickly. It auto-scrolls to the current page.
- **Finger drawing toggle.** In the ▦ menu. Off (default) = Pencil draws, one
  finger scrolls (GoodNotes feel). On = one finger draws, two fingers scroll.

## AI setup

Default is **demo mode** — the app works with no key and returns a placeholder.
For real analysis:
1. Open a notebook → tap ✨ → tap 🔑 → paste an OpenAI API key.
2. Draw/circle something → tap **Analyze this page**.

The client (`AgentInsight.swift`) targets OpenAI's `chat/completions` vision
endpoint (`gpt-4o-mini`). **Don't ship an API key inside the app** — for anything
beyond local dev, put the key behind your own backend and point the client at it.
To swap providers (e.g. Anthropic, or your Codex agent), implement
`AgentInsightClient` and return it from `AgentClientFactory.make`.

## Platform

Targets **iPadOS/iOS 17**. Set the deployment target to 17.0 (17.x is fine).
APIs used top out at iOS 16.4 (`presentationCompactAdaptation`,
`scrollBounceBehavior`, `PKEraserTool(_:width:)`), and `onChange` uses the
two-parameter iOS-17 form. No iOS-18-only APIs are used.

Note: drawing is Pencil-only by default (see the finger-drawing toggle), so to
ink in the Simulator without a Pencil, turn on **Finger drawing** in the ▦ menu.

## Files

New: `PageTemplate.swift`, `AgentInsight.swift`, `AgentSidebarView.swift`,
`PageStripView.swift`.
Changed: `Notebook.swift`, `NotebookViewModel.swift`, `NotebookCanvas.swift`,
`NotebookToolbar.swift`, `NotebookView.swift`, `NotebookStore.swift`,
`LibraryView.swift`, `PageFlipOverlay.swift`.

## Unrelated build error you hit earlier

The "Multiple commands produce … SKILL.md / openai.yaml" errors are from your
`.codex/skills/` folders being added to **Copy Bundle Resources** (four folders,
same filenames). Remove those entries from the target's Build Phases (or uncheck
target membership for `.codex`), add `.codex/` to `.gitignore`, then Clean Build
Folder (⇧⌘K). Not related to these files.

## Caveats

- Not compiled in Xcode here — expect to shake out a minor issue on first build.
- Pins aren't drawn on notebook pages yet (the `NotebookPage` → `[Pin]` note still applies).
