# PC-21 — Magic Lasso compact command strip

Status: **command strip implemented and Release-delivered — awaiting Phillip's verdict**

Target branch: `main`

Owner: Notebook presentation for the existing Magic Lasso result. Regular lasso,
SpatialCanvas geometry/Pencil capture, AI runtime, Pins, and persistence remain
unchanged.

## Objective and user-visible outcome

Replace the Magic Lasso's wide gray pill menu with a compact monochrome command
strip—Explain, Check, Ask, and Close—spatially attached to the completed Magic
Lasso. Ask expands from the same restrained surface; analysis remains in the
same footprint.

## Scope

- `TuberNotes/Notebook/NotebookView.swift`
- one focused presentation contract check
- this child plan and the PC-21 parent entry

## Non-goals and dependencies

- Do not combine, remove, or alter the regular and Magic Lasso tools.
- No selection/crop geometry, Pencil gesture, prompt/provider, authentication,
  Pin placement, persistence, archive, or response-content changes.
- Preserve PC-20 Pin work and unrelated untracked `.claude/` content.

## Acceptance evidence and stop conditions

- Completed Magic Lasso shows no wide `Selected region` glass pill and no blue
  pill buttons.
- One compact charcoal surface contains text-first actions and subtle separators;
  Close remains explicit. There are no gradients, glows, circles, or pill buttons.
- Ask expands locally; progress, error, and notice states remain readable without
  returning to the page-wide pill.
- The surface clamps within the logical page and chooses above/below based on
  available room.
- Focused checks and exact-device signed Release delivery pass. Phillip owns
  final Pencil, animation, placement, clipping, and taste judgment.

## Session log

- 2026-07-21 — Phillip rejected the first direct-chat delivery because opening
  the sidebar moved the page and conversation escalated into a page-blocking
  full-chat window. Corrected the interaction contract: notebook and toolbar
  geometry remain fixed; the 340-point Pin Chat overlays only the trailing edge;
  all new, continued, Magic-Lasso-originated, and Pin-originated conversations
  stay inside it with no dimming or modal takeover. Phillip's normal-app verdict
  remains required. Focused checks pass 11/11; signed Release build, install,
  normal launch, and process presence pass on exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Evidence is under
  `tmp/verify/pc21-noninterrupting-sidebar/`.
- 2026-07-21 — Added Phillip's requested independent chat entry point: a
  stateful top-bar button opens and closes the existing Agent sidebar directly,
  activating the selected/default Agentic Layer when needed. This does not
  change either lasso tool, sidebar composition, AI runtime, Pins, or spatial
  behavior. Focused checks pass 3/3; signed Release build, install, normal
  launch, and process presence pass on exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Evidence is under
  `tmp/verify/pc21-chat-sidebar-button/`; Phillip's direct open/close,
  clipping, and placement verdict remains.
- 2026-07-21 — Phillip showed that the redeployed restored build still contained
  the old bulky Magic Lasso pill. Corrected scope: redesign only the existing
  Magic Lasso post-selection presentation; regular Lasso remains untouched.
- 2026-07-21 — Replaced the page-wide glass card and bordered pill buttons with
  three 46-point dark circular actions fanned above a 44-point cyan-to-purple
  sparkle orb. The outer menu is transparent; only actions, labels, explicit
  Close, Ask input, progress, and status surfaces receive compact opaque backing.
  Ask expands locally, and submitting morphs the actions into a progress orb.
- 2026-07-21 — Focused separation/presentation plus PC-20 checks pass 10/10 and
  `git diff --check` passes. Two pre-existing restored-baseline lasso tests remain
  stale against current source naming/wiring and were not altered. Exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117` passed preflight; signed Release built,
  installed, normally launched, and remained in the process list. Evidence is
  under `tmp/verify/pc21-magic-lasso-radial/` and
  `tmp/build/pc21-magic-lasso-radial-device/`. Phillip's direct visual/Pencil
  verdict remains.
- 2026-07-21 — Phillip rejected the radial gradient/orb direction as tacky and
  "Gemini-y" and selected the monochrome command-strip alternative. Reopened
  PC-21 to replace only that presentation while preserving both lasso tools and
  every behavior boundary.
- 2026-07-21 — Replaced the rejected radial/orb UI with a single 48-point-high
  opaque charcoal strip containing monochrome SF Symbols, text-first Explain,
  Check, and Ask actions, hairline separators, and Close. Removed every gradient,
  glow, circle, badge, and pill from the Magic Lasso menu. Ask unfolds as a
  compact matching field beneath the strip; submitting changes the strip itself
  to a small spinner plus `Analyzing…`.
- 2026-07-21 — Focused separation/presentation plus PC-20 checks pass 10/10 and
  `git diff --check` passes. Signed Release built, installed, normally launched,
  and remained in the process list on exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`. Current artifacts are under
  `tmp/verify/pc21-magic-lasso-command-strip/` and
  `tmp/build/pc21-magic-lasso-command-strip-device/`. Phillip's visual/Pencil
  verdict remains.

## Evidence packet — 2026-07-21

- Objective/changed files: Magic Lasso post-selection presentation in
  `NotebookView.swift`, one focused source contract, and PC-21 plan records.
- Diff scope: presentation sizing, placement bounds, radial actions, local Ask,
  compact progress/status, and accessibility. Regular Lasso, Magic Lasso capture,
  SpatialCanvas, geometry, AI/provider/auth, Pins, persistence, and archives are
  unchanged. PC-20 remains intact; `.claude/` remains untouched.
- Build/delivery: focused checks 10/10 PASS; diff hygiene PASS; signed Release
  build/install/normal launch/process query PASS on exact iPad
  `2DD98ECC-A26A-5730-943B-01DD63DC4117`.
- Expected journey: use the separate Magic Lasso, close a valid loop, see the
  compact action arc and sparkle anchor, invoke Explain/Check, expand Ask, or
  clear; submitting collapses to Reading selection progress.
- Artifacts: `tmp/verify/pc21-magic-lasso-radial/focused-tests-final.log`,
  `preflight.log`, `build.log`, `install.log`, `launch.log`, `processes.log`, and
  the Release app under `tmp/build/pc21-magic-lasso-radial-device/DerivedData/`.
- Console/crash: no attached console/crash report; launch and process presence
  establish no immediate exit only.
- Human-only checks: actual arc placement near edges/toolbar, overlap, Ask keyboard,
  Pencil hit targets, transitions, progress/error composition, and visual taste.
- Stop reason: implementation and delivery are complete; Phillip owns final
  normal-app visual and behavioral acceptance.

## Command-strip correction evidence — 2026-07-21

- Objective: replace the rejected radial/orb composition with the selected
  monochrome command-strip direction while retaining separate lasso tools.
- Changed presentation: 300×50-point default strip, monochrome icons/text,
  separators, explicit Close, matching local Ask field, and in-strip progress.
- Scope: `NotebookView.swift`, the focused presentation check, and PC-21 plan
  records only beyond the already-present PC-20 work. No regular/Magic Lasso
  selection behavior, geometry, Pencil, AI runtime, Pins, persistence, or archive
  changes; `.claude/` remains untouched.
- Evidence: focused checks 10/10 PASS; diff hygiene PASS; exact-device signed
  Release build/install/normal launch/process presence PASS. Artifacts are under
  `tmp/verify/pc21-magic-lasso-command-strip/` and
  `tmp/build/pc21-magic-lasso-command-strip-device/`.
- Human-only: actual placement, clipping, Ask keyboard composition, touch/Pencil
  targets, animation, and visual taste. Phillip's verdict remains pending.
