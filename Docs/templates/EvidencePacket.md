# Evidence packet

Fill this for user-visible TuberNotes changes. Keep it compact. Point to artifacts; do not paste full logs.

## Objective

-

## Changed files

-

## Diff summary / scope check

- Summary:
- Final diff stayed in requested scope: yes / no
- Ownership violations or unrelated churn:

## Build

- Result: pass / fail
- Device preflight result:
- Pinned physical-device ID:
- Session snapshot: `.tubernotes-device-session.json` / copied artifact path
- Log path (if any):

## Verification

- Command / loop used: `DeveloperTools/verify-scenario.sh …` or manual
- Scenario(s):
- Expected state:
- Physical-iPad inspection performed:
- Screenshot path(s): collected path / not collected
- Attached console status: collected path / not collected
- Device crash diagnostics: collected path / not collected
- Artifact directory:

## Mechanical checks

- [ ] Intended content present
- [ ] No clipping of primary UI
- [ ] No unintended overlap
- [ ] No crash / immediate exit
- [ ] Deterministic Pin locations (if applicable)
- [ ] No Pin drift across supported viewport changes (if applicable)

## Human device interaction (if used)

Use Skill `human-device-loop` / PencilFixtureMCP when Pencil feel, authentic strokes, or taste judgments are required. See `Docs/Development.md` § Human device loop.

- Request id:
- Kind: `pen-fixture` / `review`
- Status: `recorded` / `answered` / still awaiting
- Verdict (`looks-good` / `needs-work` / `blocked`):
- Optional `humanNotes`:
- Fixture path (if any):
- Collected artifact dir (`.pencil-fixtures/collected/…`):

## Feedback wake (if used)

- Feedback thread ID:
- Watch status: `watching` / `closed` / `feedback-created-but-not-armed`
- Last acknowledged sequence:
- Wake ID:
- Delivery: active wait / event bridge / one-minute heartbeat fallback
- Originating Codex task resumed automatically: yes / no
- Desktop/CLI host divergence: none / details

## Human-only checks still required

- [ ] Apple Pencil feel / latency (real iPad) — or collected above
- [ ] Visual taste — or collected above
- [ ] Interaction / animation quality — or collected above
- [ ] Shared contract or architecture review

## Stop reason / unresolved issues

-
