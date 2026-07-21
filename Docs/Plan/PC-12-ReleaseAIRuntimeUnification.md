# PC-12 — Release AI runtime unification and interaction hardening

Status: **in progress — P0 normal Release lasso-to-guidance-Pins path implemented; manual gate pending**

Target branch: `main`

Owners: `AgentHarness` owns authentication, capability routing, provider
transport, response limits, and provider-error redaction. `Notebook` coordinates
user intent, request lifecycle, and document persistence. `SpatialCanvas` owns
lasso/crop geometry. `Pins` owns Pin presentation and spatial interaction.
`Knowledge` owns local retrieval. `App` wires these boundaries together.

## Objective

Patch the normal Release app's AI features into one coherent runtime without
reviving the stale Debug/scenario harness. Temporary OpenAI login, lasso-driven
structured guidance Pins, page/selection analysis, and future local textbook
search must share one request-scoped authorization and routing boundary while
retaining their existing domain-specific outputs.

The finished Release experience should have:

- one temporary sign-in state and one model selection for every live AI action;
- no Notebook-owned bearer headers, endpoints, account identifiers, or raw
  provider errors;
- request cancellation and generation checks so sign-out/relogin cannot commit
  stale AI output;
- honest signed-out, empty-input, working, retry, cancel, and unsupported states;
- a hero sparkle-lasso that never generates a raster or changes source ink;
- a deliberate promotion path for `search_textbook` without creating a second
  parallel agent stack.

## Audited Release surface map

| Surface | Current Release path | Current gap | Target |
|---|---|---|---|
| Temporary OpenAI access | `OpenAICodexLoginSession` → `AgentRuntimeAccess.openAICodex` | Tokens and route preparation are still visible across multiple clients; memory-only relog is intentional | Session vends opaque capability routes/snapshots; all clients use the same transport |
| Page/selection analysis | `AgentSidebarView` → `NotebookViewModel.analyzeCurrentPage` → `OpenAICodexVisionClient` → one `PageAnnotation` | Notebook builds Codex requests; task is untracked; late success can persist after sign-out | Central transport, retained/cancellable operation, generation-current check before persistence |
| Pin follow-up | Pin selects a parent; the same insight request embeds parent text and creates one child annotation | It is not a streamed provider conversation and has no provider conversation ID | Preserve this small path first; migrate only when structured Pins have a normal consumer |
| Drawing refinement | Historical PC-11 raster experiment | Private route rejected image generation, and raster replacement is not the intended hero | Retired from the normal Release sparkle-lasso; a separately configured backend remains an independent future seam |
| Structured agent/`place_pins` | Sparkle-lasso → crop vision → strict `PinDraft` decoding → page-normalized `PageAnnotation` | P0 is implemented and awaiting Phillip's manual provider/placement verdict | Keep this as the normal Release hero and extend it with retrieval only after acceptance |
| `search_textbook` | Contract and recorded tool events; `OfflineTextbookKnowledgeSearcher` exists | Searcher has no live call site or model tool loop | App injects Knowledge-owned local search into the future structured agent loop |
| `search_notebook` | Deferred in `SPEC.md` | No product implementation | Keep deferred; do not imply availability |

DeveloperSupport, DeveloperTools, fixture MCPs, recorded scenarios, Debug API-key
UI, and Codex development tooling are not product-runtime AI and are excluded.

## Target internal architecture

Introduce an opaque request route inside `AgentHarness`:

```swift
enum AgentCapability: Sendable {
    case insight
    case structuredPins
}

struct AgentResponseRoute: Sendable {
    let model: String
    let wireAPI: AgentProvider.WireAPI
    // Endpoint and authorization material remain private to AgentHarness.
}

extension AgentRuntimeAccess {
    func route(for capability: AgentCapability) throws -> AgentResponseRoute
}
```

Add `OpenAICodexResponsesTransport` as the only temporary-Codex request sender.
It accepts an opaque route plus an already bounded JSON body, uses the current
ephemeral session policy, attaches authorization/account/originator/request
headers privately, bounds streamed or complete responses by capability, maps
401/403 to generation-scoped unauthorized, and never exposes provider bodies.

