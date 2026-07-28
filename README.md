# TuberNotes Greenfield

This orphan branch rebuilds TuberNotes from a blank notebook foundation. It
shares no source tree or commit ancestry with the hackathon implementation.

The first product target is **Just a Canvas**: one durable page whose Pencil,
pan, zoom, undo, save, and relaunch behavior establishes the performance and
state-ownership rules for everything that follows.

Read these documents before adding application code:

- [`Docs/Architecture/DataContract.md`](Docs/Architecture/DataContract.md) —
  authoritative state, mutation, concurrency, coordinates, persistence, undo,
  and performance contract.
- [`Docs/Milestones/JustACanvas.md`](Docs/Milestones/JustACanvas.md) — exact
  scope and acceptance gates for the first executable target.
- [`Docs/Plan/PLAN.md`](Docs/Plan/PLAN.md) — ordered work lines and decision log.

[`AGENTS.md`](AGENTS.md) is the working contract for agents and humans alike;
[`CONTRIBUTING.md`](CONTRIBUTING.md) explains the gate-driven workflow.

No implementation from the previous app may be copied into this branch. The
old app may be observed as a behavioral reference only.
