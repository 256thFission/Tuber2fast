# Working here

`AGENTS.md` says what the rules are. This file says how to actually work here
without producing confident nonsense. Read both before touching code. It
applies to humans and agents alike.

## The loop

1. Read `Docs/Architecture/DataContract.md`, the active milestone, and `Docs/Plan/PLAN.md`. Identify the single `PLAN.md` line you are working.
2. Before editing, state: acceptance evidence, files in scope, non-goals,
   stopping condition.
3. Edit.
4. Run `Tools/gate.sh`. Read the verdict.
5. Append a dated `PLAN.md` session entry that says what evidence you actually
   have — and names what you don't.

You are not done when the code compiles. You are done when the gate says PASS
and the milestone's human-only checks have been handed to a maintainer.

## The gate is the arbiter

```bash
Tools/gate.sh          # every gate, in order
Tools/gate.sh 10 30    # only gates with those numeric prefixes
```

Three verdicts, and the distinction is the whole point:

| Verdict | Exit | Meaning |
|---|---|---|
| PASS | 0 | Every gate ran and passed |
| INCOMPLETE | 2 | Nothing failed, but a gate skipped — evidence is missing |
| FAIL | 1 | A contract was violated |

**INCOMPLETE is not PASS.** The device gate skips whenever the iPad is not
connected, and almost every interesting claim in this milestone (Pencil input,
palm rejection, pan/zoom feel) can only be proven there. If you report
INCOMPLETE as success you have lied about the state of the project.

The runner stops at the first FAIL on purpose. Downstream evidence gathered
after a broken structural check is not evidence, it is material for
cherry-picking.

## Before device work

```bash
Tools/preflight-device.sh
```

One command, every precondition: toolchain, signing, and the iPad itself. It
distinguishes two kinds of not-ready, and so does its exit code:

| Verdict | Exit | Meaning |
|---|---|---|
| READY | 0 | `Tools/gate.sh 60` can run |
| BLOCKED | 2 | Something physical must change — plug in, unlock, trust |
| MISCONFIGURED | 1 | Something in this repo or toolchain is wrong |

BLOCKED is a skip; MISCONFIGURED is a failure. Confusing the two is how an agent
ends up "fixing" a signing config to work around an unplugged cable.

Gate 60 delegates to this tool, so a skip always names its actual cause. Every
check prints a remedy line. Notable ones: Developer Mode status, pairing state,
DDI availability, whether iPadOS is newer than the installed SDK (that Xcode
simply cannot install to it), and whether the bundle identifier has drifted onto
`com.tubernotes.app` — which would overwrite the behavioral reference app on the
iPad the next time anyone installs.

Diagnose with this before touching `project.yml`. Most device failures are a
locked screen.

## Rules for the gates themselves

**A check that has never failed is decoration.** Before trusting a new gate,
deliberately break the thing it guards, confirm it fails, then revert. The
first structural gate here once looked green while two of its checks were dead
code — a `|` inside the regexes collided with the `|` used as a field
separator, so the pattern silently truncated to `(class`. Only a negative test
found it.

**Fail closed, not open.** Express contract rules as *allowlists of what may do
the forbidden thing*, not blocklists of known-bad names. `UIKIT_ALLOWED_FILES`
in `Tools/lib.sh` names the one file permitted to import PencilKit/UIKit, so a
new file that imports them breaks the gate without anyone remembering to update
anything. A blocklist only catches violations someone already thought of.

**A green run with zero tests is a false pass.** Gate 40 greps the log for
evidence that tests actually executed. Apply the same suspicion anywhere a tool
can succeed by doing nothing.

**Watch for false positives too.** `Coordinator` is deliberately absent from the
forbidden-pattern list: `UIViewRepresentable.makeCoordinator` is idiomatic
SwiftUI, not the coordinator abstraction the contract forbids. A gate that cries
wolf gets disabled by the next agent, which is worse than not having it.

## Free gates — use them