`OpenAICodexLoginSession` should vend a runtime snapshot and answer whether its
generation is still current. Access tokens and account IDs become private to
`AgentHarness`. A request captures one snapshot at the user tap and never
re-reads login or model preferences mid-flight.

Capability-specific code remains separate:

- insight builds its prompt and parses bounded text into `AgentInsight`;
- structured Pins translate only validated provider events into `PinDraft`;
- Notebook alone maps results to `PageAnnotation` and persists them;
- Knowledge alone executes local textbook search;
- SpatialCanvas alone maps crop-normalized geometry to page coordinates.

## Implementation sequence

### Phase 1 — Centralize temporary OpenAI authorization and transport (P0)

Files:

- `TuberNotes/AgentHarness/OpenAICodexLoginSession.swift`
- `TuberNotes/AgentHarness/AgentClient.swift`
- new `TuberNotes/AgentHarness/OpenAICodexResponsesTransport.swift`
- `TuberNotes/Notebook/AgentInsight.swift`
- `TuberNotes.xcodeproj/project.pbxproj`

Work:

1. Add `AgentCapability`, opaque `AgentResponseRoute`, runtime snapshot minting,
   and generation-current queries.
2. Restrict token/account/endpoint/header visibility to `AgentHarness`.
3. Move ephemeral session construction, shared headers, bounded accumulation,
   status mapping, generation-scoped invalidation, and provider-error redaction
   into `OpenAICodexResponsesTransport`.
4. Migrate insight and structured guidance Pins to the transport without
   changing spatial inputs or persisted output contracts.
5. Preserve memory-only/no-refresh login semantics.

`CONTRACT:` this changes the internal `AgentRuntimeAccess` handoff and adds
`AgentResponseRoute`; it does not change persisted documents, Pins, coordinates,
archives, or the external production-gateway requirement.

Manual Release gate: sign in once, analyze content, refine a lasso, sign out,
and confirm both actions return to the same sign-in-required state. No raw HTTP,
backend-endpoint, token, account, or provider-body text is visible.

### Phase 2 — Make request lifecycle generation-safe (P0)

Files:

- `TuberNotes/Notebook/NotebookViewModel.swift`
- `TuberNotes/Notebook/AgentSidebarView.swift`
- `TuberNotes/SpatialCanvas/DrawingRefinementOverlay.swift`
- `TuberNotes/Notebook/NotebookView.swift` only for presentation callbacks

Work:

1. Retain analysis and refinement task handles plus the exact request snapshot.
2. Expose Cancel while working; dismiss/Close cancels refinement.
3. Preserve the question, selection, crop, and prompt for explicit Retry after a
   recoverable failure. Cancellation is not rendered as failure.
4. Before any Pin or refinement preview is committed, verify that the captured
   OpenAI generation is still current. Discard late results after sign-out,
   expiry, or a new login.
5. Only expiry and 401/403 invalidate login. Cancellation, connectivity, 5xx,
   decoding, and unsupported-capability failures leave the session intact.

Manual Release gate: cancel each operation and sign out during each operation;
no late Pin, preview, or document mutation may appear. Retry must not require a
new lasso or retyping the question.

### Phase 3 — Make Release AI states truthful and actionable (P1)

Files:

