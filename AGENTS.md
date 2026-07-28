# TuberNotes greenfield agent contract

Greenfield rebuild of TuberNotes: a fully performant iPad canvas targeting
parity with GoodNotes. Optimize, in order, for ink integrity, interaction
latency, document durability, spatial correctness, and feature breadth.

Read before changing application code: `Docs/Architecture/DataContract.md`,
the active milestone in `Docs/Milestones/`, and `Docs/Plan/PLAN.md`.
`CONTRIBUTING.md` explains how to work here — the loop, the gate, and the
gotchas.

## Rules

Cite these by name, not number — the list gets pruned.

- **One writer.** Each durable value has one authoritative writer. Views
  render snapshots and send intentions; they never mutate document storage.
- **Canvas runtime owns the frame path.** Frame-frequency work stays inside
  the UIKit/PencilKit canvas runtime — not SwiftUI, observation, actors,
  reducers, or persistence.
- **Nothing synchronous on interaction paths.** No file, encoding, PDF,
  image, or database work on an interaction path or the main thread.
- **Scale with visible or changed content**, never with total notebook size.
- **Smallest change that proves the milestone.** No future notebook, PDF, AI,
  Pin, collaboration, or sync abstractions early.
- **No inherited implementation.** Nothing is copied from the previous app;
  it is a behavioral reference only.
- **Contract changes are explicit.** Any change to an authority, coordinate,
  persistence, or dependency rule updates `DataContract.md` and is tagged
  `CONTRACT:` in the commit subject.

## Definition of done

Work exactly one line of `Docs/Plan/PLAN.md` at a time. `Tools/gate.sh` is
the sole arbiter of done: PASS, INCOMPLETE (a gate skipped, evidence missing
— never report as success), or FAIL. Compilation is never behavioral proof.
Pencil feel, stroke fidelity, and visual taste are judged only by a human
maintainer — record the evidence, leave the verdict.
