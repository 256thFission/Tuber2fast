# TuberNotes — Build Week Product and Implementation Spec

Status: working specification

Target: iPad, iPadOS 17+, Apple Pencil

Primary implementation target: one-week Codex hackathon

Long-term intent: distributable application

Shared contract revision: v1, frozen July 15, 2026

TuberNotes is a spatial AI notebook for iPad.

The user circles visible work with Apple Pencil. An agent sees the selected pixels, investigates additional context when useful, and places answers back onto the page as spatially anchored Pins.

> **Point → Investigate → Point Back**

This document is both a product specification and the coordination contract for parallel agentic implementation. It defines the critical path, shared interfaces, subsystem ownership, verification evidence, and stopping conditions.

## 1. Decisions and open questions

### Confirmed

1. Magic Lasso is an explicit tool mode. The app does not infer that an ordinary ink circle is a command.
2. PDF documents and blank notebooks are both critical-path document types.
3. Documents use discrete horizontal pages rather than one continuous vertical canvas.
4. At fit-to-page zoom, a horizontal finger swipe turns the page. Above fit-to-page zoom, horizontal movement pans within the page. Previous/next controls remain available at every zoom level.
5. A blank notebook begins with branded TuberNotes dot-grid paper and supports appending additional blank pages.
6. Blank notebook pages are a separate critical-path document flow. Inserting or reordering blank pages inside an imported PDF is deferred.
7. The critical path supports a bundled demo PDF, one basic system PDF-import path, and creation of a blank notebook. A full document library is deferred.
8. The hackathon build uses a DEBUG-only direct provider adapter with locally supplied configuration. The architecture must support a distributable app without embedding a provider secret.
9. Selected pixels are the primary source of truth. OCR or extracted text may supplement but never replace an available image.
10. Persistent spatial data is never stored in screen coordinates.

### Explicitly unresolved

- Final provider and model selection
- Deployment location and authentication mechanism for the production agent gateway
- Whether Ask voice input remains a reach goal or returns to the primary demo

Changes to confirmed decisions or shared contracts require human review before implementation continues.

## 2. Product thesis

Most AI note tools move the user away from their work and into a chat box. TuberNotes keeps the interaction on the page.

The user can select:

- handwriting;
- equations;
- printed PDF content;
- diagrams;
- mixtures of ink and document content; or
- an entire worked solution.

The selected region is rendered as an image containing the same PDF background, ink, and diagrams visible to the user. The agent may inspect surrounding page context, search a preprocessed textbook, search earlier notebook pages, or use other explicitly configured tools.

The result is one or more spatial annotations attached to precise locations in the selected work.

Examples:

- “This is the key substitution.”
- “The sign error begins here.”
- “This definition comes from Chapter 7.”
- “You used this idea on page 3.”
- “These two lines contradict one another.”

The canvas is both the agent's input surface and its output surface.

## 3. Critical-path user story

The primary demo uses a multipage STEM PDF with a handwritten derivation over one page.

1. The user turns to the prepared page.
2. The user selects **Magic Lasso** in the toolbar.
3. The user circles the complete derivation with Apple Pencil.
4. The selected region glows and visually lifts from the page.
5. An action strip appears with **Explain**, **Check**, and **Ask**.
6. The user chooses **Check**.
7. The app immediately shows a truthful progress state.
8. The agent inspects the image and optionally searches the bundled textbook index.
9. Multiple Pins appear at relevant steps:
   - a subtle confirmation beside a correct step;
   - a primary Pin at the first incorrect step; and
   - optionally, a downstream Pin explaining inherited error.
10. The user taps the primary Pin and reads the explanation in place.
11. The user pans or zooms; every Pin remains attached to its page location.
12. The user turns away and back; ink and Pins remain on the correct page.

The demo's closing idea is:

> You point at your work. The agent investigates it. Then it points back.

The second critical document path starts from a new blank notebook:

1. The user creates a notebook and receives a polished dot-grid first page.
2. The user writes with Apple Pencil and can use the same Magic Lasso interaction on the ink.
3. The user appends another dot-grid page and turns between the pages horizontally.
4. Ink and Pins remain attached to their originating blank pages.

The blank notebook path proves that PDF support is a page background capability rather than the identity of the entire product.

## 4. Critical-path scope

### Required