- `TuberNotes/Notebook/AgentSidebarView.swift`
- `TuberNotes/Notebook/NotebookToolbar.swift`
- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/SpatialCanvas/DrawingRefinementOverlay.swift`

Work:

1. Replace Release “Demo mode” with “Sign in required” or “Signed in for this
   app run.” Keep demo copy only where a runnable demo really exists.
2. Route signed-out analysis and refinement to the same provider popup. Do not
   leave an enabled action whose only result is an alert.
3. Derive `canAnalyzeCurrentPage` from the same page snapshot predicate used by
   the request. On an empty page, disable Analyze and say “Add ink or an image
   to analyze.”
4. Present capability rejection separately from transient failure. Keep the
   lasso/selection intact in both cases.
5. Add direct Retry actions to errors and keep raw service configuration out of
   user copy.

Manual Release gate: signed-out, empty-page, working, cancel, retry, unsupported,
and signed-in states each have one clear next action and do not contradict the
runtime.

### Phase 4 — Make refinement Apply reversible (P1)

Files:

- `TuberNotes/Notebook/NotebookViewModel.swift`
- `TuberNotes/SpatialCanvas/DrawingRefinementOverlay.swift`
- existing Notebook undo integration only; no archive/schema change

Work:

1. Explain before Apply that fully enclosed ink will be replaced by a raster.
2. Capture the pre-apply drawing data, placed images, and retained lasso state.
3. Register one atomic undo that removes the refined raster, restores the source
   ink/images, and restores a coherent selection state.
4. Keep preview non-mutating and keep the PC-9 containment rule unchanged.

Manual Release gate: preview changes no document data; Apply replaces only fully
enclosed strokes; one Undo restores the exact prior drawing/images without
moving the page-space placement.

### Phase 5 — Promote structured Pins deliberately (P2, separate patch set)

Prerequisite: Phases 1–4 are manually accepted and a normal Notebook consumer
for streaming multiple Pins is explicitly chosen.

Files:

- extract from `TuberNotes/AgentHarness/DebugCodexAgentClient.swift`
- new `TuberNotes/AgentHarness/ResponsesPinStreamTranslator.swift`
- new `TuberNotes/AgentHarness/OpenAICodexAgentClient.swift`
- `TuberNotes/AgentHarness/AgentClient.swift`
- `TuberNotes/Notebook/NotebookViewModel.swift`
- `TuberNotes/Notebook/AgentSidebarView.swift`
- `TuberNotes/Knowledge/KnowledgeSearching.swift`
- `TuberNotes/App/RootView.swift` only to keep Debug compiling, never as the
  normal Release entry point

Work:

1. Extract the bounded strict `place_pins` translator into non-Debug
   AgentHarness code. It accepts one completed call and validates count, keys,
   text limits, enum values, finite coordinates, and crop-normalized `[0,1]`
   bounds. It produces only `PinDraft`.
2. Add `OpenAICodexAgentClient` using the Phase-1 route/transport and existing
   `AgentEvent` contract. Do not expand `AgentInsight` into a competing Pin
   schema.
3. Add a normal Notebook coordinator for stream state, cancellation, tool
   status, and persistence. Map crop coordinates through existing
   SpatialCanvas-owned transforms and persist page-normalized annotations only.
4. Inject `OfflineTextbookKnowledgeSearcher` from App/Knowledge into the agent
   tool loop. The model requests `search_textbook`; local code performs it and
   returns bounded excerpts/citations. The model receives no direct filesystem,
   document-store, or spatial access.
5. Keep `search_notebook` deferred and preserve the existing simple insight path
   until the structured path proves the same or better hero interaction.

Manual Release gate: one lasso can produce validated multiple Pins, streamed
status can be cancelled safely, textbook citations reflect local search, Pins
stay anchored through pan/zoom, and no Debug scenario is reachable.

### Phase 6 — Finish durable result controls and production seam (P2)

1. Add a Remove action for persisted AI Pins, with an explicit branch policy
   (recommended: confirm cascading removal of descendants) and immediate
   persistence.
2. Keep Hide as presentation state, never deletion.
3. Preserve the one transport-selection seam so the temporary direct Codex
   route can later be replaced by the authenticated TuberNotes gateway without
   changing Notebook, Pins, SpatialCanvas, or Knowledge.
4. Before distribution, remove/disable private direct-account routing and retain
   the gateway requirement from `SPEC.md` section 10.1.

## Ordering and patch boundaries

- Land Phases 1–2 together: centralized authorization without stale-result
  protection leaves a known race; lifecycle work without centralized routes
  duplicates policy again.
- Phase 3 can follow as a small UI-only patch after the runtime state is stable.
- Phase 4 is an independent document-safety patch and must not be bundled with
  provider transport changes.
- Phase 5 is intentionally separate and larger. It changes the normal product's
  AI output semantics from one explanatory annotation to streamed structured
  Pins plus a local tool loop.
- Phase 6 is cleanup/production preparation, not required to validate the
  hackathon hero loop.

## Risks and stop conditions

- Stop if the private Codex route requires reusable secrets, refresh-token
  persistence, cookie import, or access outside the memory-only session.
- Stop PC-11 at a clear unsupported-capability state if the private route rejects
  `image_generation`; do not silently send the OAuth token to a public API host.
- Stop before changing coordinate types/transforms, lasso containment, page IDs,
  archive schemas, or architecture ownership without a separately flagged
  contract patch.
- Reject any fallback from a failed Release login/request into recorded, mock,
  Debug API-key, or right.codes output.
- Bound all request inputs, streamed events, complete JSON, base64 images, tool
  arguments, search results, and user-visible error text.
- Never persist or log access/refresh/ID tokens, account identifiers, provider
  response bodies, authorization URLs/codes, or bearer-bearing errors.

## Evidence and stopping point

For each phase, delivery evidence is a fresh exact-device Release build,
install, and normal launch only. Phillip performs the listed manual gates in the
normal app. Debug/scenario/test/visual/human verification harnesses remain out
of scope until Phillip lifts the go-mode override.

The overall line stops after Phases 1–4 have manual acceptance and Phase 5 has
an explicit go/no-go decision. A rejected private image capability is a valid
PC-11 stop and does not block analysis/runtime unification.

## Audit provenance

- `ai_surface_inventory` mapped every Release/dormant AI entry point and ranked
  gaps.
- `ai_unification_architecture` proposed opaque capability routing, centralized
  transport, generation checks, and the structured-Pin extraction boundary.
- `ai_ux_audit` identified the destructive refinement Apply, missing cancel and
  retry states, misleading Demo copy, empty-page availability, and Pin removal
  gap.

### 2026-07-21 P0 scope correction

Phillip clarified that the sparkle-lasso hero behavior is crop vision → strict
structured `place_pins` → page-normalized guidance Pins. It is not image
generation or raster replacement. The P0 implementation therefore centralizes
the temporary route/transport, validates one bounded completed tool call, maps
crop coordinates through `SpatialCoordinateTransform`, and persists Pins in
the selected visible Agentic Layer. Image-generation fallback, drawing mutation,
and stroke deletion are explicitly outside this hero path. Phases 3–6 remain
deferred pending manual acceptance and an explicit follow-up scope.

All three audits were read-only. They made no file changes and ran no build,
network request, Debug/scenario harness, or device action.

## Session log

- 2026-07-21 — Phillip reported that hero Pin labels were oversized and changed
  apparent placement while zooming. Added a hero-only compact, page-anchored
  label policy: collapsed labels are 164×38 points, expanded cards are reduced,
  left/right placement is determined from the persisted page-normalized anchor,
  and edge/collision avoidance is disabled so zoom/pan cannot switch or clamp
  the card. Other Pin surfaces retain adaptive placement. Generic unsigned
  Release build succeeded under `tmp/build/pc12-stable-compact-pins/`; device
  delivery and Phillip's visual verdict remain pending.
- 2026-07-21 — Manual Release retry confirmed that the private Codex endpoint
  still did not return the forced `place_pins` function-call dialect. Replaced
  the pretend executable tool with the Responses structured-output contract:
  the same masked image/prompt now requests strict `text.format` JSON named
  `place_pins`, and the assistant text is validated into the existing Pin
  drafts. Legacy function-call decoding remains bounded compatibility only.
  Fresh exact-device signed Release build/install/normal launch succeeded from
  `tmp/build/pc12-structured-pin-text/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness, visual verifier, automated login, or provider
  request ran.
