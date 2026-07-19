# WL-E — Verification, review packets, demo reliability (continuous)

Status: not-started
Owner subsystem: `DeveloperTools` + coordinator
Depends on: rides alongside every other line.
Subagent-eligible: only for isolated verifier/test additions with a named
scenario and expected evidence; review judgment stays with the coordinator.

## Objective

Keep the harness truthful as scenarios upgrade, and burn down the human-review
debt using the existing packet guides so M4 can gate.

## Recurring duties

1. **Verifier expectations track behavior.** As WL-A/B/C upgrade `lasso-crop`,
   `agent-recorded-*`, `hero-recorded`, and add `persistence-relaunch`, extend
   `DeveloperTools/verify-scenario.sh` and the runtime-evidence assertions in
   the same change as the behavior. A PASS must keep meaning "rendered runtime
   state," never just a scenario marker (`9347406` established this).
2. **Review-guide freshness.** `Docs/ReviewGuides/*` status tables are the
   public truth of what is implemented vs. stubbed. Update them when a
   capability changes state; never let a table overstate readiness.
3. **Device review debt** (run via `human-device-loop`, per
   `Docs/DeviceWorkflow.md`, one journey per visible session):
   - Pencil drawing feel (DocumentsAndInk — physical iPad required)
   - Notebook add-page feel (DocumentsAndInk)
   - Spatial feel and label taste (SpatialAndPins)
   - After WL-B step 3: the real hero journey (status clarity, Pin
     readability, timing)
   - After WL-C: creation/import flow feel
4. **Tooling tests stay green:** PencilFixtureMCP + DeveloperTools test suites
   run with the pinned venv Python before tooling commits.

## M4 gate (demo candidate — final duty)

- All deterministic hero scenarios PASS.
- Complete hero path succeeds on the pinned demo iPad **three consecutive
  runs**; no crash, no secret exposure.
- Mechanical spatial checks pass after pan, zoom, page turn, return.
- Human has reviewed Pencil feel, visual taste, interaction timing.
- Remaining issues documented as non-critical or explicitly accepted, in the
  final Evidence Packet.

## Stop conditions

- Any verifier claiming more than rendered reality → stop the affected line,
  fix truthfulness first.
- Device/host divergence during a review journey → stop per AGENTS.md.

## Session log

- (none yet)
