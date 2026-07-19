# Spatial canvas and Pins review guide

## Purpose and current status

Use this guide for page-normalized Pin placement, label layout, viewport changes,
page transitions, and spatial stability.

| Capability | Status |
|---|---|
| One and multiple deterministic interior Pins | **IMPLEMENTED; PHYSICAL-IPAD RECHECK REQUIRED** |
| Canonical top/right/bottom/left edge Pins | **IMPLEMENTED + VISUALLY INSPECTED** |
| Page-scoped deterministic zoom/pan state | **IMPLEMENTED; PHYSICAL-IPAD RECHECK REQUIRED** |
| Pin anchoring across zoom, pan, page turn, return, and rotation | **IMPLEMENTED; PHYSICAL-IPAD RECHECK REQUIRED** |
| Physical-iPad spatial feel and label taste | **DEVICE REVIEW REQUIRED** |
| Arbitrary production gestures and every device geometry | **NOT FULLY VERIFIED** |

Relevant implementation:

- `TuberNotes/SpatialCanvas/SpatialCanvasView.swift`
- `TuberNotes/Pins/PinOverlayView.swift`
- `TuberNotes/App/RootView.swift`
- `TuberNotes/DeveloperSupport/DevelopmentScenario.swift`

Use `.codex/skills/spatial-debugging/SKILL.md` in addition to the human-device
loop whenever diagnosing drift or coordinate conversion.

## Mechanical preflight

```sh
DeveloperTools/device-preflight.sh --device <device-id>
DeveloperTools/verify-scenario.sh fake-pin
SKIP_BUILD=1 DeveloperTools/verify-scenario.sh multi-pin
SKIP_BUILD=1 DeveloperTools/verify-scenario.sh edge-pins
SKIP_BUILD=1 DeveloperTools/verify-scenario.sh pin-drift
```

Privately verify exact annotation IDs supplied to rendering, the target page ID,
fresh runtime evidence, and accessibility controls. Inspect the pinned iPad and
record screenshots, console, and crash evidence as collected or not collected.
For `pin-drift`, mechanically exercise:

1. Target page begins fit to page.
2. `Change viewport` reports zoomed and panned.
3. Adjacent page remains fit to page.
4. Returning to the target restores its selected viewport state.
5. Rotation does not make the control and rendered state disagree.

The verifier does not measure pixels or prove zero drift; inspect the result.

## Packet plan

| Review label | Scenario | Mode | Human-only checks |
|---|---|---|---|
| Interior Pin composition | `multi-pin` | Asynchronous Review Run | Label hierarchy, overlap, visual density |
| Edge Pin composition | `edge-pins` | Asynchronous Review Run | Clipping, label readability, target/label association |
| Pin stability journey | `pin-drift` | Guided review | Perceived drift, transition smoothness, spatial confidence |

The guided Pin-stability journey should present only one current action. A safe
sequence is: observe the anchor, change the viewport, turn away, return, rotate,
then give one subjective verdict. Between actions, the agent verifies the stated
precondition and stops immediately on divergence.

Suggested human-only questions:

- “Did the Pin appear to move relative to the underlying equation?”
- “Were any edge labels clipped or hard to associate with their target?”
- “Did zooming, paging, or rotation make the Pin interaction feel unstable?”

Do not ask the human to report coordinates or determine whether fixture IDs match.

## Evidence and stop conditions

Retain before/after screenshots when available, exact scenario artifact paths,
the mechanically observed page/control state, and the human's drift/taste verdict.
Stop on the first visible drift, wrong-page Pin, clipped primary label, missing
anchor, unexpected viewport transfer, ambiguous verdict, or scenario divergence.
