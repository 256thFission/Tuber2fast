# Documents and ink review guide

## Purpose and current status

Use this guide to generate review packets for the PDF, blank-notebook,
multi-page-notebook, page-local ink, and Pencil drawing surfaces.

| Capability | Status |
|---|---|
| Three-page PDF fixture and navigation | **IMPLEMENTED + SIMULATOR VERIFIED** |
| One-page blank dot-grid notebook | **IMPLEMENTED + INITIAL STATE VERIFIED** |
| App-owned notebook page addition | **IMPLEMENTED; DEVICE REVIEW REQUIRED** |
| Multi-page notebook with page-specific canned drawings | **IMPLEMENTED + SIMULATOR VERIFIED** |
| PDF pages with page-local canned ink | **IMPLEMENTED + SIMULATOR VERIFIED** |
| Pencil drawing surface | **IMPLEMENTED; PHYSICAL-IPAD REVIEW REQUIRED** |
| Production persistence and relaunch restoration | **DEFERRED / NOT IMPLEMENTED** |

Relevant implementation:

- `TuberNotes/App/RootView.swift`
- `TuberNotes/SpatialCanvas/SpatialCanvasView.swift`
- `TuberNotes/DeveloperSupport/DevelopmentScenario.swift`

## Mechanical preflight

Build the canonical project and run these scenarios before creating a human
packet:

```sh
xcodebuild -project TuberNotes.xcodeproj -scheme TuberNotes \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath DerivedData build

SKIP_BUILD=1 DeveloperTools/verify-scenario.sh pdf-pages
SKIP_BUILD=1 DeveloperTools/verify-scenario.sh blank-notebook
SKIP_BUILD=1 DeveloperTools/verify-scenario.sh notebook-pages
SKIP_BUILD=1 DeveloperTools/verify-scenario.sh ink-pages
```

Privately confirm launch, exact scenario marker, fresh runtime evidence, expected
page identity/count, screenshot integrity, console scan, and no new crash report.
Inspect screenshots for missing surfaces, clipping, and catastrophic overlap.

## Packet plan

Create separate scenario-pinned packets. Do not make the human switch scenarios
inside one packet.

| Review label | Scenario | Mode | Human-only checks |
|---|---|---|---|
| PDF navigation | `pdf-pages` | Asynchronous Review Run | Navigation clarity, page legibility, control placement |
| Blank notebook creation | `blank-notebook` | Guided if page creation needs agent inspection; otherwise asynchronous | Add-page discoverability, new-page appearance, transition quality |
| Notebook page identity | `notebook-pages` | Asynchronous Review Run | Drawings feel distinct per page; navigation is understandable |
| PDF ink separation | `ink-pages` | Asynchronous Review Run | Ink remains visually associated with the intended page |

Suggested visible actions should be short and subjective, for example:

- “Move between the available pages. Was it always clear which page you were on?”
- “Add one notebook page. Did anything about the control or transition feel confusing?”
- “Compare the drawings on pages 2 and 3. Did either appear to belong to the wrong page?”
- “Move away from and back to an inked PDF page. Did the drawing still look attached to that page?”

Do not ask the human to confirm UUIDs, page counts already asserted by tooling,
console state, or crash logs.

## Authentic Pencil packet

Pencil feel cannot be accepted from simulator mouse input. Use
`request_pen_fixture` for a separately named one-stroke capture, then collect it
through the human-device loop. Ask for one concrete stroke and, separately when
appropriate, one short feel/latency verdict. Do not combine an exact stroke
instruction with a PASS/FAIL request in the same step.

## Evidence and stop conditions

Record scenario artifact directories, screenshots, console/crash status, human
verdicts and notes, attachments, and any collected Pencil fixture path. Stop on
page identity confusion, ink appearing on the wrong page, failed page creation,
missing state after navigation, or device/host scenario divergence.

Do not claim production persistence or relaunch restoration from these packets.
