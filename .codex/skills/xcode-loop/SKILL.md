---
name: xcode-loop
description: Build, launch, diagnose, and visually verify the canonical TuberNotes iPad app. Use for any TuberNotes code change that must be exercised through Xcode or an iPad simulator.
---

# Xcode loop

1. Use `TuberNotes.xcodeproj`, scheme `TuberNotes`, and `iPad Pro 13-inch (M5)` on the newest installed iOS runtime.
2. Prefer `DeveloperTools/verify-scenario.sh <scenario>` for user-visible changes. It builds, launches the DEBUG scenario, captures a screenshot, and prints artifact paths under `tmp/verify/`.
3. If the verifier is unsuitable, prefer XcodeBuildMCP when available; otherwise run the manual `xcodebuild` loop in `Docs/Development.md`, retaining only the failure tail unless more context is needed. Keep full logs as files, not in model context.
4. Choose scenarios from the change-type map in `Docs/Development.md`.
5. Inspect compiler diagnostics or the running UI. Fix the narrowest cause and repeat. After two failed verification attempts without a narrower fix, stop and report evidence instead of expanding scope.
6. For user-visible changes, return the evidence packet from `Docs/templates/EvidencePacket.md`. Do not treat compilation as visual verification.
7. Report the exact build destination and scenario. Do not claim physical Pencil behavior without a human hardware test via Skill `human-device-loop`.