- Ordered multipage document model
- Bundled PDF loading
- Basic PDF import through the system picker
- Blank notebook creation
- Branded dot-grid paper rendering
- Appending blank notebook pages
- Discrete page turning
- Per-page PencilKit ink
- Fit-to-page, pan, and zoom
- Explicit Magic Lasso mode
- Lasso path capture and selection rendering
- Explain, Check, and typed Ask intents
- Deterministic fake agent
- Real multimodal agent request
- One or more spatial Pins
- Pin expansion
- Per-page persistence sufficient for repeatable demos
- Bundled, preprocessed textbook search fixture
- Truthful tool/progress events
- Deterministic verification scenarios
- Cancellation, retry, and safe failure behavior

### Deferred until the hero path is reliable

- Full document library and folder organization
- Rich PDF editing or annotation compatibility
- Inserting or reordering blank pages inside an imported PDF
- Exhaustive pen tools
- Multiple windows and multi-device sync
- Production migrations
- Generalized textbook ingestion UI
- Runtime DeepSeek-OCR preprocessing on iPad
- Handwritten follow-up recognition
- Voice Ask
- Full long-press conversation UI
- Agent-drawn connectors
- Semantic Pin clustering
- Visual correction overlays
- Web research placed on canvas

Deferred features may be promoted only when the critical hero scenario passes its reliability gate.

## 5. Hero interaction contract

### 5.1 Tool modes

The canvas has an explicit input mode:

```swift
enum CanvasToolMode: Equatable {
    case ink
    case erase
    case magicLasso
    case navigate
}
```

The exact toolbar design may evolve, but the active mode must always be visible. Drawing an ordinary circle in ink mode must create ink and must not invoke the agent.

### 5.2 Magic Lasso state machine

```swift
enum LassoState: Equatable {
    case idle
    case drawing
    case selected(selectionID: UUID)
    case submitting(investigationID: UUID)
    case receiving(investigationID: UUID)
    case completed(investigationID: UUID)
    case failed(investigationID: UUID, recoverable: Bool)
}
```

Required transitions:

```text
idle
  → drawing
  → selected
  → submitting
  → receiving
  → completed
```

From `selected`, tapping outside the selection or choosing Cancel returns to `idle`. From `submitting` or `receiving`, Cancel terminates the active investigation and preserves the page. A recoverable failure offers Retry without requiring the user to redraw the lasso.

The first version may close an almost-closed Pencil path automatically. It must preserve the captured path used to construct the selection and must reject degenerate paths that contain no meaningful area.

### 5.3 Selection presentation

After a valid lasso closes:

- the selected pixels remain unchanged;
- the boundary receives a visible glow or lift treatment;
- content outside the selection may dim slightly;
- the action strip appears adjacent to the selection without obscuring its center;
- page turning, mode changes, or cancellation dismiss the action strip safely.

### 5.4 Intents

```swift
enum InvestigationIntent: Codable, Equatable, Sendable {
    case explain
    case check
    case ask(question: String)
}
```

**Explain** requests localized understanding.

**Check** requests a correctness review and prioritizes the first meaningful error.

**Ask** immediately reveals a keyboard field; submitting combines typed text with the retained selection image.

No additional mode-selection screen is allowed between lasso completion and these actions.

## 6. Document and page model

### 6.1 Document

A document is an ordered collection of stable page identities.

```swift
struct NotebookDocument: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var source: DocumentSource
    var pages: [PageRecord]
    var currentPageID: UUID?
}

enum DocumentSource: Codable, Sendable {
    case bundledPDF(resourceName: String)
    case importedPDF(bookmarkData: Data)
    case notebook(defaultPaperStyle: PaperStyle)
}

enum PaperStyle: String, Codable, Sendable {
    case plain
    case ruled
    case grid
    case tuberDotGrid
}

struct PageDimensions: Codable, Equatable, Sendable {
    let width: Double
    let height: Double

    static let tuberPortrait = PageDimensions(width: 768, height: 1024)
}

struct InkReference: Codable, Equatable, Sendable {
    let relativePath: String
}
```

Exact persistence types may change to accommodate security-scoped URLs, but callers must not use a transient file URL as document identity.

### 6.2 Page

```swift
struct PageRecord: Identifiable, Codable, Sendable {
    let id: UUID
    var index: Int
    var background: PageBackground
    var inkReference: InkReference?
    var annotations: [PageAnnotation]
}

enum PageBackground: Codable, Sendable {
    case pdf(documentID: UUID, pageIndex: Int)
    case blank(style: PaperStyle, dimensions: PageDimensions)
}
```

Each PDF page remains an immutable background. TuberNotes ink and Pins are stored as overlays and never destructively written into the source PDF during the critical path.