- **Swift 6 language mode.** Compiler-enforced actor isolation turns "no work on
  the Pencil path" from a code-review opinion into a build error.
- **Warnings as errors** (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). This caught a
  deprecated `UIWindow(frame:)` in a test within seconds of it being written.
- **Runtime contract assertions.** `LiveCanvas` in `PageCanvasController.swift`
  asserts the one-live-canvas rule and logs `CONTRACT VIOLATION` via `os.Logger`;
  gate 50 greps the simulator console for that string. Cheap, and it fires at the
  moment of violation rather than during a review that may not happen.

Put an assertion **at the boundary where the risk lives, not where it is
convenient to write**. The one-canvas check first lived in
`PageCanvasController.init` and immediately crashed the test run, because the
test host app legitimately has its own live controller. The contract's actual
hazard is *SwiftUI rebuilding the canvas*, so the check belongs in
`makeUIViewController`. Directly constructing a controller in a test is not the
hazard and must not trip the guard.

## When a test fails, find out who is wrong

The assertion is wrong at least as often as the code. `contentSize` came back as
`819.99` instead of the expected `612`, which looked like PencilKit ignoring page
space. It was not: `UIScrollView` reports `contentSize` already multiplied by
`zoomScale`, and `612 × 1.3399 = 819.99` exactly. The implementation was right
and the test was wrong. Had that been "fixed" in the code, page space would have
been silently corrupted to view space — the precise failure the data contract
exists to prevent.

Diagnose before you edit. Compute the number the framework gave you and see
whether it means something.

## Do not test what the environment cannot express

Some properties are simply not observable here, and pretending otherwise
produces a green gate that proves nothing:

- `undoManager` walks the responder chain, so an unhosted controller always
  reports `nil`. Undo/redo is device evidence, not a unit test.
- The simulator has no Apple Pencil. Drawing, erasing, palm rejection, and
  pressure cannot be proven off-device at all.

When you hit one of these, do not weaken the assertion until it passes. Delete it
and name the gap explicitly in the `PLAN.md` session entry as outstanding device
evidence.

## Project structure

- **`project.yml` is the only project source.** The `.xcodeproj` is generated by
  XcodeGen on every gate run and is gitignored. Never edit the project in Xcode
  and expect it to survive; change `project.yml`.
- Bundle ID is `com.tubernotes.greenfield`, deliberately different from the old
  app's `com.tubernotes.app` so installing this never replaces it on the iPad.
- `Artifacts/` holds gate output (logs, screenshots, report). It is regenerated
  and gitignored — cite paths from it as evidence, never commit it.

## Scope discipline

The contract's hardest rule to follow is *smallest change that proves the
milestone*. The pressure to add the next abstraction is constant and it always
feels justified. Concretely:

- No protocol, repository, reducer, event bus, or service container. Gate 10
  enforces this, but the gate only knows the names it was told.
- No file I/O outside `DocumentStore` — which does not exist until G3. Do not
  create it early "since we'll need it".
- One live `PKCanvasView`. Forever, not just for now.

## Ask instead of guessing

Some decisions cannot be derived from the documents, and guessing at them
silently wastes the work: which physical device "the named iPad" means, how
far to go in one session, whether a rule covers developer tooling as well as
application code. Guessing produces work that gets thrown away. Ask, then
proceed.

Never make the human-only judgments. Pencil feel, stroke fidelity, palm
rejection, and pan/zoom quality are judged by a maintainer on the device.
Record the journey, produce the artifacts, and leave the verdict alone.

## Adding a gate

1. Create `Tools/gates/NN-name.sh`, source `../lib.sh`, `chmod +x`.
2. Exit `0` pass, `2` skip with a `skip "reason"`, non-zero fail with `fail`.
3. Use `FAILED=1` accumulation when you want all failures reported at once
   rather than only the first.
4. Negative-test it. Then run the whole suite.
5. Note in `PLAN.md` what contract clause the gate now enforces mechanically.