- 2026-07-21 — Fixed the apparent no-op after **Explain**. The attached menu
  previously hid `agentError` because failures were rendered only in the
  separate assistant sidebar. It now keeps the selection, displays a specific
  request-vs-decode error beside the halo, and leaves actions available for
  retry. The strict single `place_pins` decoder now also accepts the compatible
  `response.output_item.done` completion shape and an omitted redundant call
  status. Fresh exact-device signed Release build/install/normal launch
  succeeded from
  `tmp/build/pc12-visible-pin-result/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness, visual verifier, automated login, or provider
  request ran.
- 2026-07-21 — Fixed the retained Magic Eraser selection drifting during zoom.
  The lasso remains persisted in page-normalized coordinates, and its shape
  layer now reprojects that path whenever the projected page bounds change;
  the zoom container also reports its final viewport after recentering. Fresh
  exact-device signed Release build/install/normal launch succeeded from
  `tmp/build/pc12-zoom-stable-selection/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness or visual verifier ran. Phillip owns the live
  pinch/button-zoom judgment.
- 2026-07-21 — Live manual feedback showed the post-circle intent chooser was
  effectively absent because it was anchored at the bottom of the page and
  capture was discarded on pages without a recognized ink/image layer. Replaced
  it with an automatically presented floating context menu attached to the
  selected region, clamped above or below the halo, and made every valid circle
  produce the selection artifact and menu before any provider call. Explain,
  Check, Ask, and cancel remain explicit actions.