The default blank page uses `.tuberDotGrid` and `.tuberPortrait`. The theme should feel intentionally designed rather than like a generic graph-paper texture: warm paper, low-contrast graphite or indigo dots, generous margins, and enough restraint that Pencil ink and Pins remain dominant. Exact color and spacing values belong to the visual implementation and require human review.

A new notebook starts with one page. Appending a page creates a new stable `pageID` with the document's default paper style. Deleting, reordering, and inserting pages are deferred for the critical path.

### 6.3 Page rendering

- The active page renders at sufficient resolution for the current zoom.
- Neighboring pages may be prefetched, but only the active page requires full interactive state.
- Page identity, not array index, owns ink, Pins, selections, and investigations.
- Rotated PDF pages must render upright and use the same top-left page-normalized coordinate convention as unrotated pages.
- The visible selection renderer must composite the PDF background and ink exactly as shown.

### 6.4 Page turning and gesture precedence

1. Apple Pencil input follows the active Pencil tool and never turns pages.
2. At fit-to-page zoom, a deliberate horizontal finger swipe turns one page.
3. Above fit-to-page zoom, finger gestures pan and pinch-zoom the current page.
4. Previous/next controls provide deterministic page navigation at every zoom level.
5. An active lasso selection is cancelled before changing pages.
6. An in-flight investigation may continue after a page turn, but its results attach only to its original `pageID`.

## 7. Spatial coordinate contract

Spatial correctness is a shared product invariant owned in implementation by `SpatialCanvas`.

### 7.1 Coordinate spaces

TuberNotes uses these named spaces:

1. **PDF space** — source PDF coordinates, including PDF rotation and bottom-left conventions.
2. **Page space** — logical page coordinates after PDF rotation is resolved.
3. **Page-normalized space** — top-left origin, x and y in `0...1` over the page bounds.
4. **Crop pixel space** — pixels in the encoded selection image.
5. **Crop-normalized space** — top-left origin, x and y in `0...1` over the encoded crop bounds.
6. **Canvas space** — the scroll/zoom content coordinate system.
7. **View space** — transient on-screen points.

Only page-normalized coordinates may persist for page annotations. Crop-normalized coordinates may cross the agent boundary. Canvas and view coordinates are ephemeral.

### 7.2 Strong spatial types

Raw `CGPoint` and `CGRect` values must not cross subsystem boundaries without a named wrapper.

```swift
struct PageNormalizedPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

struct PageNormalizedRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct CropNormalizedPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

struct CropNormalizedRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
```

Decoding invalid, non-finite, or materially out-of-range model coordinates must fail validation. Tiny floating-point excursions may be clamped only at the provider-decoding boundary and must be logged as validation events.

### 7.3 Transform invariant

For a stable page point `p`, the following must remain true across pan, zoom, rotation handling, and page reuse:

```text
pageNormalizedToView(p, viewportA)
    → viewport changes
pageNormalizedToView(p, viewportB)
```

The projected view point changes, but the stored `p` does not.

Crop output maps through the selection geometry:

```text
crop-normalized target
    → crop pixel target
    → page-space target
    → page-normalized target
    → persisted PageAnnotation
```

The model never receives or returns screen coordinates.

## 8. Selection artifact contract

`SpatialCanvas` produces an immutable selection artifact for the agent boundary.

```swift
struct SelectionArtifact: Identifiable, Sendable {
    let id: UUID
    let documentID: UUID
    let pageID: UUID
    let pageIndex: Int
    let lassoPath: [PageNormalizedPoint]
    let pageBounds: PageNormalizedRect
    let crop: SelectionCrop
    let context: SelectionContext
}

struct SelectionCrop: Sendable {
    let imageData: Data
    let mediaType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let pageBounds: PageNormalizedRect
}

struct SelectionContext: Codable, Sendable {
    var documentTitle: String?
    var sourceDocumentID: UUID?
    var pageNumber: Int?
    var nearbyText: String?
}
```

Requirements:

- `imageData` contains the PDF background, current visible ink, and other user-visible page content.
- The crop is an axis-aligned image corresponding exactly to `pageBounds`.
- Pixels inside the lasso remain visually exact.
- Pixels inside the crop but outside the lasso are visually de-emphasized so the model can distinguish the intended selection while retaining local layout.
- Crop-normalized coordinates refer to the complete encoded image, not the lasso polygon's internal bounding shape.
- The artifact remains valid for Retry even if the viewport changes.
- Nearby text is optional supplementary context and must not replace the image.

