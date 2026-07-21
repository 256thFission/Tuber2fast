# PC-4 — Synchronized unlocked zoom

Status: **implementation complete — physical-device verification blocked**

Target branch: `sive/dev`

Owner: `SpatialCanvas` owns zoom and coordinate behavior; App integration owns
the normal notebook composition; `Pins` retains spatial UI ownership.

## Objective and user-visible outcome

Make unlocked pinch zoom continuous and visibly available while keeping paper,
images, foreground/background ink, refinement state, Agentic Layers, and Pins
synchronized to the same page viewport.

## Scope

- `TuberNotes/Notebook/NotebookCanvas.swift`
- `TuberNotes/Notebook/NotebookView.swift`
- `TuberNotes/SpatialCanvas/DrawingRefinementOverlay.swift`
- this child plan and the PC-4 parent status entry

## Non-goals and dependencies

- No persisted coordinate, Pin, page, drawing, or archive contract changes.
- No gesture architecture rewrite, new zoom modes, or unrelated toolbar work.
- Preserve the concurrent PC-2 toolbar and PC-3 export changes.
- Physical launch and interaction inspection require an explicitly named,
  pinned iPad on an Apple host.

## Work and verification

1. Prevent SwiftUI viewport reporting from feeding the previous bound scale
   back into the active UIKit pinch gesture.
2. Coalesce programmatic zoom targets and duplicate viewport callbacks.
3. Keep page-relative refinement state normalized throughout live zoom and pan;
   retain the existing page-normalized Pin projection.
4. Expose compact unlocked zoom-out/reset/zoom-in controls with the current
   scale and a pinch hint; disable all zoom actions while locked.
5. Inspect the final diff and run host-safe coordinate and hygiene checks.
6. On the pinned iPad, run `pin-drift`, `fake-pin`, and `multi-pin`, then inspect
   live unlocked pinch zoom for smoothness, layer drift, clipping, and crashes.

## Acceptance evidence and stop conditions

- An active pinch is never overwritten by stale bound zoom state.
- Repeated render updates do not restart a programmatic zoom animation.
- All page-relative visual layers remain attached to the page during zoom;
  persisted anchors remain page-normalized.
- Unlocked zoom is visible and operable; locking disables pinch and direct or
  menu-based zoom actions consistently.
- Stop after evidence is collected, after two failed device verifications
  without a narrower repair, or when the exact-device prerequisite is absent.

## Session log

- 2026-07-20 — Traced the chop to a live feedback loop: viewport-frame state
  updates re-entered `NotebookCanvas.updateUIView` during pinch and animated
  the scroll view toward the pre-gesture `zoomScale`. Implemented explicit
  user-zoom ownership, coalesced programmatic targets, deduplicated identical
  viewport frames, normalized refinement selections, and added unlocked zoom
  controls. `git diff --check` passes. The non-symmetric `(0.69, 0.49)` viewport
  round trip across scales 0.5, 1, 2.375, and 5 has maximum error
  `5.5511151231257827e-17`. This Linux host has no Swift/Xcode toolchain and no
  pinned device session, so build, launch, live pinch, screenshots, console,
  crash, clipping, and physical Pin-drift checks remain open. Stopped at the
  exact-device prerequisite per the repository contract.
