# TuberNotes agent guide

TuberNotes is a one-week iPad hackathon. Prioritize: (1) hero interaction quality, (2) spatial correctness, (3) demo reliability, (4) AI capability, and (5) conventional note-app completeness.

## Rules

- Prefer the smallest implementation that proves the current milestone. For a small change, make a small change.
- Do not rewrite working systems unnecessarily or create large test suites for trivial changes.
- Compilation alone does not verify user-visible work; run and inspect it.
- Work autonomously inside established architectural contracts. A shared-contract change may be implemented without prior review, but the commit must carry a `CONTRACT:` prefix and a `Docs/Plan/PLAN.md` log entry naming the changed type and why — Phillip reviews after the fact and may roll back. Architecture-ownership changes still require Phillip first.
- Never bypass OS security or permission boundaries.
- Keep collaborator ownership clear: `App` integrates; `SpatialCanvas` owns Pencil/coordinates; `Pins` owns spatial UI; `AgentHarness` owns the in-product AI boundary; `Knowledge` owns retrieval; `DeveloperSupport` and `DeveloperTools` own fixtures/tooling.

Codex, Skills, MCPs, Xcode, physical-device harnesses, and fixtures are **development tooling**. The multimodal agent shipped inside TuberNotes and product tools such as `search_textbook`, `search_notebook`, and `place_pins` are **product runtime**. Never conflate their permissions, APIs, or responsibilities.

Canonical workflow: pin an explicitly named connected physical iPad with `DeveloperTools/device-preflight.sh`, then use `TuberNotes.xcodeproj`, scheme `TuberNotes`, through that shared session. Build, install, launch, and inspect the pinned device; never discover or fall back to another target. See `Docs/DeviceWorkflow.md`, `Docs/Development.md`, and the repo Skills under `.codex/skills/`.

Human Pencil capture and in-app review feedback go through Debug `DeveloperSupport` + `DeveloperTools/PencilFixtureMCP` (Skill: `human-device-loop`). Conversational review uses active waiting while the turn is live, then a one-response event bridge to resume the originating Codex task; a one-minute task heartbeat is emergency fallback only when bridge arming fails. Authentic Pencil capture remains a separate one-stroke fixture protocol. The human works only in TuberNotes—no Mac-side file work. Details: `Docs/Development.md` § Human device loop.

### Human review session contract

- One guided review journey maps to one visible feedback session unless the human explicitly requests separate conversations. Queue, ownership, and protocol-conformance work stays out of that session.
- Show the human only the current action and, when needed, one short question. Keep thread/request IDs, owner tokens, sequence cursors, lifecycle states, queue details, expected assertions, artifact paths, and test keys agent-side.
- Ask for either an exact response needed to exercise behavior or a subjective verdict, never both in one step. Do not ask the human to judge mechanical facts the tooling can verify.
- An event-bridge or fallback-heartbeat wake collects, acknowledges, records, and notifies before advancing. Advance only after the prior response is understood, recorded, and the next precondition is verified.
- Stop the guided journey on an unmet precondition, ambiguous response, first failure, device/host state divergence, or human confusion. Explain the issue before asking for another action; never invent Pencil feel, visual taste, intent, or interaction judgments.

## Operating contract

1. Work within the named subsystem and make the smallest milestone-proving change.
2. Before long-running work, state acceptance evidence, files in scope, non-goals, and the stopping point.
3. Use subagents only when explicitly requested, and only for independent bounded outputs with a concrete return contract. Keep architecture, integration, and final judgment with the coordinating agent.
4. Treat build success as necessary but insufficient. Launch a deterministic scenario and inspect the result (`DeveloperTools/verify-scenario.sh` or the loop in `Docs/Development.md`).
5. Return a compact evidence packet and artifact paths; keep full logs outside model context.
6. Escalate architecture ownership, permissions, external writes, secrets, irreversible actions, and human-only interaction judgments. Shared-contract changes proceed under the `CONTRACT:` flag-and-log rule instead of stopping.
7. After repeated verification failure, stop and report evidence instead of expanding scope or inventing workarounds.
8. Turn recurrent failures into the smallest durable repo improvement that would have prevented them (rule → Skill → fixture/scenario → narrow check).

## Task checkpoints

For substantial work, follow this loop and stop when the named condition is met:

1. **Inspect / plan** — confirm objective, scope, non-goals, and acceptance evidence.
2. **Bounded edit** — change only the files needed for the milestone.
3. **Build** — canonical project/scheme on the explicitly named physical iPad; retain failure tails, not full logs in context.
4. **Launch scenario** — pick scenarios from the change-type map in `Docs/Development.md`.
5. **Mechanical visual verification** — clipping, overlap, crashes, missing state, Pin drift.
6. **Identify human review** — Pencil feel, taste, architecture, or anything the scenario cannot prove. Prefer `human-device-loop` so feedback messages, attachments, watch state, or Pencil fixtures land as durable evidence.
7. **Final diff inspection** — reject unrelated churn, ownership violations, and speculative abstractions.
8. **Stop** — report the evidence packet, artifact paths, and unresolved issues.

Stop and report when: acceptance evidence is collected; an architecture-ownership change needs approval; verification fails twice without a narrower fix; or the next step would bypass a security/permission boundary. Shared-contract changes do not stop work — flag and log them per the `CONTRACT:` rule.

## Evidence packet

For user-visible changes, end with this compact packet (template: `Docs/templates/EvidencePacket.md`):

- objective and changed files
- short diff summary (and confirmation the final diff stayed in scope)
- build result
- scenario(s) and expected state
- screenshot / artifact paths
- console or crash status
- mechanical checks performed
- human-only checks still required (or collected via `human-device-loop`: feedback-thread/request ID, watch state and sequence, messages/attachments or verdict/notes, fixture path)
- stop reason or unresolved issue

Handoffs between sessions or models use `Docs/templates/Handoff.md`.

## Current execution plan

The long-running coordination document is `Docs/Plan/PLAN.md`. Every session
works exactly one of its child work-line docs, then updates that child's
Status and Session log plus the parent status board before stopping. Do not
create new standalone handoff documents; append to the plan instead.