## 9. Pin and annotation contract

A Pin is a persistent page annotation derived from an agent target.

```swift
struct PageAnnotation: Codable, Identifiable, Sendable {
    let id: UUID
    let pageID: UUID
    let threadID: UUID
    var target: PageNormalizedPoint
    var targetRegion: PageNormalizedRect?
    var kind: AnnotationKind
    var teaser: String
    var body: String
    var citations: [Citation]
    var status: AnnotationStatus
}

struct Citation: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var pageNumber: Int?
    var url: URL?
    var excerpt: String?
}

enum AnnotationKind: String, Codable, Sendable {
    case confirmation
    case issue
    case explanation
    case source
    case uncertainty
    case suggestion
}

enum AnnotationStatus: String, Codable, Sendable {
    case streaming
    case complete
    case failed
}
```

The agent first produces a crop-relative draft:

```swift
struct PinDraft: Codable, Identifiable, Sendable {
    let id: UUID
    var target: CropNormalizedPoint
    var targetRegion: CropNormalizedRect?
    var kind: AnnotationKind
    var teaser: String
    var body: String
    var citations: [Citation]
}
```

`App` coordinates conversion of validated `PinDraft` values through `SpatialCanvas` geometry into `PageAnnotation` values. `AgentHarness` does not render Pins and `Pins` does not interpret crop coordinates.

### Pin behavior

- Collapsed Pins show a marker and concise teaser.
- Tapping expands the explanation in place.
- Streaming content may update an expanded Pin without moving its target.
- Pins remain attached across pan, zoom, page turns, relaunch, and view reuse.
- Multiple Pins must avoid making their targets ambiguous. Labels may move or collapse; target anchors may not.
- Citations display source title and page or URL when available.
- Full conversation Thread UI is deferred, but every Pin retains `threadID` for forward compatibility.

## 10. Agent runtime and gateway

Development agents, Codex skills, MCP tools, and Xcode tooling are not the agent shipped inside TuberNotes. Product runtime uses only explicitly implemented application interfaces.

### 10.1 Security boundary

The distributable app must not contain a reusable provider API secret.

```text
iPad app
   → authenticated TuberNotes Agent Gateway
   → model provider Responses API
```

For the hackathon, a DEBUG-only direct provider adapter will be used. Its credential is supplied locally at runtime and never committed, logged, included in fixtures, or compiled into a distributable build. Release builds must use the gateway interface.

“ChatGPT/Codex OAuth” is not an implementation assumption. Authentication will be specified against the chosen gateway when that service is selected.

### 10.2 Harness interface

```swift
protocol AgentClient: Sendable {
    func investigate(_ request: InvestigationRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(investigationID: UUID) async
}

struct InvestigationRequest: Identifiable, Sendable {
    let id: UUID
    let intent: InvestigationIntent
    let selection: SelectionArtifact
    let conversationID: String?
}
```

### 10.3 Events

```swift
enum AgentEvent: Sendable {
    case accepted
    case inspectingSelection
    case toolStarted(ToolInvocationSummary)
    case toolFinished(ToolInvocationSummary)
    case pinStarted(PinDraft)
    case pinDelta(id: UUID, bodyDelta: String)
    case pinCompleted(PinDraft)
    case completed(conversationID: String?)
    case failed(AgentFailure)
}

enum ProductToolName: String, Codable, Sendable {
    case searchTextbook = "search_textbook"
    case placePins = "place_pins"
}

struct ToolInvocationSummary: Codable, Identifiable, Sendable {
    let id: UUID
    let tool: ProductToolName
    let userVisibleStatus: String
}

struct AgentFailure: Error, Codable, Sendable {
    enum Code: String, Codable, Sendable {
        case unavailable
        case unauthorized
        case timedOut
        case invalidResponse
        case cancelled
    }

    let code: Code
    let userMessage: String
    let recoverable: Bool
}
```

Events expose observable activity and high-level progress, not hidden chain-of-thought. Tool summaries contain only user-safe names such as “Checking the textbook…” or “Comparing earlier notes…”.

### 10.4 Tools

Critical-path tools:

- `search_textbook`
- `place_pins`

Supported by local context without a model tool call:

- selection image inspection through the request itself;
- current document and page identity; and
- optional nearby text.

Deferred tools:

- `search_notebook`
- `web_search`
- connectors or external workspace search

`place_pins` uses a strict structured schema. Provider output is untrusted until decoded, bounds-checked, associated with the active selection, and converted to page-normalized annotations.

### 10.5 Failure behavior

