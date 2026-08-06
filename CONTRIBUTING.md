# Working here

`AGENTS.md` says what the rules are. This file says how to actually work here
without producing confident nonsense. Read both before touching code. It
applies to humans and agents alike.

New to the repo? `README.md` gets you from a clone to a running app in two
commands. Start there, then come back.

## The loop

`Docs/Queue.md` is Phillip's notebook for tracking state, not a work
assignment system. Skim it to see what's known and what's already being
tracked, but decide what to work on from what the codebase actually needs —
not by claiming a numbered slot.

1. Read `Docs/Contract.md`. If `Docs/Queue.md` already describes the problem
   you're about to touch, read that entry too — it likely has context
   (why it's hard, what blocks it, what's been ruled out).
2. Before editing, state: acceptance evidence, files in scope, non-goals,
   stopping condition.
3. Edit.
4. Build and test locally. Push, open a pull request, and read what CI says.
5. On green and approved, put in the description what evidence you actually
   have — and what you don't. Anything found and not fixed is recorded
   before you stop — see "Where a fact goes" below. If your change resolves
   or changes the state of something written in `Docs/Queue.md`, update or
   remove that entry in the same pull request so Phillip's notes stay true —
   but the queue entry is a courtesy update, not the gate that decides
   whether the PR merges.

You are not done when the code compiles. You are done when CI is green, a
reviewer has approved, and the item's human-only checks have been handed to a
maintainer.

**Do not write a progress document.** There is no status board, no session log,
and no milestone file, deliberately — the same fact in two places is the same
fact that will disagree with itself. Commit messages and pull requests carry
the narrative, CI carries the evidence, and `Docs/Queue.md` shrinks. If you
catch yourself wanting to record that something is complete, delete it instead.

If a rule itself changed, rewrite `Docs/Contract.md` in place — present tense,
no "superseded", no history — and tag the commit `CONTRACT:`. Cite contract
sections by name; there are no numbers.

## Where a fact goes

Every fact has exactly one home, chosen so it cannot drift from what it
describes. There is no decisions log and no defect list.

| Fact | Home | Why there |
|---|---|---|
| A rule that is in force | `Docs/Contract.md` | normative, present tense |
| **Why** that rule exists, where a reader would otherwise get it wrong | next to the rule — in `Contract.md` or at the code site | cannot drift from what it explains |
| Why we chose something, as history | the commit message | `git log -p` has dates and authorship |
| A defect we are not fixing now | a `KNOWN DEFECT:` block **at the code site** | moves with the code, dies when fixed |
| A claim we have not earned | `Docs/Unproven.md` | belongs to no single line of code |
| Phillip's read on what's open, risky, or blocked | `Docs/Queue.md` | his notebook, not a queue an agent must drain in order |

The test for whether a "why" is worth writing down: **would a new contributor
make a mistake without it?** If yes, it is a live constraint — put it next to
the rule. If no, it is archaeology, and `git` already has it.

An append-only decisions log keeps reversed entries readable as if still in
force; a defect list pinned to line numbers must be re-verified against source
on a schedule. Both structures rot by design, not through neglect — which is
why neither exists.

## CI and review are the arbiter

The generate/build/test commands live in `AGENTS.md`, under **Build** — their
one home. `.github/workflows/ci.yml` runs exactly those on every pull request and on
pushes to `main`. On failure it writes the compile errors and failed assertions
onto the run page and emits them as annotations on the pull request diff, then
uploads the logs — so a contributor reads the verdict in a browser rather than
inside a downloaded zip.

**CI calls no script in `Tools/`, deliberately.** What "green" means has to stay
readable without running anything we would factor into it, so the workflows
spell out `xcodebuild` and duplicate their few guard lines rather than sharing
a program. `Tools/` is a convenience; it never decides whether work is done.

The simulator is pinned on purpose. A moving destination makes results
incomparable between runs, and runner images have shipped an Xcode whose
matching iOS runtime was absent — which surfaces from `xcodebuild` as an opaque
destination error.

`Tools/pinned-simulator` holds that name and is the only place it is written —
both workflows and the commands in `AGENTS.md` read it. It is a bare value with no `KEY=`,
because the device name contains spaces and parentheses and so is not valid
shell to `source`. There is no fallback anywhere: a missing pin fails the run
naming the file, per the contract's rule that nothing is silently defaulted.

**Green CI means it compiled and the tests passed. That is all it means.** It
is not evidence about ink, and saying otherwise in a pull request is lying
about the state of the project.