- 2026-07-21 — Exact-device preflight and a fresh signed Release build
  succeeded, installed, and normally launched from
  `tmp/build/pc12-attached-context-menu-v2/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness, visual verifier, automated login, or provider
  request ran. Phillip owns the live menu-placement and interaction verdict.
- 2026-07-21 — Phillip reported two live regressions: selecting Magic Eraser
  turned the whole page rainbow, and drawing a circle produced no visible
  result. Removed automatic Agentic Layer activation and the page-wide glow
  from this flow. Magic capture now accepts Pencil or touch, tolerates a
  naturally imperfect closure, provides success/rejection haptics and a red
  rejection flash, and retains only the local pulsing halo.
- 2026-07-21 — Added the post-selection intent gate: no provider request starts
  on capture. The retained region presents **Explain**, **Check**, and **Ask**;
  the first two pass distinct fixed prompts and Ask passes the user's text. The
  transmitted crop is white-masked outside the closed polygon, while returned
  crop-normalized Pins still use the existing crop-to-page transform. Fresh
  exact-device Release build/install/normal launch succeeded from
  `tmp/build/pc12-magic-prompt-flow/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness, visual verifier, automated login, or provider
  request ran. Phillip owns the live capture/prompt/provider verdict.
- 2026-07-21 — Phillip clarified the exact hero choreography after the first
  structured-Pin patch had replaced it: select **Magic Eraser**, draw a closed
  Pencil circle, retain a pulsing halo while AI works, place short guidance Pin
  heroes, and long-press any Pin to open a full-width Pin Chat tab. Rewired the
  normal Notebook to the existing Pencil-only `MagicLassoOverlay`, retained its
  closed page-normalized path, passed that exact crop to structured
  `place_pins`, and preserved crop-to-page projection. Ordinary lasso and ink
  are unchanged; no raster or stroke mutation occurs.
- 2026-07-21 — Exact-device preflight and a fresh signed Release build succeeded,
  installed, and normally launched from
  `tmp/build/pc12-magic-eraser-hero/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug/scenario/test harness, visual verifier, automated login, or provider
  request ran. Phillip owns Pencil feel, halo appearance, live Pin output, and
  full-chat interaction judgment after a fresh sign-in.
- 2026-07-21 — Phillip corrected the product intent: the sparkle-lasso is the
  guidance-Pin hero, not drawing generation. Implemented authenticated crop
  vision with strict `place_pins` function output, bounded SSE/complete response
  parsing, crop-to-page conversion through the existing spatial transform, and
  immediate Agentic Layer persistence. Removed the temporary OpenAI
  image-generation client; no AI path mutates ink or images.
- 2026-07-21 — Exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` passed preflight. A fresh signed
  Release build succeeded, installed, and normally launched from
  `tmp/build/pc12-guidance-pins/DerivedData/Build/Products/Release-iphoneos/TuberNotes.app`.
  No Debug build, scenario/test harness, visual verifier, automated login, or
  provider request ran. Reinstalling cleared the memory-only session; Phillip
  owns the fresh-login and live Pin-placement verdict.