- Network failure preserves the selection and offers Retry.
- Retrieval failure does not prevent a vision-only answer when the model can continue honestly.
- Invalid Pin coordinates reject the affected Pin rather than corrupting page state.
- Cancellation stops new events; already completed Pins may remain only if the user has seen them.
- Late events for an inactive or mismatched investigation ID are ignored and logged.
- Provider diagnostics must not expose secrets or selected page content in normal console logs.

## 11. Knowledge architecture

There are two intentionally different paths.

### 11.1 Live understanding

```text
Magic Lasso → rendered selection image → multimodal model
```

There is no OCR prerequisite for a lasso. The model sees handwriting, equations, diagrams, layout, PDF material, and mixtures of these.

### 11.2 Important-document preprocessing

```text
PDF/textbook
    → offline OCR/layout preprocessing
    → structured searchable artifact
    → bundled or imported knowledge source
```

DeepSeek-OCR is a candidate preprocessing implementation, not a runtime requirement or a shared contract. The hackathon critical path may use a checked-in, preprocessed fixture produced by any suitable offline process.

```swift
protocol KnowledgeSearching: Sendable {
    func searchTextbook(_ query: KnowledgeQuery) async throws -> [KnowledgeHit]
}

struct KnowledgeQuery: Codable, Sendable {
    let documentID: UUID?
    let text: String
    let limit: Int
}

struct KnowledgeHit: Codable, Identifiable, Sendable {
    let id: UUID
    let documentID: UUID
    let documentTitle: String
    let pageNumber: Int
    let sectionTitle: String?
    let excerpt: String
    let score: Double?
}
```

The demo corpus must preserve document identity and page numbers so citations can return the user to the correct PDF page.

Initial retrieval may be lexical or hybrid. Retrieval sophistication is not a milestone unless it improves the fixed demo queries.

## 12. Persistence contract

Persistence exists to make the hero demo repeatable, not to implement a production document database.

The app must persist:

- imported document identity and access information;
- ordered stable page IDs;
- current page;
- per-page PencilKit drawing data;
- completed PageAnnotations;
- annotation-to-thread identifiers; and
- sufficient investigation metadata to render existing Pins after relaunch.

The app need not persist:

- an in-flight provider stream after process termination;
- raw selected crops after an investigation completes;
- provider secrets;
- full source-tool traces; or
- generalized schema migrations.

Raw selection images should be treated as transient user content. Any retention beyond the active investigation requires an explicit later product decision.

## 13. Shared contracts and change control

Shared contract revision v1 is frozen in coordinator-owned files under `TuberNotes/App/Contracts/`. The runtime boundary protocols remain in their owning subsystem directories and compile only against these shared types.

The initial frozen contracts are:

- document and page identity;
- named normalized spatial types;
- `SelectionArtifact`;
- `CanvasToolMode` and `LassoState`;
- `InvestigationIntent` and `InvestigationRequest`;
- `AgentClient` and `AgentEvent`;
- `PinDraft` and `PageAnnotation`;
- `KnowledgeSearching`, `KnowledgeQuery`, and `KnowledgeHit`; and
- deterministic scenario identifiers.

Parallel threads may implement against these contracts but may not silently modify them. A requested contract change must include:

1. the blocking use case;
2. the smallest proposed change;
3. affected modules and fixtures;
4. migration or compatibility impact; and
5. a human/coordinator decision.

## 14. Parallel work packages

These are work threads, not additional runtime agents or permission domains. After contract freeze they can proceed independently. `App` integration and final product judgment remain with the coordinating agent.

### WP1 — SpatialCanvas: paged spatial surface

**Owns**

- PDF page rendering
- page viewport and page turning mechanics
- PencilKit ink per page
- explicit Magic Lasso input capture
- selection crop compositing
- all coordinate transforms
- projection of page-normalized anchors into the current view

**Consumes**

- `NotebookDocument`
- `PageRecord`
- deterministic PDF and Pencil fixtures

**Produces**

- `SelectionArtifact`
- page viewport state
- pure crop-to-page and page-to-view transform operations

**Non-goals**

- agent calls
- Pin visual design
- document library UI
- OCR

**Demoable-alone bar**

Load a known multipage PDF, turn pages, draw on two different pages, lasso mixed PDF and ink, inspect the deterministic crop, and project a fake page-normalized target without drift through zoom, pan, page turn, and return. Separately, load a deterministic two-page dot-grid notebook fixture, draw on both blank pages, and verify page-specific state. Notebook creation and append commands remain coordinator-owned App integration behavior.

