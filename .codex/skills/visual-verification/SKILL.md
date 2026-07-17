---
name: visual-verification
description: Run and inspect user-visible TuberNotes work, mechanically checking clipping, overlap, crashes, scenario state, and spatial drift while identifying judgments that require human review.
---

# Visual verification

1. Build and run the changed state on the canonical iPad simulator via `DeveloperTools/verify-scenario.sh` or the manual loop. Select scenarios using the change-type map in `Docs/Development.md`.
2. Inspect the initial frame and the relevant interaction. Prefer the verifier's `screenshot.png` when comparison must be repeatable.
3. Mechanically check clipping, unintended overlap, missing content, crashes, deterministic Pin locations, and drift after supported viewport changes.
4. Compare against the requested behavior, not merely a successful launch.
5. Ask a human to judge Apple Pencil feel, interaction quality, animation feel, and visual taste on appropriate hardware. For durable UI review, use Skill `human-device-loop` with `create_feedback_thread` and automatic task resumption; reserve `request_pen_fixture` for authentic Pencil input.
6. Close with the evidence packet in `Docs/templates/EvidencePacket.md`, including artifact paths, any collected verdict/`humanNotes`, and remaining human-only checks.
