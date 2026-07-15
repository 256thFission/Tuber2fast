---
name: human-device-loop
description: Request human Pencil capture or UI review on a connected TuberNotes test device via PencilFixtureMCP, then collect durable indexed results without Mac-side human steps.
---

# Human device loop

Use this for judgments or authentic Pencil input the simulator cannot provide. Canonical detail: `Docs/Development.md` § Human device loop and `DeveloperTools/PencilFixtureMCP/README.md`.

1. Ensure Debug TuberNotes is installed on the connected iPad or booted canonical simulator.
2. Call PencilFixtureMCP `request_pen_fixture(description)` or `request_human_review(prompt)`. Prefer a physical device when available.
3. Tell the human only: read the in-app banner, then draw once and/or tap a verdict. Optional free-text note is fine; never required. Do not ask them to set env vars or copy files.
4. Call `await_interaction(request_id)` (or poll `collect_interaction`) and keep the returned fixture path, verdict, `humanNotes`, and index entry in `Docs/templates/EvidencePacket.md`.
5. For replay, use `replay_pen_fixture(name)` through the controlled app seam. Never treat simulator mouse input as authentic Pencil.
6. Stop if the device is unavailable and report the delivery error rather than inventing synthetic stroke data.
