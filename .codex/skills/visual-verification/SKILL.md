---
name: visual-verification
description: Run and inspect user-visible TuberNotes work, mechanically checking clipping, overlap, crashes, scenario state, and spatial drift while identifying judgments that require human review.
---

# Visual verification

1. Read `Docs/DeviceWorkflow.md`, pin the iPad with `DeveloperTools/device-preflight.sh --device <device-id>`, then build, install, and run the changed state via `DeveloperTools/verify-scenario.sh <scenario>` or the manual loop. Select scenarios using the change-type map in `Docs/Development.md`. Stop if the pinned iPad is unavailable.
2. Inspect the initial frame and the relevant interaction on the iPad. The verifier proves scenario selection and runtime state but does not capture a physical-device screenshot; collect any screenshot or human visual verdict separately through `human-device-loop`.
3. Mechanically check clipping, unintended overlap, missing content, crashes, deterministic Pin locations, and drift after supported viewport changes.
4. Compare against the requested behavior, not merely a successful launch.
5. Ask a human to judge Apple Pencil feel, interaction quality, animation feel, and visual taste on the connected iPad. For durable UI review, use Skill `human-device-loop` with active waiting followed by the event wake bridge; reserve `request_pen_fixture` for authentic Pencil input.
6. Close with the evidence packet in `Docs/templates/EvidencePacket.md`, including artifact paths, any collected verdict/`humanNotes`, and remaining human-only checks.
