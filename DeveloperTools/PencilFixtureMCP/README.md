# PencilFixtureMCP

Development tooling only — not the in-product AI agent.

Pushes agent interaction requests into the **Debug** TuberNotes app on a connected simulator or physical iPad. The human sees the agent prompt in an in-app banner, completes the request on device, and the app indexes the result under Documents. Agents collect durable JSON; the human does no Mac-side file copying.

Canonical docs: `Docs/Development.md` § Human device loop, Skill `human-device-loop`, evidence fields in `Docs/templates/EvidencePacket.md`.

## Tools

| Tool | Purpose |
|---|---|
| `request_pen_fixture(description, scenario?, prefer_device?)` | Push a Pencil capture request and launch the app |
| `request_human_review(prompt, title?, scenario?, prefer_device?)` | Push a review request for looks-good / needs-work / blocked |
| `await_interaction(request_id, timeout_seconds?)` | Poll until the human finishes; return fixture/verdict/index |
| `collect_interaction(request_id)` | One-shot pull of completed artifacts |
| `list_interactions()` | On-device index + local request catalog |
| `list_pen_fixtures()` / `get_pen_fixture(name)` | Read fixtures |
| `replay_pen_fixture(name)` | Install fixture and relaunch replay seam |

## Feedback model

| Kind | Required on device | Optional |
|---|---|---|
| `pen-fixture` | One Apple Pencil stroke | Verdict + free-text `humanNotes` after capture |
| `review` | Verdict: `looks-good` / `needs-work` / `blocked` | Free-text `humanNotes` |

Text is never required. Collected payloads include `status`, `verdict`, `humanNotes`, `fixtureName` / fixture JSON, and the `pen-fixtures/index.json` entry.

## On-device layout

```text
Documents/
  agent-requests/
    pending/<id>.json
    completed/<id>.json
  pen-fixtures/
    <name>.json
    index.json
```

Mac-side mirror (gitignored): `.pencil-fixtures/requests/`, `.pencil-fixtures/collected/`.

Reviewed fixtures can be copied into `Fixtures/` for the repo.

## Human path

1. Agent calls `request_pen_fixture` or `request_human_review`.
2. App opens on the connected test device with the prompt at the top.
3. Human draws once and/or chooses a verdict (optional note).
4. Agent calls `await_interaction` / `collect_interaction` and records results in the evidence packet.

No environment-variable fiddling or container browsing is required of the human.

## Install

```sh
cd DeveloperTools/PencilFixtureMCP
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

Register `pencil-fixture-mcp` as a stdio MCP server. Prefer a physical iPad when available; the tools fall back to the booted simulator.
