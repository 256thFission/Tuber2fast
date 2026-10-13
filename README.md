# TuberNotes

An iPad notebook canvas targeting GoodNotes parity.

## Setup

You need Xcode 26 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Then:

```bash
Tools/setup               # writes Local.xcconfig, generates the project
open TuberNotes.xcodeproj
```

`Tools/setup` fills in your own signing team from the Apple Development
certificate in your keychain. If you have no certificate yet, sign in at
**Xcode → Settings → Accounts** and re-run it; if you belong to more than one
team, it writes a placeholder and asks you to pick one in `Local.xcconfig`. It
never guesses at a signing identity.

Two files are yours alone and are gitignored — never commit either:

| File | Why it is local |
|---|---|
| `Local.xcconfig` | Your team ID, bundle prefix, and which iPad is yours. Peers have different ones. |
| `TuberNotes.xcodeproj` | Generated from `project.yml`, the only project source. |

### Working on a physical iPad

```bash
Tools/device --check      # diagnose the toolchain, signing, and the iPad
Tools/device              # build, install, launch, and capture the session
```

`--check` explains a signing or connection problem rather than leaving you to
guess: it distinguishes **BLOCKED** (plug in, unlock, trust — exit 2) from
**MISCONFIGURED** (something in this repo is wrong — exit 1), and prints a
remedy for each. Without `--check` it goes on to build for that iPad, install,
launch with the app's trace stream attached, and print what the app reported
when you end the session with Ctrl-C.

It auto-selects the one iPad paired with your Mac and refuses to choose when
there are several; set `TN_DEVICE_NAME` in `Local.xcconfig` if that is you.

It renders no verdict about your branch, deliberately. Ink is judged by a human.

## CI decides when work is done

Phillip pushes to `main`, and CI builds the app and runs the tests on a
pinned simulator. Green on the pushed commit, and the item is done. There are
no pull requests.

Run the same thing locally before you push:

```bash
xcodegen generate
xcodebuild test -project TuberNotes.xcodeproj -scheme TuberNotes \
  -destination "platform=iOS Simulator,name=$(< Tools/pinned-simulator)"
```

`Tools/pinned-simulator` is the only place that name is written. The workflows
read the same file, so the docs and CI cannot drift apart, and neither has a
fallback: a missing pin fails the run rather than quietly substituting a
different device.

**Green CI means it compiled and the tests passed. That is all it means.** The
simulator has no Apple Pencil, so ink, pressure, and palm rejection cannot be
proven off-device at all. Changes to the canvas runtime need evidence from a
real iPad — `AGENTS.md`, under **Definition of done**, says which.
[`CONTRIBUTING.md`](CONTRIBUTING.md) explains the loop around it.

## Reading order

Four documents, one job each. CI and `git` hold the state; these hold only what
those cannot.

| File | Answers | Shape |
|---|---|---|
| [`AGENTS.md`](AGENTS.md) | What are the rules? | Short, for humans and agents alike |
| [`Docs/Contract.md`](Docs/Contract.md) | What is true **now**? | Normative, present tense, no history |
| [`Docs/Queue.md`](Docs/Queue.md) | What does Phillip think is **open**, and why? | His notebook, kept current — not a work assignment |
| [`Docs/Unproven.md`](Docs/Unproven.md) | What have we **not earned**? | Claims without evidence. No line numbers, no expiry date |

Before you write application code, read `AGENTS.md` and `Docs/Contract.md`.
`Docs/Queue.md` is worth a skim for context, but it doesn't gate what you're
allowed to work on — fix what the codebase needs. Some of the contract's
structural rules are machine-checked as ordinary tests, in
`TuberNotesTests/ContractStructureTests.swift`; what is held by review alone
is in [`Docs/Unproven.md`](Docs/Unproven.md).

**Why** a rule is the way it is lives next to the rule, in `Docs/Contract.md`
or at the code site. There is no decisions log: `git log -p` is the history,
with dates and authorship no hand-maintained file has. Known defects
live in the code as `KNOWN DEFECT:` blocks — `grep -rn "KNOWN DEFECT"
Modules/ TuberNotesApp/`.

Two rules keep this from rotting:

- **The contract carries no history.** When a rule changes, that file is
  rewritten and `git log -p` is the record. Nothing is marked superseded.
- **Done-ness is never a word in a document.** Work is done when Phillip has
  pushed it and CI is green on that commit. `Queue.md` gets updated to
  match, as a courtesy to whoever reads it next — it's evidence of nothing on
  its own.

[`Docs/Forks/`](Docs/Forks/) is background — deferred design directions for
gestures and PDF/image, so a later work item need not rediscover them. Not
required reading, and it authorizes building nothing early.
