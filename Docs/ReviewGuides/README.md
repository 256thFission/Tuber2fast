# M0 review-packet guides

Use these guides when a new Codex task needs to prepare review evidence or an
on-device review journey for the current M0 implementation.

| Major group | Guide | Default review path |
|---|---|---|
| Documents and ink | `DocumentsAndInk.md` | Mechanical scenario pass, then scenario-pinned human Review Runs |
| Spatial canvas and Pins | `SpatialAndPins.md` | Mechanical spatial checks, then guided or asynchronous device review |
| Agent and Knowledge | `AgentAndKnowledge.md` | Focused tests; optional review of the explicitly partial hero stub |
| Verification tooling | `VerificationTooling.md` | Agent-run harness conformance and evidence packet; normally no human session |

## Status vocabulary

- **IMPLEMENTED + VERIFIED**: the named behavior exists and has current mechanical
  evidence in its supported environment.
- **IMPLEMENTED; DEVICE REVIEW REQUIRED**: the behavior exists, but physical-iPad
  feel, usability, or visual judgment remains open.
- **IMPLEMENTED; NOT APP-INTEGRATED**: the subsystem behavior is tested behind its
  product boundary but has no complete user-facing flow.
- **PARTIAL / STUB**: a narrow demonstrator exists while named product behavior is
  missing. A passing stub scenario is not feature acceptance.
- **DEFERRED / NOT IMPLEMENTED**: do not create an acceptance packet pretending the
  behavior exists.

## Rules for every generated packet

1. Read `.codex/skills/human-device-loop/SKILL.md`, `Docs/Development.md`, and
   `Docs/DeviceWorkflow.md` before creating device state; use
   `Docs/templates/EvidencePacket.md` for the result.
2. Run the guide's mechanical preflight first. Never ask the human to judge facts
   the tooling can verify.
3. Before creating visible sessions, publish a chat-only table of human-readable
   review labels, pinned scenarios, and checks covered.
4. One visible session stays pinned to one scenario. Do not ask the human to set
   environment variables, copy files, or reason about protocol state.
5. Keep identifiers, owner tokens, cursors, queue state, expected assertions,
   artifact paths, and test keys agent-side.
6. Prefer one asynchronous Review Run when all checks are human-autonomous; the
   human completes ready checks in any order and taps `Finish Review` once. Use
   guided review only when the agent must inspect evidence or establish a
   precondition between actions.
7. Use active waiting, then arm the Codex feedback wake bridge before yielding. Use a task heartbeat only if bridge arming fails. Stop on the first unmet precondition,
   ambiguous response, failure, human confusion, or device/host divergence.
8. Export durable evidence and finish with `Docs/templates/EvidencePacket.md`.
