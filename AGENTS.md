# TuberNotes agent guide

TuberNotes is a one-week iPad hackathon. Prioritize: (1) hero interaction quality, (2) spatial correctness, (3) demo reliability, (4) AI capability, and (5) conventional note-app completeness.

## Human-in-the-loop review is ACTIVE on this worktree

> This section is authoritative on the `demo/codex-human-review` worktree. It
> **supersedes** the "PC-10 go-mode override" and the paragraph below that calls
> `DeveloperTools/PencilFixtureMCP` disabled. On this worktree the human review
> loop is enabled and, for the trigger below, **required**. Everywhere else the
> disable still stands.

TuberNotes' verification model splits work into two kinds:

- **Verifiable** — a build, a test, or a mechanical inspection settles it. Handle
  it yourself; do not bother a human.
- **Non-verifiable (taste / feel / "reads better")** — no test can settle it.
  You do **not** get to self-certify these. You must obtain a human verdict
  through the `PencilFixtureMCP` review tools before claiming the work is done.

The `PencilFixtureMCP` server is the human-in-the-loop verifier. When you post a
question, it surfaces as a "Your turn" card inside the running app
(`ReviewHarnessOverlay`, `REVIEW_HARNESS` build), the human answers on device,
and their verdict returns to you. Treat that verdict as the test result.

### Trigger

When the operator's request is exactly (or a close paraphrase of):

> **"The pin overlay feels cramped — widen its internal padding so notes read better."**

follow the flow below. Do not skip the human verdict, and do not declare success
before it arrives.

### Required flow

1. **Make the smallest change.** Edit the pin-note padding in
   `TuberNotes/Pins/PinOverlayView.swift` (the `.padding(.horizontal, 14)` /
   `.padding(.vertical, 10)` on the note body near line 490). Widen it modestly —
   e.g. horizontal 14 → 18, vertical 10 → 14. One bounded edit; no refactor.

2. **Build** to prove it compiles (scheme `TuberNotes`, Debug — the
   `REVIEW_HARNESS` flag is on for this scheme).

3. **Recognize this is non-verifiable.** "Reads better" is taste. Request a human
   verdict via `PencilFixtureMCP` — three tool calls, in order:

   ```
   create_feedback_thread(
     title="Pin overlay spacing — does it read better?",
     objective="Human verdict on a non-verifiable spacing change.",
     prompt="I widened the pin overlay padding. Confirm the new spacing reads better.",
     scenario="pin-overlay-demo")
   → returns { feedback_thread_id, owner_token, last_sequence }

   ask_thread_question(
     feedback_thread_id, owner_token,
     idempotency_key="pin-overlay-q1",
     prompt="I widened the pin overlay padding (h:14→18, v:10→14). Which way did the spacing go?",
     kind="single-choice",
     options=[{"id":"better","label":"Better"},
              {"id":"same","label":"About the same"},
              {"id":"worse","label":"Worse"}],
     allows_comment=True)
   → returns the question message; note its sequence

   await_thread_response(
     feedback_thread_id, owner_token,
     after_sequence=<the question message sequence>,
     timeout_seconds=180)
   → blocks until the human answers on device
   ```

4. **Act on the verdict.**
   - `better` → finalize; report the change plus the human verdict as the
     acceptance evidence.
   - `same` / `worse` → adjust the padding per any comment and repeat step 3 with
     a fresh `idempotency_key`. Iterate until `better` or the human resolves the
     thread.
   - `timeout` → do not guess. Report that no human verdict arrived and stop.

5. **Never claim behavioral success before the human verdict.** The verdict *is*
   the test result for this task.

Operator setup (done outside the model, on the physical iPad — not a simulator).
The verifier round-trips over `xcrun devicectl ... copy` into the app's data
container, so it needs a **Debug**-signed install (`get-task-allow`) and a pinned
device session:

1. Pin the iPad from this worktree:
   `DeveloperTools/device-preflight.sh --device <UDID>`
   (writes `.tubernotes-device-session.json` at the worktree root).
2. Install and launch the **Debug + `REVIEW_HARNESS`** build (scheme `TuberNotes`)
   on that pinned iPad. Release/distribution builds cannot be container-copied and
   will not receive threads.
3. Register `PencilFixtureMCP` as this Codex session's MCP server, run **from this
   worktree** so `ROOT` resolves here (`python -m server` under
   `DeveloperTools/PencilFixtureMCP`).

The push (`create_feedback_thread` / `ask_thread_question`) writes the thread into
`Documents/feedback-threads/` on the iPad, where `FeedbackThreadSession` shows the
"Your turn" card; `await_thread_response` pulls the human's answer back off the
device. Bundle id `com.tubernotes.app` must match the installed app.

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

Validate user-visible behavior only in the actual normal Release app on Phillip's explicitly named iPad. Debug scenarios, recorded routes, fixture-driven UI, `DeveloperTools/verify-scenario.sh`, `DeveloperTools/review-session.py`, and `DeveloperTools/PencilFixtureMCP` are disabled and must not be used as acceptance evidence — **except** the human review loop re-enabled for this worktree under "Human-in-the-loop review is ACTIVE on this worktree" above, which does produce acceptance evidence. Phillip performs any required human interaction directly in the normal app. Never claim behavioral success before his verdict.

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
