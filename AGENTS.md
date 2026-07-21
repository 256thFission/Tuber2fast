# TuberNotes agent guide

TuberNotes is a one-week iPad hackathon. Prioritize: (1) hero interaction quality, (2) spatial correctness, (3) demo reliability, (4) AI capability, and (5) conventional note-app completeness.

## PC-10 go-mode override

Until Phillip explicitly lifts this override, PC-10 OpenAI-login work runs in
implementation-first go mode:

- Complete the scoped implementation before conducting review or verification.
- Do not run or modify Debug scenarios, recorded-agent routes, adapter tests,
  reproduction tooling, visual-verification tooling, device-verification
  scripts, human-device-loop sessions, or other behavioral verification for
  PC-10.
- Do not interrupt implementation for incremental review, screenshots, evidence
  collection, or human judgment. Resolve implementation questions from the
  current contracts and PC-10 plan.
- PC-10 targets the normal Release app, not a Debug-only surface. Temporary
  OpenAI account access may be compiled into Release only under the
  Keychain-isolated refresh, memory-only access-token, no-provider-secret
  boundary in `SPEC.md` section 10.1.
- After implementation is complete, device preflight, Release build, install,
  and a normal Release launch on Phillip's explicitly named iPad may run.
  They are delivery steps, not behavioral acceptance.
- Phillip alone performs final behavioral verification in the normal app. Do
  not claim behavioral success before his verdict.

This section overrides conflicting Debug-only and
build/launch/verification requirements below for PC-10 only. Security
boundaries, ownership rules, secret handling, and destructive-action rules
remain fully active.

## Rules

- Prefer the smallest implementation that proves the current milestone. For a small change, make a small change.
- Do not rewrite working systems unnecessarily or create large test suites for trivial changes.
- Compilation alone does not verify user-visible work; run and inspect it.
- Work autonomously inside established architectural contracts. A shared-contract change may be implemented without prior review, but the commit must carry a `CONTRACT:` prefix and a `Docs/Plan/PLAN.md` log entry naming the changed type and why — Phillip reviews after the fact and may roll back. Architecture-ownership changes still require Phillip first.
- Never bypass OS security or permission boundaries.
- Keep collaborator ownership clear: `App` integrates and owns the in-product AI boundary; `SpatialCanvas` owns Pencil/coordinates; `Pins` owns spatial UI; `Knowledge` owns retrieval; `DeveloperSupport` and `DeveloperTools` own development-only fixtures/tooling.

Codex, Skills, MCPs, Xcode, and fixtures are **development tooling**. The multimodal agent shipped inside TuberNotes and product tools such as `search_textbook`, `search_notebook`, and `place_pins` are **product runtime**. Never conflate their permissions, APIs, or responsibilities.

Canonical workflow: pin an explicitly named connected physical iPad with `DeveloperTools/device-preflight.sh`, then use `TuberNotes.xcodeproj`, scheme `TuberNotes`, through that shared session. Build, install, launch, and inspect the pinned device; never discover or fall back to another target. See `Docs/DeviceWorkflow.md`, `Docs/Development.md`, and the repo Skills under `.codex/skills/`.

Validate user-visible behavior only in the actual normal Release app on Phillip's explicitly named iPad. Debug scenarios, recorded routes, fixture-driven UI, `DeveloperTools/verify-scenario.sh`, `DeveloperTools/review-session.py`, and `DeveloperTools/PencilFixtureMCP` are disabled and must not be used as acceptance evidence. Phillip performs any required human interaction directly in the normal app. Never claim behavioral success before his verdict.

## Operating contract

1. Work within the named subsystem and make the smallest milestone-proving change.
2. Before long-running work, state acceptance evidence, files in scope, non-goals, and the stopping point.
3. Use subagents only when explicitly requested, and only for independent bounded outputs with a concrete return contract. Keep architecture, integration, and final judgment with the coordinating agent.
4. Treat build success as necessary but insufficient. Launch and inspect the normal Release app on the pinned device.
5. Return a compact evidence packet and artifact paths; keep full logs outside model context.
6. Escalate architecture ownership, permissions, external writes, secrets, irreversible actions, and human-only interaction judgments. Shared-contract changes proceed under the `CONTRACT:` flag-and-log rule instead of stopping.
7. After repeated verification failure, stop and report evidence instead of expanding scope or inventing workarounds.
8. Turn recurrent failures into the smallest durable repo improvement that would have prevented them (rule → narrow check).

## Task checkpoints

For substantial work, follow this loop and stop when the named condition is met:

1. **Inspect / plan** — confirm objective, scope, non-goals, and acceptance evidence.
2. **Bounded edit** — change only the files needed for the milestone.
3. **Build** — canonical project/scheme on the explicitly named physical iPad; retain failure tails, not full logs in context.
4. **Launch actual app** — install and open the normal Release app on the pinned iPad.
5. **Mechanical inspection** — inspect the actual app for clipping, overlap, crashes, missing state, and Pin drift where mechanically observable.
6. **Identify human judgment** — leave Pencil feel, taste, and interaction judgments to Phillip in the normal app.
7. **Final diff inspection** — reject unrelated churn, ownership violations, and speculative abstractions.
8. **Stop** — report the evidence packet, artifact paths, and unresolved issues.

Stop and report when: acceptance evidence is collected; an architecture-ownership change needs approval; verification fails twice without a narrower fix; or the next step would bypass a security/permission boundary. Shared-contract changes do not stop work — flag and log them per the `CONTRACT:` rule.

## Evidence packet

For user-visible changes, end with this compact packet (template: `Docs/templates/EvidencePacket.md`):

- objective and changed files
- short diff summary (and confirmation the final diff stayed in scope)
- build result
- actual Release-app journey and expected state
- screenshot / artifact paths
- console or crash status
- mechanical checks performed
- human-only checks still required and Phillip's verdict when available
- stop reason or unresolved issue

Handoffs between sessions or models use `Docs/templates/Handoff.md`.

## Current execution plan

The long-running coordination document is `Docs/Plan/PLAN.md`. Every session
works exactly one of its child work-line docs, then updates that child's
Status and Session log plus the parent status board before stopping. Do not
create new standalone handoff documents; append to the plan instead.
