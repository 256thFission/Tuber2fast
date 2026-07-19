---
name: xcode-loop
description: Build, install, launch, diagnose, and verify the canonical TuberNotes app on a connected physical iPad.
---

# Xcode loop

1. Read `Docs/DeviceWorkflow.md`. Run `DeveloperTools/device-preflight.sh --device <device-id>` to pin the explicitly named connected physical iPad. Never discover or fall back to another target.
2. Prefer `DeveloperTools/verify-scenario.sh <scenario>` for user-visible changes. It consumes the pinned session, builds, installs, launches the DEBUG scenario, pulls nonce-matched runtime evidence, and prints artifact paths under `tmp/verify/`; it does not capture the physical screen.
3. If the verifier is unsuitable, prefer XcodeBuildMCP when available; otherwise run the manual `xcodebuild` loop in `Docs/Development.md`, retaining only the failure tail unless more context is needed. Keep full logs as files, not in model context.
4. Choose scenarios from the change-type map in `Docs/Development.md`.
5. Inspect compiler diagnostics or the running UI. Fix the narrowest cause and repeat. After two failed verification attempts without a narrower fix, stop and report evidence instead of expanding scope.
6. For user-visible changes, return the evidence packet from `Docs/templates/EvidencePacket.md`. Do not treat compilation as visual verification.
7. Report the exact physical-device ID and scenario. Inspect the visible result on that iPad, and do not claim Pencil behavior without a human hardware test via Skill `human-device-loop`.
