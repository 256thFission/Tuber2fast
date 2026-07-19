# Verification tooling review guide

## Purpose and current status

Use this guide to review the scenario verifier, runtime-evidence boundary, failure
truthfulness, and related developer checks.

| Capability | Status |
|---|---|
| Pinned-device build/install/launch | **IMPLEMENTED + VERIFIED** |
| Fixture-declaration assertions | **IMPLEMENTED + VERIFIED** |
| Separate runtime-rendered assertions | **IMPLEMENTED + VERIFIED** |
| Per-launch nonce rejecting stale evidence | **IMPLEMENTED + VERIFIED** |
| Physical screenshot, attached console, and device crash diagnostics | **OUTSIDE VERIFIER; REPORT SEPARATELY** |
| Accumulated failure state and forced-failure check | **IMPLEMENTED + VERIFIED** |
| Pixel comparison, automated navigation, drift measurement, taste | **NOT IMPLEMENTED BY VERIFIER** |

Relevant implementation:

- `DeveloperTools/verify-scenario.sh`
- `DeveloperTools/tests/test_verify_scenario_truthfulness.py`
- `TuberNotes/DeveloperSupport/DevelopmentScenario.swift`
- `Docs/Development.md`

## Review mode

This group normally uses **harness conformance**, not a visible human review
session. Do not create feedback threads or Review Runs for queue state, marker
contents, nonce matching, exit codes, console capture, or crash scanning.

If physical-iPad inspection reveals a visual question, route that question to the owning
Documents/Ink, Spatial/Pins, or Agent/Knowledge guide instead.

## Mechanical packet

Run:

```sh
bash -n DeveloperTools/verify-scenario.sh
python3 -m unittest DeveloperTools.tests.test_verify_scenario_truthfulness

DeveloperTools/PencilFixtureMCP/.venv/bin/python -m unittest discover \
  -s DeveloperTools/PencilFixtureMCP/tests -p 'test_*.py'
python3 -m unittest discover -s DeveloperTools/tests -p 'test_*.py'

DeveloperTools/device-preflight.sh --device <device-id>
SKIP_BUILD=1 DeveloperTools/verify-scenario.sh pin-drift
SKIP_BUILD=1 DeveloperTools/verify-scenario.sh hero-recorded
```

Then prove the negative path in isolation:

```sh
FORCE_MECHANICAL_FAILURE=1 SKIP_BUILD=1 \
  DeveloperTools/verify-scenario.sh blank-canvas
```

The negative command must exit nonzero, report `MECHANICAL_ASSERTION: FAIL`, and
end with `RESULT: FAIL`. Its failure is expected evidence, not a broken test run.

For a broad release-candidate packet, run every allowlisted scenario from
`DeveloperTools/verify-scenario.sh --help`. For a bounded change, run the owning
guide's scenarios plus one forced-failure check when verifier logic changed.

## Assertions the reviewer must inspect

- Scenario marker and runtime-rendered evidence are separate files.
- Both carry the verifier's current per-launch nonce.
- App-wired scenarios require exact surface, page, pen-fixture, and annotation state.
- `hero-recorded` reports `partial-stub`, never App-wired acceptance.
- `MECHANICAL_ASSERTION: PASS` is reachable only when accumulated `pass == 1`.
- A verifier PASS does not claim pixel correctness, navigation coverage, Pin-drift
  measurement, screenshot/console/crash coverage, Apple Pencil feel, or visual taste.

## Evidence and stop conditions

Produce `Docs/templates/EvidencePacket.md` with command results, the pinned-device
session artifact, dynamic artifact directories, explicit collected/uncollected
screenshot/console/crash status, and the expected forced-failure
artifact. Stop on a stale-evidence acceptance, false PASS, missing runtime file,
scenario metadata divergence, device-session mismatch, or any
claim beyond the verifier's documented limits.