**Required evidence**

- build pass
- coordinate round-trip checks
- crop fixture artifact
- `pdf-pages` scenario
- `blank-notebook` scenario
- `notebook-pages` scenario
- `lasso-crop` scenario
- `pin-drift` scenario before and after viewport changes
- human Pencil review for lasso feel

**Stop** when the demoable-alone bar passes or a shared contract change is required.

### WP2 — Pins: spatial annotation experience

**Owns**

- Pin marker and teaser design
- expansion/collapse
- streaming body presentation
- citation presentation
- label positioning and collision policy
- selection and accessibility behavior

**Consumes**

- `[PageAnnotation]`
- projected target positions supplied by the spatial surface
- deterministic Pin fixtures

**Produces**

- user-visible Pin overlay events such as expand and dismiss

**Non-goals**

- crop coordinate conversion
- model output decoding
- page navigation
- retrieval

**Demoable-alone bar**

Render one, several, and edge-positioned canned Pins; expand each Pin; stream a canned body; show a citation; keep targets unambiguous without clipping primary content.

**Required evidence**

- build pass
- `fake-pin`, `multi-pin`, and `edge-pins` scenarios
- deterministic target positions
- no primary clipping or catastrophic overlap
- human visual review after mechanical checks

**Stop** when the demoable-alone bar passes or a shared contract change is required.

### WP3 — AgentHarness: multimodal investigation loop

**Owns**

- gateway client
- DEBUG direct provider adapter
- multimodal request construction
- tool loop orchestration
- structured `place_pins` decoding
- streaming event translation
- cancellation, timeouts, and provider error mapping

**Consumes**

- `InvestigationRequest`
- `KnowledgeSearching`
- provider/gateway configuration
- recorded provider fixtures

**Produces**

- `AsyncThrowingStream<AgentEvent, Error>`

**Non-goals**

- rendering Pins
- coordinate conversion into page space
- storing provider credentials in source or app assets
- implementing OCR

**Demoable-alone bar**

Given a fixed selection image and intent, a recorded adapter produces a deterministic truthful event sequence and valid PinDraft values. A separately gated live smoke test produces at least one relevant, valid PinDraft from the real provider.

**Required evidence**

- recorded success, retrieval, invalid-coordinate, cancellation, and network-failure fixtures
- strict schema validation
- secret scan of changed files and artifacts
- one live smoke artifact with user content redacted from logs

**Stop** when recorded cases and the live smoke test pass, or gateway/auth requires an external decision.

### WP4 — Knowledge: demo textbook retrieval

**Owns**

- preprocessed corpus format
- corpus loader
- textbook query implementation
- document/page-aware results
- deterministic retrieval fixtures

**Consumes**

- a known demo PDF
- a checked-in or generated offline index

**Produces**

- `[KnowledgeHit]`

**Non-goals**

- OCR every live lasso
- generalized import pipeline
- notebook-wide search
- web search

**Demoable-alone bar**

Known queries from the primary demo return the expected document, page, section, and supporting excerpt. A missing query returns an empty result without inventing a citation.

**Required evidence**

- fixed query fixture set
- expected page assertions
- malformed/missing index failure case
- compact query result artifact

**Stop** when all fixed demo queries pass or the source corpus is unavailable.

### WP5 — DeveloperSupport and DeveloperTools: verification surface

**Owns**

- deterministic scenario selection
- fake document, selection, agent-event, Pin, and retrieval fixtures
- build/install/launch/screenshot automation
- mechanical assertions and compact evidence artifacts
- human-device request plumbing

**Consumes**

- frozen scenario names and fixture schemas
- module demoable-alone bars

**Produces**

- repeatable scenarios and evidence directories

**Non-goals**

- product runtime behavior
- visual taste judgments
- model-provider logic

**Demoable-alone bar**

Each required scenario launches deterministically, identifies its expected state, captures artifacts, reports crash status, and can be invoked independently by another work thread.

**Required evidence**

- scenario help output
- one passing artifact bundle per fixture family
- one intentionally failing mechanical assertion proving failure reporting

**Stop** when all currently required scenarios are callable and produce compact evidence.

### Coordinator-owned App integration

The coordinating agent owns:

- shared contract creation and approval;
- root composition and dependency injection;
- document/session state machine;
- conversion of agent drafts into persisted annotations;
- integration order;
- architecture decisions;
- final diff and evidence judgment; and
- the primary demo.

App integration begins with fakes immediately and replaces them with module implementations as their demoable-alone bars pass.

