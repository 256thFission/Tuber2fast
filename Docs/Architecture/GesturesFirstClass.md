# First-class custom Pencil gestures

Status: deferred vision, not an active contract  
Scope: design direction only. No implementation, no prescribed types, no
recognizer scaffolding in code. `Just a Canvas` builds none of this.

## Purpose

This note records a committed architectural decision: TuberNotes will support
custom, Pencil-authored gestures, and it will recognize them **post-hoc** rather
than by pre-empting ink in real time. It exists so the custom-gesture milestone
does not have to rediscover the fork, and so no earlier milestone wires input
handling in a way that structurally precludes it.

## Committed decisions

1. Custom gestures are a required future capability, not a maybe.
2. The gestures are **Pencil-authored** (not finger-only navigation verbs).
3. Recognition is **post-hoc reinterpretation (Fork A)**, not live interception
   (Fork B).

## What Fork A means

PencilKit remains the live ink engine. A Pencil stroke renders normally. When
the stroke completes, an app-owned classifier inspects the completed stroke(s);
if the stroke is a gesture — a scratch-out, a lasso circle, a bracket, a shape —
the app mutates the one live drawing to remove the gesture stroke and apply the
effect. Examples: scratch-to-erase, circle-to-select, draw-a-shape-and-beautify,
bracket-to-invoke. This is the model GoodNotes/Notability shape recognition uses.

Accepted cost: the gesture fires at stroke-end, and gesture ink may briefly
appear before it is reinterpreted. That latency and flash are inherent to Fork A
and are a UX concern, not an architecture defect.

## Why not Fork B

Live interception requires deciding gesture-vs-ink before PencilKit renders and
suppressing its output. `PKCanvasView`'s drawing gesture recognizer is greedy
and does not cleanly yield first crack at the Pencil stream, so Fork B would
force replacing `PKCanvasView` with an app-owned ink engine. Fork A avoids that
and keeps the `Just a Canvas` PencilKit bet as a real foundation rather than a
throwaway. If a specific future gesture genuinely cannot tolerate stroke-end
latency, that single gesture — not the whole app — is what reopens the ink-engine
question.

## Consequences that must not be violated early

These follow from `Docs/Architecture/DataContract.md` and must survive into the
gesture milestone:

- Input interpretation lives entirely inside `PageCanvasController`'s runtime.
  Custom recognition is added to the owner that already owns "gestures," never
  as SwiftUI observation of Pencil samples and never as a second canvas.
- The classifier mutates the single live drawing through the **ordinary autosave
  path** (mark dirty, debounce, capture, save), exactly as app-authored undo is
  specified to do. There is still one live `PKDrawing` and no second mutable copy.
- `drawingData` stays opaque in `Just a Canvas`. The gesture milestone is the
  first consumer to read stroke-level structure out of the drawing; that reading
  is its scope, not M0's.

## Raw samples come for free

Fork A needs no separate live raw-input capture. Each committed `PKStroke`
already carries its full sample sequence via `PKStroke.path` (`PKStrokePoint`:
location, timeOffset, force, azimuth, altitude). The committed `PKDrawing` is
therefore both the classifier's input and a replayable regression fixture. A
dedicated live sample buffer would only be justified by Fork B, which is not the
chosen path. Any separate diagnostic/event log records app-level actions, not a
per-sample firehose, and stays within the DataContract performance invariants.

## Relationship to `Just a Canvas`

This decision changes nothing to build in Milestone 0. Its value is that it
confirms PencilKit as a durable foundation, closes the live-sample-capture
question, and defines the future gesture layer as a post-stroke classifier owned
by `PageCanvasController` that mutates the one live drawing through the ordinary
save loop. Shape recognition and lasso are also listed as tools in
`Docs/Architecture/PDFImageFirstClass.md`; this note governs the recognition
*mechanism* for the Pencil-authored subset.
