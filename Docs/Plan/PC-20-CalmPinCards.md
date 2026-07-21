# PC-20 — calm, content-preserving Pin cards

Status: **implementation complete and Release-delivered — awaiting Phillip's verdict**

Target branch: `main`

Owner: `Pins` spatial UI. Notebook integration, AgentHarness response content,
page-normalized anchors, Pencil/canvas gestures, persistence, and Pin Chat remain
unchanged.

## Objective and user-visible outcome

Replace the visually heavy collapsed Pin label and clipped translucent expanded
card with a calm annotation interaction that keeps handwriting dominant:

- collapsed Pins render as a single clear 44-point target with no text pill;
- tapping a Pin reveals one nearby, connected, high-contrast answer card;
- the card has an explicit close action, readable hierarchy, and room for a
  concise answer without clipping;
- longer content remains scrollable and offers the existing direct Pin Chat
  continuation without duplicating instructional chrome;
- placement remains edge-aware and never rewrites the persisted Pin anchor.

## Scope

- `TuberNotes/Pins/Pin.swift`
- `TuberNotes/Pins/PinOverlayView.swift`
- focused Pins source-contract checks
- this child plan and the PC-20 parent status entry

## Non-goals and dependencies

- No prompt, provider, Markdown, response, persistence, archive, thread, page,
  coordinate-system, or target-region changes.
- No background-tap or writing-gesture interception; dismissal is explicit on
  the card and by retapping the Pin so Pencil/canvas ownership stays intact.
- No Debug scenario, recorded route, fixture-driven acceptance, or automated
  behavioral claim. Final interaction/taste judgment remains Phillip's in the
  normal Release app.

## Work and verification

1. Make labels expansion-only and preserve a full-size anchor hit target.
2. Enlarge the expanded card within page bounds and use an opaque, accessible
   surface with concise header/body/action hierarchy.
3. Keep the connector, edge/collision placement, drag, citations, Markdown,
   streaming/failure states, and Continue path truthful.
4. Add narrow host-safe source/layout checks, inspect the diff, then preflight,
   build, install, and normally launch Release on Phillip's pinned iPad.
5. Mechanically inspect clipping, overlap, immediate crashes, and Pin attachment;
   leave animation feel and visual taste to Phillip.

## Acceptance evidence and stop conditions

- No collapsed text card appears over handwriting.
- Expanded content has a readable dark surface, clear close action, and no
  duplicate teaser/body treatment introduced by the card.
- Compact normal-notebook placement provides at least a 300-point-wide,
  220-point-tall card when the page has room, while edge clamping remains intact.
- Existing drag, Continue, citation, Markdown, accessibility, and status paths
  remain available.
- Host checks and diff hygiene pass; Release builds, installs, and normally
  launches on only the explicitly pinned iPad.
- Stop after evidence is recorded, after two narrow verification failures, or
  before any change that would pressure Pencil/coordinate ownership.

## Session log

- 2026-07-21 — Phillip rejected the current normal-app Pin presentation. The
  supplied screenshots show collapsed text obscuring handwriting, a translucent
  low-contrast surface, repeated summary hierarchy, and an expanded compact card
  clipping its answer. Started a Pins-only visual repair on `main`; preserved the
  unrelated untracked `.claude/` directory. No product code changed yet.
- 2026-07-21 — Implemented the Pins-only redesign. Collapsed labels now have
  zero layout size and are not rendered; the 44-point anchor remains. Expanded
  normal-notebook cards grow from 228×126 to 310×230 when space permits, retain
  edge-aware placement and a connector, use an opaque near-black surface, show
  visible scrolling, and expose independent Pin Chat and Close controls. Removed
  the duplicated drag-instruction/action strip; drag remains discoverable through
  the Pin anchor's accessibility hint and unchanged gesture behavior.
- 2026-07-21 — Final host checks pass 8/8 and `git diff --check` passes. Exact
  iPad `2DD98ECC-A26A-5730-943B-01DD63DC4117` passed preflight; the final signed
  Release build succeeded, installed, launched normally without a scenario, and
  remained present in the device process list. Artifacts are under
  `tmp/verify/pc20-calm-pin-cards/` and
  `tmp/build/pc20-calm-pin-cards-device/`. No automated interaction, screenshot,
  attached console, or crash report was collected. Phillip's current normal-app
  clipping/overlap, scrolling, animation, touch, Pencil, and taste verdict remains.

## Evidence packet — 2026-07-21

- Objective/changed files: calm collapsed Pin and readable expanded card in
  `Pin.swift` and `PinOverlayView.swift`; narrow source checks and PC-20 plan
  records. Final diff stayed inside Pins presentation/layout plus its check/docs.
- Diff summary: labels render only for the expanded Pin; compact expanded size is
  310×230; surface, hierarchy, close/chat controls, scrolling, and anchor styling
  were revised. Coordinates, drag, persistence, response content, Markdown,
  provider routing, notebook integration, Pin Chat, and Pencil/canvas code did
  not change. Untracked `.claude/` content remains untouched.
- Build/delivery: focused tests 8/8 PASS; diff hygiene PASS; signed Release build,
  install, normal launch, and live-process query PASS on only iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`.
- Expected normal journey: open the existing notebook, observe only the small Pin
  anchor, tap it to reveal the connected dark card, read/scroll, open Pin Chat or
  close, and drag the anchor without changing its logical attachment.
- Artifacts: `tmp/verify/pc20-calm-pin-cards/focused-tests-final.log`,
  `preflight.log`, `build-final.log`, `install-final.log`, `launch-final.log`, and
  `processes-final.log`; app product under
  `tmp/build/pc20-calm-pin-cards-device/DerivedData/Build/Products/Release-iphoneos/`.
- Console/crash: no attached console or crash report; successful normal launch
  plus live-process query establishes no immediate exit only.
- Mechanical checks: source contract for expansion-only labels, card dimensions,
  opaque surface, explicit close, visible scrolling, Pin Chat reachability,
  page-normalized drag seam, signed build/install/launch, and process presence.
- Human-only checks: actual content avoidance, clipping/overlap near all page
  edges, scroll feel, open/close/drag animation, touch/Pencil coexistence,
  readability, and visual taste. Phillip's verdict is not yet supplied.
- Stop reason: every safe implementation and delivery step is complete; final
  normal-app behavioral/visual acceptance belongs to Phillip.