## Device evidence

The simulator has no Apple Pencil. Drawing, erasing, palm rejection, and
pressure cannot be proven off-device at all, so some changes are not finishable
by CI no matter how green it is.

Evidence from a physical iPad is **required** when a pull request touches the
canvas runtime or the editor session:

| File | Why |
|---|---|
| `PageCanvasController.swift` | the live PencilKit canvas — ink, pan, zoom |
| `PagedCanvasController.swift` | paging, the live window, gesture arbitration |
| `EditorSession.swift` | page turns, autosave timing, dirty tracking |
| `EditorLifecycle.swift` | the background-execution lease and flush |

It is **not** required for `DocumentStore`, `DocumentIndex`,
`PageGeometry`, `CanvasLog`, tests, docs, or tooling. Correctness there is
settled by a test.

The pull request template asks which case you are in. Answering "required but
not done" is a legitimate answer; add it to `Docs/Unproven.md` and say so.
Quietly skipping it is not.

Pencil feel, stroke fidelity, palm rejection, and pan/zoom quality remain a
maintainer's verdict. Record the journey, produce the evidence, and leave the
verdict alone.

## Device work

```bash
Tools/device --check      # every precondition, then stop
Tools/device --install    # ...then build and install, but no capture session
Tools/device              # ...then build, install, launch, and capture
```

One command, every precondition: toolchain, signing, and the iPad itself. It
distinguishes two kinds of not-ready, and so does its exit code:

| Verdict | Exit | Meaning |
|---|---|---|
| READY | 0 | you can build and run on the iPad |
| BLOCKED | 2 | something physical must change — plug in, unlock, trust |
| MISCONFIGURED | 1 | something in this repo or toolchain is wrong |

BLOCKED is not a failure; MISCONFIGURED is. Confusing the two is how someone
ends up "fixing" a signing config to work around an unplugged cable.

Every check prints a remedy line. Notable ones: Developer Mode status, pairing
state, DDI availability, whether iPadOS is newer than the installed SDK (that
Xcode simply cannot install to it), and whether the bundle identifier has
drifted onto `com.tubernotes.app` — which would overwrite the behavioral
reference app on the iPad the next time anyone installs.

Diagnose with this before touching `project.yml`. Most device failures are a
locked screen.

There is no separate preflight command, on purpose: nobody runs preflight for
pleasure, they run it after a device build already failed, and a two-command
dance is what gets skipped under pressure.

### What the capture gives you

A plain run builds for that specific iPad, installs, and launches with
`devicectl --console` and `TN_TRACE=1`, streaming the app's own trace to
`Artifacts/device/<utc>-<sha>/console.log`. Ctrl-C ends the session and prints
the build and device identity plus what the app actually reported: whether the
session came up, whether a touch reached the canvas, how many saves happened and
**how many page files each one wrote out of how many exist** — which is how
"the save trace names only changed pages" becomes checkable rather than
asserted.

Re-read any past capture with `Tools/device --digest <console.log>`.

Two things it will not do. It renders **no verdict about your branch** — the
last line it prints says so, because ink is a maintainer's judgment and a tool
that scored it would be usurping one. And it is **never consumed by CI**:
everything it writes comes from an untrusted machine and is trivially forgeable,
so a human cites it and nothing verifies it.

If the capture says `NO TRACE CAPTURED`, believe it. `CanvasLog`'s stderr mirror
is DEBUG-only and gated on `TN_TRACE`, so a Release build emits nothing — and a
summary of an empty stream would otherwise read as "nothing went wrong."

## Rules for any check you add

These rules apply to tests and CI steps just as well.

**A check that has never failed is decoration.** Before trusting a new one,
deliberately break the thing it guards, confirm it fails, then revert. A check
can be dead without looking it — a `|` inside a regex collides with a `|`
field separator and silently truncates the pattern — and only a planted
violation exposes it.

**Fail closed, not open.** Express a rule as an *allowlist of what may do the
forbidden thing*, not a blocklist of known-bad names, so a new file breaks the
check without anyone remembering to update anything. A blocklist only catches
violations someone already thought of.

**A green run with zero tests is a false pass.** `xcodebuild` exits 0 when a
scheme runs nothing, so `ci.yml` greps the log for evidence tests actually
executed. Apply the same suspicion anywhere a tool can succeed by doing
nothing.

**Watch for false positives too.** A check that cries wolf gets disabled by the
next person, which is worse than not having it.

## Free checks — use them

