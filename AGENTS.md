# TuberNotes agent guide

TuberNotes is a one-week iPad hackathon. Prioritize: (1) hero interaction quality, (2) spatial correctness, (3) demo reliability, (4) AI capability, and (5) conventional note-app completeness.

## Rules

- Prefer the smallest implementation that proves the current milestone. For a small change, make a small change.
- Do not rewrite working systems unnecessarily or create large test suites for trivial changes.
- Compilation alone does not verify user-visible work; run and inspect it.
- Work autonomously inside established architectural contracts. Shared contracts or architecture changes require human review.
- Never bypass OS security or permission boundaries.
- Keep collaborator ownership clear: `App` integrates; `SpatialCanvas` owns Pencil/coordinates; `Pins` owns spatial UI; `AgentHarness` owns the in-product AI boundary; `Knowledge` owns retrieval; `DeveloperSupport` and `DeveloperTools` own fixtures/tooling.

Codex, Skills, MCPs, Xcode, simulators, and fixtures are **development tooling**. The multimodal agent shipped inside TuberNotes and product tools such as `search_textbook`, `search_notebook`, and `place_pins` are **product runtime**. Never conflate their permissions, APIs, or responsibilities.

Canonical workflow: `TuberNotes.xcodeproj`, scheme `TuberNotes`, simulator `iPad Pro 13-inch (M5)`. See `Docs/Development.md` and the repo Skills under `.codex/skills/`.

Human Pencil capture and in-app review feedback go through Debug `DeveloperSupport` + `DeveloperTools/PencilFixtureMCP` (Skill: `human-device-loop`). The connected test device shows the agent prompt in a banner. The human draws and/or taps a verdict (`looks-good` / `needs-work` / `blocked`); an optional note is stored as `humanNotes`. No Mac-side file work. Details: `Docs/Development.md` § Human device loop.

## Operating contract

1. Work within the named subsystem and make the smallest milestone-proving change.
2. Before long-running work, state acceptance evidence, files in scope, non-goals, and the stopping point.
3. Use subagents only when explicitly requested, and only for independent bounded outputs with a concrete return contract. Keep architecture, integration, and final judgment with the coordinating agent.
4. Treat build success as necessary but insufficient. Launch a deterministic scenario and inspect the result (`DeveloperTools/verify-scenario.sh` or the loop in `Docs/Development.md`).
5. Return a compact evidence packet and artifact paths; keep full logs outside model context.
6. Escalate shared contracts, architecture, permissions, external writes, secrets, irreversible actions, and human-only interaction judgments.
7. After repeated verification failure, stop and report evidence instead of expanding scope or inventing workarounds.
8. Turn recurrent failures into the smallest durable repo improvement that would have prevented them (rule → Skill → fixture/scenario → narrow check).

## Task checkpoints

For substantial work, follow this loop and stop when the named condition is met:

1. **Inspect / plan** — confirm objective, scope, non-goals, and acceptance evidence.
2. **Bounded edit** — change only the files needed for the milestone.
3. **Build** — canonical project/scheme/simulator; retain failure tails, not full logs in context.
4. **Launch scenario** — pick scenarios from the change-type map in `Docs/Development.md`.
5. **Mechanical visual verification** — clipping, overlap, crashes, missing state, Pin drift.
6. **Identify human review** — Pencil feel, taste, architecture, or anything the scenario cannot prove. Prefer `human-device-loop` so the verdict/notes land as durable JSON.
7. **Final diff inspection** — reject unrelated churn, ownership violations, and speculative abstractions.
8. **Stop** — report the evidence packet, artifact paths, and unresolved issues.

Stop and report when: acceptance evidence is collected; a shared-contract or architecture change needs approval; verification fails twice without a narrower fix; or the next step would bypass a security/permission boundary.

## Evidence packet

For user-visible changes, end with this compact packet (template: `Docs/templates/EvidencePacket.md`):

- objective and changed files
- short diff summary (and confirmation the final diff stayed in scope)
- build result
- scenario(s) and expected state
- screenshot / artifact paths
- console or crash status
- mechanical checks performed
- human-only checks still required (or collected via `human-device-loop`: request id, verdict, `humanNotes`, fixture path)
- stop reason or unresolved issue

Handoffs between sessions or models use `Docs/templates/Handoff.md`.