## 15. Integration sequence

```text
Contract freeze
    ├── WP1 SpatialCanvas
    ├── WP2 Pins
    ├── WP3 AgentHarness
    ├── WP4 Knowledge
    └── WP5 Verification

SpatialCanvas + Pins + fake agent
    → M0 paged spatial illusion

SpatialCanvas + Pins + recorded agent
    → M1 deterministic point-back loop

Real AgentHarness
    → M2 live multimodal point-back loop

Knowledge tool
    → M3 agent investigation

Reliability and human review
    → M4 demo candidate
```

Work packages may land in any order after contract freeze. Integration accepts only outputs that meet their package evidence bar.

## 16. Milestones and acceptance gates

### M0 — Paged spatial illusion

```text
PDF or blank notebook → turn page → draw → fake Pin → zoom/pan → turn away/back
```

Pass when:

- at least three PDF pages render and turn correctly;
- a new notebook renders the TuberNotes dot-grid first page and can append a second page;
- horizontal page turning works for both PDF and blank notebook documents;
- ink stays on its originating page;
- a fake page-normalized Pin remains attached through viewport changes;
- returning to the page restores the same ink and Pin; and
- deterministic scenarios show no crash, clipping of primary UI, or Pin drift.

No model or retrieval is required.

### M1 — Deterministic point-back loop

```text
Magic Lasso → rendered crop → recorded agent events → real Pin UI
```

Pass when:

- the crop includes visible PDF and ink;
- Explain, Check, and typed Ask produce the correct request intent;
- recorded AgentEvents drive truthful progress states;
- valid crop-relative drafts become page-normalized annotations;
- Retry works without redrawing the lasso; and
- cancellation and invalid output do not corrupt page state.

### M2 — Live multimodal point-back loop

```text
Magic Lasso → real provider → place_pins → page annotations
```

Pass when:

- the primary demo selection produces at least one semantically relevant localized Pin;
- all returned coordinates validate;
- no provider secret is present in source, fixtures, logs, or a Release build;
- a provider failure is recoverable; and
- the primary live scenario succeeds repeatedly on the demo device.

Retrieval is not required.

### M3 — Agent investigation

```text
lasso → agent requests textbook context → search → grounded Pins
```

Pass when:

- the fixed demo query invokes textbook search only when useful;
- progress truthfully indicates textbook activity;
- the returned citation identifies the correct document and page;
- a retrieval miss degrades honestly to vision-only output or uncertainty; and
- the result returns to the original selected page location.

### M4 — Demo candidate

Pass when:

- all deterministic hero scenarios pass;
- the complete hero path succeeds on the actual demo device in three consecutive runs;
- no crash or secret exposure is observed;
- mechanical spatial checks pass after pan, zoom, page turn, and return;
- a human has reviewed Pencil feel, visual taste, and interaction timing; and
- remaining issues are documented as non-critical or explicitly accepted.

## 17. Deterministic scenario contract

Existing scenarios remain valid during migration:

- `blank-canvas`
- `fake-pin`
- `multi-pin`

Required new scenarios:

- `pdf-pages` — known multipage PDF at a deterministic page
- `blank-notebook` — new notebook on the branded dot-grid first page
- `notebook-pages` — distinct canned drawings on two appended blank pages
- `ink-pages` — distinct canned drawings on two pages
- `lasso-crop` — known PDF + ink selection with inspectable crop artifact
- `pin-drift` — known anchor before and after deterministic viewport changes
- `edge-pins` — multiple Pins near all page edges
- `agent-recorded-success` — complete recorded event sequence
- `agent-recorded-retrieval` — recorded textbook tool sequence
- `agent-recorded-failure` — recoverable provider failure
- `hero-recorded` — deterministic end-to-end Check interaction

Scenario names and expected states are shared contracts. `Docs/Development.md` must be updated when a scenario becomes runnable, not before.

## 18. Verification rules

Compilation is necessary but insufficient for user-visible work.

Each package handoff includes:

- objective and files changed;
- short scoped diff summary;
- canonical build result;
- scenarios run and expected state;
- screenshot, crop, fixture, or query artifact paths;
- crash and console status;
- mechanical checks performed;
- human-only checks remaining or collected; and
- stop reason or unresolved contract request.

### Mechanical spatial checks