- **Swift 6 language mode.** Compiler-enforced actor isolation turns "no work on
  the Pencil path" from a code-review opinion into a build error.
- **Warnings as errors** (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). A deprecated call
  becomes a build error the moment it is written, not a review comment.
- **Runtime ownership.** Each `EditorSession` constructs and retains its canvas
  controller once. There is one controlled `PKCanvasView` construction site,
  but no process-global singleton: future scenes and virtualized page editors
  must be able to own independent active canvases.

## When a test fails, find out who is wrong

The assertion is wrong at least as often as the code. `UIScrollView` reports
`contentSize` already multiplied by `zoomScale`: an assertion expecting the
unzoomed page width sees `612 × 1.3399 = 819.99` and reads as PencilKit
ignoring page space — but the implementation is right and the assertion is
wrong. "Fixing" that in the code silently corrupts page space to view space,
the precise failure the data contract exists to prevent.

Diagnose before you edit. Compute the number the framework gave you and see
whether it means something.

## Do not test what the environment cannot express

Some properties are simply not observable here, and pretending otherwise
produces a green run that proves nothing:

- `undoManager` walks the responder chain, so an unhosted controller always
  reports `nil`. Undo/redo is device evidence, not a unit test.
- The simulator has no Apple Pencil. Drawing, erasing, palm rejection, and
  pressure cannot be proven off-device at all.

When you hit one of these, do not weaken the assertion until it passes. Delete it
and record the gap explicitly in `Docs/Unproven.md` as outstanding device evidence.

## Project structure

- **`project.yml` is the only project source** — stated in `AGENTS.md`, under
  **Build**, so agents see it every session. Never edit the project in Xcode
  and expect it to survive.
- **Anything that differs per developer lives in `Local.xcconfig`**, which is
  gitignored and written by `Tools/setup`. Signing team, bundle prefix, and
  which iPad is yours are there. Putting a team ID in `project.yml` makes every
  peer's checkout permanently dirty, so a signing fix belongs in
  `Local.xcconfig` every time. `Local.xcconfig.example` carries a deliberately
  invalid placeholder team rather than a real one — a real ID there would be one
  person's, and anyone who copied the file instead of running `Tools/setup`
  would sign against it and get an error naming the wrong cause.
- Bundle ID defaults to `com.tubernotes.greenfield`, deliberately different from
  the reference app's `com.tubernotes.app` so installing this never replaces it
  on the iPad. Change the prefix if two people share one iPad.
- `Artifacts/` holds build and test logs and captured device sessions. It is
  regenerated and gitignored — cite paths from it as evidence, never commit it.
- **`Tools/` is three files and no shared library.** `pinned-simulator` is one
  line of data; `setup` gets a clone to an Xcode window; `device` runs the iPad
  loop. There is deliberately no shared library: a library that does work at
  *source* time hands its caller values cached before the caller's world
  exists. Two scripts sharing a few lines of `sed` should duplicate them.
  Nothing in `Tools/` decides whether work is done.

## Scope discipline

The contract's hardest rule to follow is *smallest change that proves the
queue item*. The pressure to add the next abstraction is constant and it always
feels justified. Concretely:

- No `import UIKit` or `import PencilKit` outside the canvas runtime and
  `EditorLifecycle`.
- The live canvas count is bounded by a small constant and must not grow with
  page count.

The first is machine-checked by `TuberNotesTests/ContractStructureTests.swift`,
along with the single `PKCanvasView` construction site and file I/O confined to
`DocumentStore`. The second is not, and neither is the forbidden-pattern list —
those hold only as far as review holds them. `Docs/Unproven.md` says which is
which.

Those checks are tests rather than a script on purpose. They run inside the
thing that already decides, they fail like any other test so no second verdict
vocabulary exists, and **the checker has its own tests**: a structural check
can go silently dead, or fail on a *comment* that merely names the API it
polices, and each failure mode stays caught only by a permanent
planted-violation test. If you add a rule there, add the planted-violation
test with it.

## Ask instead of guessing

Some decisions cannot be derived from the documents, and guessing at them
silently wastes the work: which iPad to trust when the Mac is paired with
several, how far to go in one session, whether a rule covers developer tooling
as well as application code. Guessing produces work that gets thrown away. Ask,
then proceed.

Never make the human-only judgments. Pencil feel, stroke fidelity, palm
rejection, and pan/zoom quality are judged by a maintainer on the device.
Record the journey, produce the artifacts, and leave the verdict alone.
