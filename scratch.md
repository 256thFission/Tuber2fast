Original (misguided, assumes a custom metal engine we don't have):
# Feature Parity Roadmap: Building an Open-Source iOS Alternative to GoodNotes & Notability

## TL;DR
- **The core note-taking experience (pens, erasers, lasso, paper templates, PDF annotation, pagination, undo/redo, palm rejection) is achievable mostly with UI/interaction and algorithmic work you likely already have** — but three signature capabilities create the real moat: **Notability's audio-synced-to-ink recording**, **handwriting-to-text + math recognition** (both apps rely on MyScript; GoodNotes also runs proprietary on-device ML), and **GoodNotes' organization/search + AI layer**. Budget your effort around those.
- **Apple frameworks accelerate the periphery, not the core.** PencilKit gives free low-latency ink, a tool picker, and Apple Pencil hover/double-tap/squeeze plumbing, but its drawing engine is a "walled garden" — since you already have a performant custom engine, you should keep it and adopt only the Pencil interaction APIs, Vision (image OCR), PDFKit (with known pitfalls), and Files/Shortcuts/WidgetKit. There is **no Apple API that turns live Apple Pencil ink into text**; you must license MyScript or use Google ML Kit.
- **Recommended sequencing:** (1) ship the writing/erasing/selection/paper/PDF/undo core with iCloud sync; (2) add the "delighters" that are cheap and high-impact (zoom-window writing, shape recognition, Apple Pencil double-tap/squeeze, presentation/laser mode); (3) tackle the expensive differentiators (handwriting search/OCR, audio-sync, math) last, buying rather than building recognition.

## Key Findings

**1. Feature parity splits into three tiers of difficulty.** The bulk of what users touch daily — writing tools, erasers, lasso select/move/resize/rotate, color palettes, pressure/opacity, paper types, pagination vs. infinite canvas, PDF import/annotation/export, undo/redo, and multi-touch gestures — is UI and algorithmic work. Because you already have a performant canvas engine and an extensible gesture system, most of Tier 1 is within reach without heavy ML or third-party dependencies.

**2. The signature/differentiating features are where the engineering cost concentrates.** Notability's audio recording time-synced to every stroke is its unique moat and has "no real equivalent anywhere else." GoodNotes' differentiators are its deep organization (nested folders, notebook/tab UI), universal handwriting search, on-device AI handwriting (Spellcheck in your own writing, "Ask Goodnotes"), math conversion, an infinite Whiteboard, and a stationery Marketplace. For context on the incumbent's scale: Goodnotes is "the leading digital note-taking app used by over 25 million monthly active users worldwide" and "was named Apple's 2022 iPad App of the Year." Handwriting-to-text and math recognition are common to both but require licensing an engine.

**3. Apple frameworks help selectively.** PencilKit/PKCanvasView deliver Apple's own low-latency ink and tool picker in a few lines of code, but the drawing engine is not customizable for performance-critical or novel-feature work — hence your custom engine is the right call. The valuable, low-cost wins from Apple's stack are the Apple Pencil interaction APIs (`UIPencilInteraction` for double-tap and Pencil Pro squeeze; hover pose), PDFKit for PDF rendering/annotation, Vision for image OCR, and system integration (Files, Shortcuts/Siri, WidgetKit).

**4. Recognition is a build-vs-buy decision that you should resolve as "buy."** Apple's Vision framework only reliably recognizes machine-printed text in images, not handwriting, and there is no public API to convert live Apple Pencil ink strokes to text. Apple's Scribble cannot be used on a drawing canvas (it competes with the canvas for Pencil input and exposes no recognized-text API). The realistic options are **MyScript iink SDK** (what Notability licenses; best-in-class, on-device, does math→LaTeX) or **Google ML Kit Digital Ink Recognition** (free, on-device, stroke-based, 300+ languages, but no math).

## Details

### A. Comprehensive Feature/Tool Inventory

Columns: **Difficulty** (Low / Medium / High / Very High engineering effort), **Impact** (Core = central to note-taking, High, Medium, Nice-to-have), **Who has it**, and **Apple framework / build notes**.

#### Tier 1 — Writing & Marking Tools

| Feature | Description | Difficulty | Impact | Who | Framework / Notes |
|---|---|---|---|---|---|
| Ballpoint/fountain/pen ink | Pressure- and tilt-responsive vector ink; fountain pen varies width by speed/pressure | Medium (you have engine) | Core | Both | Custom engine (yours). PencilKit offers `.pen`/`.fountainPen` free but limits customization |
| Pencil tool | Textured graphite look with pressure shading | Medium | High | Both | Custom; texture brush |
| Highlighter | Translucent ink that sits behind text, single-layer (no darkening on overlap) | Low–Medium | Core | Both | Custom; render as multiply/behind-ink layer. Note both apps deliberately avoid stacking opacity |
| Pressure sensitivity + toggle | Map Pencil force to width; allow disabling | Low | High | Both | `UITouch.force`; already in your engine |
| Apple Pencil Pro squeeze / barrel roll / hover | Squeeze opens tool palette; roll rotates chisel tools; hover previews touchdown | Low–Medium | Medium | Notability (squeeze/hover); GoodNotes (palette) | `UIPencilInteraction`, hover pose APIs, roll angle on gesture recognizers |
| Apple Pencil double-tap tool switching | Double-tap to swap pen/eraser or last tool | Low | High | Both | `UIPencilInteraction` double-tap delegate |
| Color picker + palettes / presets | HEX/dropper/wheel; save favorite colors (Notability 64 color slots + 8 fast custom; GoodNotes preset slots) | Low | Core | Both | `UIColorPickerViewController` or custom |
| Opacity / line-style settings | Dashed/dotted lines, tip sharpness | Low | Medium | Both | Custom stroke styling |

#### Tier 2 — Erasers & Selection

| Feature | Description | Difficulty | Impact | Who | Framework / Notes |
|---|---|---|---|---|---|
| Stroke eraser | Deletes whole strokes on contact | Low–Medium | Core | Both | Hit-testing against vector strokes |
| Pixel/partial eraser | Erases part of a stroke within radius | Medium–High | Core | Both | Vector path splitting or raster masking; nontrivial with vectors |
| Object eraser / selective erase | Erase highlighter-only, or by ink type | Medium | Medium | Both (limited) | Filter by stroke metadata. Users actively request more granularity (erase pen-only, pencil-only, single-color) |
| Scribble-to-erase gesture | Scratch-out motion auto-deletes | Medium | High | Both | You already have this in your gesture system — good competitive parity move |
| Auto-deselect / sticky-tool behavior | Tool reverts after one use vs. stays active | Low | Medium | Both | Interaction state machine |
| Lasso select (freehand + rectangular) | Select ink/objects to move/resize/rotate/recolor/delete | Medium–High | Core | Both | Polygon hit-testing; affine transforms |
| Circle-to-select / lasso from pen | Draw a circle with the pen, long-press to convert to selection | Medium | Medium | GoodNotes | Extends your gesture system |
| Convert selection to text/element; group ink | Turn ink into a movable/scalable object | Medium | Medium | Both | Grouping model in data layer |

#### Tier 3 — Navigation, Paper & Structure

| Feature | Description | Difficulty | Impact | Who | Framework / Notes |
|---|---|---|---|---|---|
| Zoom / pan canvas | Pinch-zoom, two-finger pan, palm rejection | Medium | Core | Both | Custom; palm rejection via `UITouch.type` |
| **Zoom Window / writing assist** | Magnified write box with auto-advance across the page and auto-line-wrap; adjustable return height | High | High | Both (Notability considered best) | Custom; the auto-advance logic is the hard part and a signature convenience |
| Paged vs. infinite canvas | Fixed pages (Notability/GoodNotes notebooks) vs. infinite Whiteboard (GoodNotes) | Medium (paged) / High (infinite) | Core (paged) | Both paged; GoodNotes infinite Whiteboard | Tiling/virtualization for infinite; watch memory |
| Paper types (blank/lined/grid/dot/Cornell) | Built-in templates | Low | Core | Both | Render programmatically or as PDF/image backgrounds |
| Custom templates / import PDF or image as paper | Use any PDF/PNG as page background; multi-size | Medium | High | Both | PDFKit render; GoodNotes supports pages up to 5000 pt (176 cm) wide |
| Custom page sizes/colors, covers | Fully custom dimensions, colored paper, notebook covers | Medium | Medium | GoodNotes (strongest) | Custom |
| Templates marketplace | In-app store of stationery/stickers/planners | High | Nice-to-have | GoodNotes (built-in); Notability (Gallery) | Backend + commerce; defer for open-source |

#### Tier 4 — Text, Shapes & Assistive Tools

| Feature | Description | Difficulty | Impact | Who | Framework / Notes |
|---|---|---|---|---|---|
| Typed text boxes | Movable/resizable text with fonts, lists, styling | Medium | Core | Both | `UITextView`/TextKit; text flows around media in Notability |
| Full-page text document mode | Word-processor-style typing (GoodNotes Text Doc / block editor) | Medium–High | Medium | GoodNotes; Notability (limited) | TextKit; block model |
| Shape recognition ("draw & hold") | Rough shape snaps to perfect line/curve/oval/polygon | Medium | High | Both | Geometric fitting; part of your gesture system |
| Ruler tool | Straight edges, angle measurement | Low–Medium | Medium | Both | Custom; constrain strokes to ruler line |
| Tape / masking tool | Highlight-block / washi-tape decoration | Low | Nice-to-have | GoodNotes | Custom |
| Laser pointer (dot + fading trail, colors) | Temporary on-screen pointer for presenting, leaves no marks | Low–Medium | Medium | Both | Custom overlay; fade animation |
| Sticky notes | Repositionable note objects | Low | Nice-to-have | Both | Object model |
| Image/photo import, crop, camera scan | Insert and mark up images; document scanning | Medium | High | Both | `VisionKit` `VNDocumentCameraViewController` for scanning |

#### Tier 5 — Import / Export / PDF

| Feature | Description | Difficulty | Impact | Who | Framework / Notes |
|---|---|---|---|---|---|
| PDF import & annotation | Import PDF, write/highlight over it, select PDF text | Medium–High | Core | Both (Notability rated best for PDF markup) | PDFKit renders; but PDFKit ink annotations have documented zoom/memory bugs and scaling issues — many apps put a custom canvas over each page instead of using `PDFAnnotation` |
| PDF export (flattened + with annotations) | Export page/notebook to PDF | Medium | Core | Both | PDFKit or custom PDF writer |
| Image export (PNG/JPEG) | Export note as image | Low | High | Both | Core Graphics |
| Multi-format import (Word, PPT, images) | Convert to annotatable pages | Medium–High | Medium | GoodNotes (with layout caveats) | Conversion pipeline; layout fidelity is hard |

#### Tier 6 — Organization, Sync & Sharing

| Feature | Description | Difficulty | Impact | Who | Framework / Notes |
|---|---|---|---|---|---|
| Notebooks / folders / subjects / dividers | Library structure; GoodNotes nested folders + tabs; Notability subjects/dividers sidebar | Medium | Core | Both | Data model + UI |
| Tags, favorites/bookmarks | Cross-cutting organization | Low–Medium | Medium | Both | Data model |
| Universal search (titles, typed, PDF text) | Search across library | Medium | High | Both | Index typed/PDF text; Core Spotlight optional |
| **Handwriting search (OCR)** | Find handwritten words across all notes | High | High | Both (GoodNotes OCR across 17 languages, strong) | Requires recognizer (MyScript/ML Kit) + index; not free from Apple |
| iCloud sync + third-party backup | Sync across devices; auto-backup to Dropbox/Drive/OneDrive | High | Core | Both | CloudKit / iCloud Drive; conflict resolution is the hard part |
| Real-time collaboration | Multiple editors, live cursors | Very High | Medium | GoodNotes ("Up to 50 participants can collaborate in real time at once… There is no overall limit on total document participants"; Live Cursor "turns on automatically when a Goodnotes Pro subscriber opens the shared document"); Notability limited | CRDT/OT sync engine; major effort — defer |
| Share link / read-only sharing | Public/invite links | Medium–High | Medium | GoodNotes | Backend |
| Presentation mode | Mirror to external display, hide toolbars, laser pointer, hide slide-over apps | Medium | Medium | Both | `UIScreen`/AirPlay external display APIs |

#### Tier 7 — Signature / Differentiating Features

| Feature | Description | Difficulty | Impact | Who | Framework / Notes |
|---|---|---|---|---|---|
| **Audio recording synced to ink (Notability's signature)** | Records audio; every stroke/typed char timestamped so tapping a note jumps to that moment; playback replays note being written; import audio; merge/trim; voice boost | High | High (defining feature) | Notability | `AVFoundation` for capture; the sync model (timestamp every stroke, seekable playback) is custom and the core value |
| Live transcription + AI "Smart Notes"/summaries/quizzes/flashcards | Real-time transcript, AI study tools | Very High | Medium | Notability (Learn); GoodNotes (Ask Goodnotes) | `SFSpeechRecognizer` + LLM backend; heavy, defer or make optional |
| **Handwriting-to-text conversion** | Convert selected ink to typed text | High | High | Both | License MyScript or use ML Kit; not available from Apple for ink |
| **Math equation recognition/solving** | Handwritten equations → LaTeX/typed; GoodNotes AI Math Assistance flags errors; Notability → scalable image, LaTeX-editable | Very High | Medium (High for STEM) | Both (via MyScript); GoodNotes adds solving | MyScript Math (250 symbols → LaTeX/MathML) is effectively the only licensable engine; Apple Math Notes is not a public API |
| On-device AI handwriting (Spellcheck in own hand, word complete, "Ask your notes") | Corrects handwriting in user's style; semantic Q&A over notes | Very High | Medium | GoodNotes (proprietary on-device ML) | Custom ML; runs on Neural Engine; very large effort. Note GoodNotes itself pruned features here (see Caveats) |
| Infinite Whiteboard | Unbounded canvas for mind-maps/diagrams | High | Medium | GoodNotes | Custom infinite canvas |
| Study tools: flashcards + spaced repetition | Generate/review flashcards from notes | Medium–High | Medium | Both (GoodNotes Study Sets; Notability Flashcards) | Data + SRS algorithm |
| Layers | Separate drawing layers | Medium | Nice-to-have (not a core GoodNotes/Notability feature) | Neither prominently | Custom compositing |

#### Tier 8 — System Integration & Accessibility

| Feature | Difficulty | Impact | Who | Framework / Notes |
|---|---|---|---|---|
| Undo/redo (buttons + two-finger/three-finger gestures) | Low | Core | Both | `UndoManager`; gesture recognizers |
| Palm rejection / multi-touch gestures | Medium | Core | Both | `UITouch.type` to distinguish Pencil vs. finger |
| Files app integration | Medium | High | Both | `UIDocumentBrowserViewController` / File Provider |
| Shortcuts / Siri | Medium | Medium | Notability (note reminders, quick note/record) | App Intents / SiriKit |
| Widgets (home/lock screen quick note/record) | Medium | Medium | Notability | WidgetKit |
| Handwriting-to-text via Scribble in text fields | Low | Nice-to-have | System-wide | `UIScribbleInteraction` (text fields only, not canvas) |
| Accessibility (VoiceOver, Dynamic Type, high-contrast) | Medium | High (and ethical/legal) | Both (Notability strong on Dynamic Type + screen-reader labels) | UIKit accessibility APIs; label everything |
| Apple Watch / other device support | Medium–High | Nice-to-have | Limited | Defer; iOS-only per your scope |
| Note locking (password/FaceID) | Low–Medium | Medium | Both | LocalAuthentication |
| Dark mode / smart ink recoloring | Medium | Medium | Both | Recolor ink without changing paper |

### B. Apple Frameworks: Accelerate vs. Build Custom

**Adopt from Apple (low cost, high leverage):**
- **`UIPencilInteraction`** — double-tap and Apple Pencil Pro squeeze events, plus hover pose (location, azimuth, altitude, roll). Available even without PencilKit. This is the correct, cheap way to get Pencil Pro parity. Note: if the user sets squeeze to "run a shortcut" system-wide, your app won't receive the squeeze event.
- **PDFKit** — for rendering/paging PDFs and reading embedded text. But treat its annotation layer with caution (see below).
- **Vision (`VNRecognizeTextRequest` / iOS 18 `RecognizeTextRequest` / `RecognizeDocumentsRequest`)** — good for OCR of imported images/scanned PDFs and Live Text-style selection; the iOS 18 document API recognizes text in 26 languages and can detect tables, lists, and machine-readable codes. Not for live ink.
- **VisionKit** — `VNDocumentCameraViewController` for document scanning; Live Text.
- **AVFoundation / SFSpeechRecognizer** — audio capture and (optional) on-device transcription.
- **WidgetKit, App Intents/SiriKit, File Provider, CloudKit, LocalAuthentication, UIKit accessibility.**

**Keep custom (Apple can't meet the bar):**
- **The ink engine.** PencilKit is a "walled garden … when it comes to the actual drawing engine"; for advanced features Apple itself points developers to Metal or Core Graphics. Since you have a performant engine, keep it and layer only the interaction APIs on top.
- **Zoom-window auto-advance, custom erasers, shape/gesture system, infinite canvas, audio-ink sync** — all custom.
- **PDF annotation:** PDFKit's `PDFAnnotation` ink has documented problems — memory spikes and crashes when zooming with several ink annotations, and annotation-content shrinking on repeated saves (a regression around iPadOS 17.2, largely fixed in 17.4). Apple's PencilKit team's own recommendation is to put a `PKCanvasView` over each PDF page rather than use ink `PDFAnnotation`s. For your app, the robust path is to render the PDF with PDFKit and overlay your own canvas per page, exporting flattened output — this matches how serious annotation apps work around PDFKit.

### C. Build-vs-Buy: Handwriting & Math Recognition (the pivotal decision)

This is the single thinnest area in "just use Apple," so here is the sourced assessment:

- **Apple Vision does not do handwriting reliably.** It is "limited to printed text in clear fonts — don't expect to be able to throw raw handwriting at it and get useful results." It operates on a rasterized image, not live vector ink, so it has no stroke order/timing. The iOS 18 Swift Vision API and `RecognizeDocumentsRequest` are still image/document OCR (tables, lists, QR, contacts), not ink recognizers.
- **Scribble is unusable on a note canvas.** Per an Apple engineer: "Both Scribble and the PKCanvasView would compete to get the pencil events and draw strokes. You can control if you want to let the user draw on the canvas view, or have their writing transcribed by Scribble, but not both at the same time … there is no API to access that drawing." Scribble is for text-field entry only. PencilKit does give you full stroke access via `PKDrawing` (iOS 14+), which you then feed to your own recognizer.
- **MyScript iink SDK** is what Notability licenses — MyScript's official blog (Oct 2021) states plainly: "you may not know that MyScript provides the tech that drives Notability's superb handwriting recognition… From November 1, 2021, Notability developer Ginger Labs will offer the app for free." It runs on-device (native SDK); MyScript's own materials say iink "recognizes handwriting in 72 languages and language variants" and "recognises 250 mathematical symbols," exporting math "to specialized formats such as MathML and LaTeX." (MyScript's consumer app, MyScript Notes, advertises 66 languages and "copy math as LaTeX or image" — the 72-language figure is the SDK/education number.) The current SDK generation is transformer-based (iink 3.x). **Pricing is quote-based/custom** (per-run-time-license packs for native; usage tiers for Cloud with the first 2,000 requests/month free and ~$10 per 1,000 thereafter) — confirm 2025-2026 figures directly with MyScript, as public prices are gated.
- **Google ML Kit Digital Ink Recognition** is a strong free alternative for text: free, unlimited, fully on-device/offline, stroke-based (takes an `Ink` object of strokes with touch-point timing — a natural fit for your PKStroke-style data). Per Google's Developers Blog it "supports 300+ languages and 25+ writing systems," and per VentureBeat "recognition time is about 100 milliseconds, depending on the device hardware and the size of the input stroke sequence." **But it has no math/LaTeX engine** (text, shapes, gestures, emoji only).
- **Math specifically:** MyScript Math is effectively the only turnkey licensable engine (exports LaTeX/MathML). Apple's iOS 18 Math Notes solves handwritten equations but is an end-user feature with **no public developer API**. LaTeX is the de-facto interchange/rendering format (Notability lets you edit the underlying LaTeX; render via KaTeX/MathJax).

**Recommendation:** Capture ink with your own engine (own the strokes), use **ML Kit Digital Ink (free)** as the baseline handwriting-to-text/search recognizer, and **license MyScript** if/when you need best-in-class accuracy and, especially, **math** conversion. Do not architect around Apple for ink recognition.

## Recommendations

**Stage 1 — Ship the credible core (parity table stakes).** Pens (ballpoint/fountain/pencil/highlighter), stroke + pixel + object erasers, freehand/rectangular lasso with move/resize/rotate/recolor, color palettes with presets, pressure toggle, paged notebooks with blank/lined/grid/dot templates plus custom PDF/image paper import, zoom/pan with palm rejection, undo/redo with two-/three-finger gestures, typed text boxes, PDF import/annotate (custom canvas over PDFKit pages) and PDF/PNG export, notebook/folder/subject organization, universal search over typed/PDF text, iCloud sync, note locking. Adopt `UIPencilInteraction` double-tap early — it's cheap and expected. *Benchmark to advance:* stable multi-hundred-page notebooks with <16 ms stroke latency and reliable sync-conflict handling.

**Stage 2 — Cheap, high-visibility delighters.** Zoom-Window writing with auto-advance (high perceived value), shape recognition ("draw & hold"), ruler, laser pointer + presentation/external-display mode, image insert + document scan (`VisionKit`), Apple Pencil Pro squeeze/hover, dark-mode ink recoloring, Files app + Shortcuts + a quick-note/record Widget, and full accessibility (VoiceOver labels, Dynamic Type). *Benchmark:* these are mostly interaction work reusing your gesture system; ship as a fast follow.

**Stage 3 — The differentiators, bought not built where possible.** (a) Handwriting search/OCR and handwriting-to-text via **ML Kit (free)** first, MyScript if accuracy demands; (b) **audio recording synced to ink** — the highest-ROI unique feature for the Notability audience, built on AVFoundation with your own stroke-timestamp model; (c) **math conversion** via MyScript (LaTeX output, render with KaTeX). Treat real-time collaboration, AI summaries/"ask your notes," on-device handwriting-style Spellcheck, infinite whiteboard, and a stationery marketplace as **later or optional** — each is Very High effort and none is table-stakes for a first competitive release.

**Thresholds that change the plan:** If your target users are primarily students recording lectures, promote audio-sync into Stage 1/2. If they're STEM users, promote MyScript math earlier. If you can't secure acceptable MyScript licensing terms for an open-source/free app, ship ML Kit for text and defer math rather than blocking the release. If real-time collaboration becomes a top request, budget a dedicated CRDT-based sync effort — do not bolt it onto iCloud sync.

## Caveats
- **Marketing vs. shipped reality:** Several GoodNotes 6 "AI" capabilities (Ask Goodnotes, audio transcription, math assistance) are recent and evolving; GoodNotes discontinued its Word Complete experimental feature — per its own support docs, "Word Complete was discontinued on March 31st, 2025. After evaluating user feedback and testing, we're focusing our efforts on other features that have proven more valuable to our users, such as Goodnotes AI, Audio Transcription, and Lasso Edit." Even the incumbent prunes AI features; treat AI parity as a moving target, not a fixed spec.
- **Recognition pricing is not public.** MyScript native SDK per-license costs are quote-only; the pack structure cited is from older MyScript materials. Get a current quote before committing, and note MyScript is an independent company (a stability consideration for a long-lived open-source project).
- **PDFKit annotation bugs are real and version-dependent** (zoom/memory crashes, save-scaling regressions). Validate on current iPadOS and prefer the overlay-canvas architecture.
- **Difficulty/impact ratings are relative judgments** for a team that already has a performant engine and gesture system; they will shift with your specific data model and target audience.
- **Scope is iOS-only per your brief**; cross-platform (GoodNotes' Windows/Android/Web) and Apple Watch are explicitly out of scope and were rated Nice-to-have accordingly.
- Some competitor specifics (e.g., exact color-slot counts, collaboration participant limits, language counts) come from vendor support docs and reviewer testing and may change with app updates.
Ammendment:
# PencilKit as a Note-App Foundation: How Far It Can Be Pushed Toward GoodNotes/Notability Parity

## TL;DR
- The previous report's claim is **half right but materially overstated**: PencilKit's *stroke-rendering engine* (the exact pixels an ink lays down — brush textures, pressure curves, blend modes) genuinely is a closed "walled garden" you cannot customize, but its *data model* (PKDrawing/PKStroke/PKStrokePath/PKStrokePoint) is fully open and manipulable, so lasso transforms, object/partial erasers, custom tool pickers, infinite/paged canvases, high-frequency Pencil Pro input, and PDF annotation are all achievable **without** dropping to Metal.
- Since you have already achieved high performance on PencilKit, you should **stay on it** and build your advanced features on top of the data-model and interaction APIs; the only features that hit a true hard wall are (1) genuinely new ink *looks*/brush physics/textures beyond Apple's built-in inks, (2) custom pixel-blend/eraser effects like blur, and (3) sub-frame rendering control finer than Apple exposes — all of which require your own Metal/Core Graphics layer *alongside* PencilKit, not instead of it.
- The correct architecture for PDF is still **one PKCanvasView overlay per PDFPage via `PDFPageOverlayViewProvider`**, but budget for well-documented zoom/blur/coordinate-sync bugs; and note that iOS 18 (custom tool-picker items, Pencil Pro roll/squeeze/haptics), iOS 26 (PaperKit), and iOS 27 (stable stroke IDs, programmatic selection, programmatic erasing, substroke slicing) have each moved the hard wall meaningfully outward.

## Key Findings

**1. Custom ink types / brush rendering — HARD WALL (with a large workaround).** You cannot register a new `PKInkingTool.InkType` or supply your own brush shader, texture, or pressure curve. Ink types are limited to Apple's built-ins. Apple's own PencilKit documentation (`PKContentVersion.version2`) enumerates the full set: "inks from iPadOS 17 and earlier, including marker, pen, pencil, monoline, fountain pen, watercolor, and crayon" — where pen/pencil/marker date to iOS 13 and monoline/fountainPen/watercolor/crayon were added in iOS 17. As Wesley Matlock's write-up "Customizing PencilKit: Going Past Apple's Tool Picker" states plainly: "We can't add textures or modify pressure curves, but we can simulate different brush effects" (by layering pen/pencil/marker with alpha). When a developer asked Apple directly about a custom 3D-feel fountain pen, Apple DTS pointed only to the tool-picker config APIs and said to file an enhancement request if those "don't provide enough." Even stroke width is clamped (`.pen` maxes at ~25.66 pt regardless of the value you pass). **However**, iOS 18's `PKToolPickerCustomItem` lets you register a fully custom tool in Apple's picker where *your app does the rendering* — but note the key constraint stated in WWDC24 session 10214: "Drawing is turned off on any observing PKCanvasView when a custom tool item is selected." So a true custom brush means rendering that tool's strokes yourself (Metal/Core Graphics) on a layer over/under PKCanvasView, while PencilKit continues to own its native inks.

**2. Raw stroke data access — FULLY OPEN since iOS 14.** As an Apple Frameworks Engineer put it on the developer forums: "New in PencilKit on iOS 14 is full access to the underlying strokes in a canvas via PKDrawing, which you can process through a handwriting recognition engine." The model has been programmatically inspectable, modifiable, and constructible since iOS 14 (WWDC20 session 10148, "Inspect, modify, and construct PencilKit drawings"). You get `PKDrawing.strokes → [PKStroke]`, each `PKStroke` exposing `ink` (type+color), `transform` (CGAffineTransform), `mask` (partial-erase clip), `renderBounds`, and `path` (a `PKStrokePath` — a uniform cubic B-spline). Each `PKStrokePoint` carries location, size, opacity, force, azimuth, altitude, and timeOffset. You can interpolate the spline with `interpolatedPoints(strideBy:)` and construct strokes/drawings from scratch. This is the single most important fact overturning the "walled garden" framing: for a recognition pipeline, custom lasso, or export, you have everything. The one gap: you cannot read the *in-progress* stroke before the pencil lifts (Apple confirmed this is not exposed and suggested an enhancement request).

**3. Lasso select / move / resize / rotate — ACHIEVABLE on PencilKit.** Because each PKStroke has a mutable `transform` and you can rebuild a `PKDrawing` from a filtered/transformed stroke array, developers have shipped custom lasso tools using point-in-polygon tests on stroke points, then applying a CGAffineTransform to selected strokes (documented in a Let'Swift 2022 conference talk implementing exactly this). PencilKit also ships `PKLassoTool` for the built-in behavior. iOS 27 makes this dramatically cleaner: `PKStroke`/`PKStrokePath` gain `Identifiable` (stable UUID surviving edits/undo), you can now **programmatically control selection state on PKCanvasView**, and there's a new `canvasViewSelectionDidChange` delegate callback (all per WWDC26 session 203, "Read between the strokes with PencilKit").

**4. Erasers — bitmap + vector built in; partial/object erasing programmable in iOS 27.** `PKEraserTool` offers `.vector` (whole-stroke/object erase), `.bitmap` (pixel erase), and `.fixedWidthBitmap` (iOS 16.4+); eraser width is settable only on iOS 16.4+. Custom eraser *effects* (blur, pixelate) are a hard wall — as Matlock reports, "PencilKit doesn't support custom erasers. You get bitmap and vector, that's it." Critically for you: iOS 27 adds **programmatic erasing** — per WWDC26 session 203, "you provide a PKStrokePath as the eraser. It cuts through the drawing, slicing a single stroke into multiple independent strokes with their own mask, just as if the user had used the eraser tool on the canvas" (Apple warns this "can be expensive on complex drawings," so do it off the main thread). This enables a custom scribble-to-erase gesture that drives real PencilKit erasing.

**5. Serialize / merge / split — FULLY SUPPORTED.** `PKDrawing.dataRepresentation()` round-trips losslessly (it's `Codable`; store in SwiftData/Core Data/files). `PKDrawing(strokes:)` and `appending(_:)` merge/split drawings trivially. iOS 27 adds **substroke extraction** (parametric subscript ranges on PKStroke/PKStrokePath) for precise splitting while preserving ink particle consistency, and lossless **Bézier ↔ PKStrokePath conversion** (so a Bézier-based canvas can feed PencilKit recognition). The one real export gap: rendering a PKDrawing to PDF/image via `image(from:scale:)` rasterizes — there is **no built-in vector PDF export**, a long-standing developer complaint on the Apple forums.

**6. Performance characteristics — genuinely good, with two documented cliffs.** PencilKit renders in Metal internally, is low-latency by design, and, per Matlock, "handles most of the heavy lifting." But: (a) a developer profiled **100–165% CPU spikes for ~3 seconds on canvases with >5,000 strokes**, traced to `CoreHandwriting` running background handwriting recognition on every stroke-end — you cannot disable it via public API. (b) PKCanvasView zoom is capped at `maximumZoomScale` 10, and there are multiple open rendering bugs at non-1× zoom (blurry strokes, and an Apple-confirmed **internal tile-rendering flicker when drawing at non-1× zoom**, filed as FB22063128, which Apple engineering said is "occurring within PKCanvasView's internal tile rendering ... rather than being caused by anything in your app code").

**7. High-frequency Pencil Pro input — PencilKit consumes it natively; raw access is via UIKit.** PencilKit ingests high-rate samples and, on iOS 18 with Pencil Pro, natively maps barrel-roll (`rollAngle`) to the marker and fountainPen tools and shows hover shadows (WWDC24 session 10214). For raw high-frequency data you use UIKit's coalesced touches plus predicted touches. Per Kodeco's Apple Pencil tutorial citing Apple: "the iPad Pro scans for a touch at 120 times per second, but when the Pencil is near the screen the scan rate doubles to 240 times per second," versus a default UIKit delivery of ~60 Hz (which itself rises to the display's animation rate — an Apple Frameworks Engineer noted "if there is 120 Hz animation occurring, your app will receive touches at 120 Hz"). You'd only wire coalesced/predicted touches into your *own* renderer, not PKCanvasView (which already handles them).

**8. Real-world precedent — the flagships built their own engines; PencilKit powers Apple's apps and smaller apps.** GoodNotes, Notability, and Procreate all run **proprietary** engines, which is the strongest evidence that outgrowing PencilKit is a real pattern — but each did so for reasons PencilKit has since narrowed. GoodNotes uses a proprietary vector ink engine; its own support page states: "Scribble does not use Goodnotes' own ink engine, but instead uses Apple PencilKit, which is also found in other apps like Apple's Notes" — i.e., it touches PencilKit only for system Scribble text entry, not its drawing canvas. Notability uses a bespoke Bézier vector engine; its engineering blog ("Notability object selection: adventures in vector graphics") states "objects in Notability documents use a vector representation ... use Bézier curves as their primitives," and "Notability's partial eraser leverages our ink's vector representation to allow restyling of objects as logical units" (Notability had "over 30 million users" as of January 2023 per Ginger Labs). Procreate uses its own Metal raster engine: per "Meet Procreate 4" (2017), "Built entirely with Metal, our new painting engine – Silica M – allows for incredible new effects," and the original Silica shipped with "Procreate 1.0 ... in 2011" — 8 years before PencilKit (2019). By contrast, PencilKit is primarily used by Apple's own Notes and Freeform, by PaperKit-based apps, and by numerous third-party note apps (e.g., CollaNote, at least historically, before it moved partly to its own vector ink).

## Details

### Is "PencilKit is a walled garden requiring a fully custom Metal implementation" accurate?
It conflates two very different layers. **The rendering engine** — how an ink converts stroke geometry + pressure/tilt/roll into pixels, including textures, grain, wet-ink blending, and pressure response — is closed. You get Apple's seven inks and their looks, full stop. In that narrow sense "walled garden" is fair, and this is exactly why Procreate (raster paint fidelity), and to a lesser degree GoodNotes/Notability (restyleable vector ink, custom brush pens), built their own engines.

But **the data model and interaction surface** are open and, since iOS 18/26/27, increasingly rich. The previous report's conclusion — that performance and advanced features *require* a fully custom Metal engine — is not correct for a note-taking app. You have already disproved the performance half empirically. On the feature half: lasso transforms, object and (iOS 27) partial/programmatic erasing, custom tool pickers, custom gesture systems, multi-page and infinite canvases, PDF annotation, handwriting recognition, and Pencil Pro input are all reachable on PencilKit. The accurate statement is: **"PencilKit's ink-rasterization engine is closed; everything around it is open. Keep PencilKit for its low-latency native inks and add a thin custom Metal/Core Graphics layer only for ink looks and pixel effects Apple doesn't provide."**

### Revised architecture guidance for PDFKit + PencilKit
The per-page overlay remains correct and is now Apple's officially demonstrated pattern (WWDC22 "What's new in PDFKit," session 10089): implement `PDFPageOverlayViewProvider`, return a `PKCanvasView` per `PDFPage` keyed in a `page → canvasView` dictionary, and persist each page's `PKDrawing` in `willEndDisplayingOverlayView`. Do **not** try to stuff a PKDrawing into a `PDFAnnotation` — developers report document corruption ("X watermark") and deprecated-API round-trips. Concrete pitfalls to budget for, all from developer reports:
- **Touch vs. scroll conflict**: overlays don't receive touches unless you disable `usePageViewController` and set the document *after* wiring the overlay provider.
- **Zoom/resolution**: strokes drawn at 1× go blurry when the PDF is zoomed, because the overlay's `contentScaleFactor` isn't re-rendered with PDF scale; Apple engineers at WWDC24 could not give a working fix for one reported case, and the Documents app itself shows the bug on older iOS. You must sync `contentScaleFactor`/zoom between the PDFView's scroll view and each canvas.
- **Non-1× flicker** (FB22063128, Apple-confirmed internal tile-rendering bug).
- **Memory with many pages**: instantiate/tear down canvases lazily per visible page (the dictionary-provider pattern does this); don't hold a live PKCanvasView for every page of a large PDF.

### What requires dropping to a custom renderer vs. staying on PencilKit
| Feature | Stay on PencilKit? | How / caveat |
|---|---|---|
| Lasso select-move-resize-rotate | ✅ Yes | Transform PKStrokes + rebuild PKDrawing; native in iOS 27 via selection API + stable IDs |
| Object (whole-stroke) eraser | ✅ Yes | `PKEraserTool(.vector)` |
| Pixel/partial eraser | ✅ Yes | `.bitmap`/`.fixedWidthBitmap`; iOS 27 adds programmatic path-based slicing |
| Scribble-to-erase gesture | ✅ Yes | Recognize gesture from PKStroke data → apply programmatic erase (iOS 27) or remove strokes |
| Infinite / paged canvas | ✅ Yes | PKCanvasView is a UIScrollView; huge contentSize (e.g. 1,000,000²) pattern is proven (simonbs/InfiniteCanvas) |
| Zoom-window ("writing assist") | ⚠️ Mostly | Achievable but fights the zoom-blur/flicker bugs; test heavily |
| Custom tool in Apple's picker | ✅ Yes (iOS 18+) | `PKToolPickerCustomItem`; but *you* render that tool's output |
| Pencil Pro roll/squeeze/haptics | ✅ Yes (iOS 18+) | Native for marker/fountainPen; `UIPencilInteraction` + `rollAngle` for custom |
| Custom brush look / texture / physics | ❌ No | Requires your own Metal/CG layer |
| Custom blend modes / blur eraser | ❌ No | Requires your own Metal/CG layer |
| Vector PDF export | ❌ No | PencilKit rasterizes; build your own vector export from PKStroke geometry |
| Disabling background handwriting-recognition CPU | ❌ No | No public API; a real cost at >5k strokes/canvas |

### Can PencilKit feed your extensible gesture system?
Yes, but respect one hard rule repeatedly reported by developers: **do not add custom gesture recognizers directly to PKCanvasView** — they conflict with its internal `drawingGestureRecognizer` and can cause a black screen during drawing (Matlock: "Don't add gesture recognizers directly to the canvas view — they'll conflict with PencilKit's internal drawing gestures and cause a black screen during drawing"). Instead: (a) read completed strokes via `canvasViewDrawingDidChange` and analyze the last PKStroke's points for gesture patterns (e.g., a tight back-and-forth scribble → trigger erase); (b) attach recognizers to a *sibling/overlay* view or a parent, not the canvas itself; (c) for truly custom input capture you can use `PKToolPickerCustomItem` (drawing is disabled on the canvas while your tool is active, freeing you to interpret touches) or a separate transparent UITouch-handling view. iOS 27's programmatic erasing + stable stroke IDs make a scribble-to-erase gesture a first-class, reliable operation rather than a hack.

## Recommendations

**Stage 1 — Stay on PencilKit and harden what you have (now).** Keep PKCanvasView as your canvas. Adopt `PKToolPickerCustomItem` (iOS 18+) for your custom tools and `UIPencilInteraction` for Pencil Pro squeeze/double-tap. Build lasso and gesture logic from PKStroke data read via the delegate — never by adding recognizers to the canvas. Persist via `dataRepresentation()`. **Benchmark now:** measure CPU on a 5,000+ stroke page; if the `CoreHandwriting` spike is a real UX problem for your users, that's your first signal to consider a hybrid.

**Stage 2 — Add a thin custom layer only where PencilKit has a hard wall (as needed).** If and only if you need custom brush looks, textures, true fountain-pen physics, blend modes, blur erasers, or vector PDF export, add a Metal/Core Graphics layer *for those specific inks/effects* over or under PKCanvasView — a hybrid, not a rewrite. Render your custom-tool strokes there while PencilKit keeps its native inks. Use UIKit coalesced + predicted touches (up to 240 Hz on Pencil-near-screen) in that layer.

**Stage 3 — Target iOS 27 APIs for advanced editing (when you can raise your OS floor).** Programmatic erasing (path-based slicing), substroke extraction, stable Identifiable stroke IDs, and programmatic canvas selection turn your hardest features (partial erase, precise lasso, scribble-erase, stroke-order animation) into supported operations. Gate them with `@available` and keep the manual PKStroke-rebuild path as the fallback for iOS 16–18.

**Thresholds that would change the plan:** (1) If profiling shows PencilKit's rendering or the handwriting-recognition CPU spike blocks your target device/frame budget at your expected stroke counts, move the *canvas* to custom Metal. (2) If custom ink fidelity (not just tool picking) becomes a core differentiator — i.e., you're competing with Procreate/GoodNotes on brush feel — plan a custom engine. (3) If your minimum OS can be iOS 26+, adopt PaperKit for shapes/text/image markup rather than rebuilding it. Below those thresholds, PencilKit is the right foundation.

## Caveats
- **Version naming:** The major new drawing-model APIs (stable stroke IDs, programmatic selection/erasing, substroke slicing, Bézier conversion, `PKStrokeRecognizer`) are **iOS 27 (2026)**, per Apple's WWDC26 session 203. **iOS 26 (2025)** introduced **PaperKit** (a higher-level markup framework on top of PencilKit), not those stroke APIs. Confirm exact symbol names (e.g., a `selectedStrokes` property, `renderState`/`PKStrokeReference`) against shipping Xcode 27 headers — the WWDC transcript confirms the capabilities and names `canvasViewSelectionDidChange` and `renderGroupID`, but some symbol names in secondary sources are unverified.
- Several performance/bug claims (>5k-stroke CPU spike, non-1× flicker FB22063128, zoom blur, 10× zoom cap) come from Apple Developer Forums threads — credible and often Apple-acknowledged, but they are individual reports; validate against your own device matrix.
- The GoodNotes/Notability/Procreate "own engine" facts are from vendor channels and are reliable, but they describe *why those apps left/avoided* PencilKit historically; PencilKit in iOS 18/26/27 is more capable than when those decisions were made, so they are not a reason for *you* to avoid it given your existing performance.
- CollaNote's PencilKit usage rests on a third-party aggregator plus a review noting a later partial move to its own vector ink — treat as low-confidence.