- Named coordinate values are finite and validated.
- Pure page-normalized → page-space → page-normalized round trips differ by no more than `1e-6` per axis.
- Crop corners map to the corresponding page bounds within one crop pixel.
- After a viewport transition settles, a known Pin anchor differs from its expected projected location by no more than two screen points.
- Pin anchors do not change when their label layout changes.
- Pin anchors remain deterministic across page reuse and relaunch.
- No Pin result attaches to a page or investigation other than its originating IDs.

### Reliability checks

- No immediate crash or silent exit
- Cancellation is idempotent
- Late events cannot mutate inactive investigations
- Missing PDF/index/provider state produces an actionable failure
- Deterministic scenarios do not depend on network access
- Live provider tests are separately labeled and never used as the only acceptance evidence

### Initial interaction budgets

Measure these on the physical demo iPad. They are local UI budgets, not provider service-level guarantees.

- A valid completed lasso reveals its action strip within 200 ms.
- Tapping Explain, Check, or submitting Ask changes the visible state within 100 ms.
- Selection crop rendering completes within 500 ms for the primary demo region.
- A prefetched adjacent PDF page becomes visible within 250 ms of a page-turn action.
- A newly appended blank page becomes visible within 250 ms of the append action.
- A slow provider never blocks drawing, page navigation, cancellation, or reading existing Pins.

### Human-only checks

- Apple Pencil latency and lasso feel on physical iPad
- Selection glow and lift quality
- Pin legibility and animation taste
- Gesture conflict between page turning, pan/zoom, and lasso
- Perceived latency of the live hero interaction

Use the repo human-device loop so verdicts and notes become durable artifacts.

## 19. Scaffold migration plan

The current source tree is a disposable integration scaffold, not an architecture to preserve at all costs.

### Retain and extend

- canonical Xcode project and scheme;
- subsystem directory ownership;
- `DevelopmentScenario` launch routing;
- verification script and evidence packet pattern;
- human-device request banner and Pencil fixture storage; and
- the rule that persistent Pin positions are normalized to the page.

### Rewrite behind frozen contracts

- `App/RootView.swift` into dependency-injected document/session composition;
- `SpatialCanvas/PencilCanvas.swift` for per-page drawing lifecycle and explicit input modes;
- `SpatialCanvas/SpatialCanvasView.swift` for PDF page viewport, turning, lasso, and transforms;
- `Pins/Pin.swift` into the shared `PageAnnotation` representation or a view model derived from it;
- `Pins/PinOverlayView.swift` to consume projected page annotations;
- `AgentHarness/AgentClient.swift` into the streaming gateway boundary; and
- `Knowledge/KnowledgeSearching.swift` into document/page-aware retrieval.

### Preserve unless a concrete blocker appears

- DEBUG human-device loop types and storage;
- project bundle identity;
- canonical simulator configuration; and
- evidence templates.

Do not perform a broad rewrite in one change. Each replacement must enter through a bounded work package, compile against frozen contracts, and prove its demoable-alone bar before integration.

## 20. Reach backlog

After M4, prioritize by demo impact and leverage:

### Tier 1

- Multi-Pin teacher markup refinement
- “Find my first mistake” specialization
- Agent-drawn connectors

### Tier 2

- Search earlier notebook pages
- Handwritten follow-up on the canvas
- Voice Ask
- Richer live professor progress

### Tier 3

- Visual correction overlays
- Web research placed on the canvas
- Semantic zoom and Pin clustering
- Full persistent conversation Thread UI

No reach item may weaken page stability, spatial correctness, provider security, or hero reliability.

## 21. Product principles

1. **Vision-native:** the model sees the same visual work the user sees.
2. **Spatial output:** answers belong on the work, not in a detached chatbot.
3. **Stable page identity:** ink, selections, and annotations belong to pages, not views.
4. **Multiple insights, multiple Pins:** one selection may contain several meaningful targets.
5. **Agentic when useful:** tool use is purposeful and visible at a safe level.
6. **Runtime/tooling separation:** Codex development tools never become implicit product capabilities.
7. **Hackathon-first:** build the smallest version that proves the interaction.
8. **Distributable boundary:** prototype shortcuts may not embed reusable secrets or prevent a later gateway.
9. **Robust enough to demo:** the complete hero path must work repeatedly on the actual iPad.

## 22. Success criterion

A judge should understand the product after watching one interaction:

> A person turns to a page in a PDF, circles visible work with Apple Pencil, and asks the AI to check it. The agent sees the exact work, investigates the relevant source, and places useful responses at the exact locations they refer to.

The desired reaction is not:

> “That is a note app with an AI chat feature.”

It is:

> “The agent can actually see and inhabit the page with you.”
