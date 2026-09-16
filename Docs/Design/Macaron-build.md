# Macaron — what was built, on 15 September 2026

Branch `identity/macaron-v2`, worktree `TuberNotes-macaron-v2`. Nine steps,
nine commits, in the order `Docs/Design/Macaron.md` §10 gives them. Nothing
pushed, nothing merged.

Screenshots are in this session's scratchpad, one file per step and snap
state, named `step<n>-…png`:

    /private/tmp/claude-501/-Users-phil-Documents-Build-Week-TuberNotes-postoai/
      6e3f7f4f-f3c1-41da-a48e-d17baa96c7a8/scratchpad/

**The vetoed defect was checked on every screenshot that has the bar in it
and never appeared.** The swatches are a row in the horizontal bar and a
column only in the vertical one.

## The steps

| # | state | commit | what the screenshot shows |
|---|---|---|---|
| 1 | done | `5a0d2c6` | No pixels; six unit tests over the §3.2 table. `step1-baseline.png` is the editor before any of this, for comparison. |
| 2 | done | `d8be25c` | Cream ground under a 34-point grid, the page white at radius 10 inside a 3-point `#7E7E7E` line. `step2-ground.png`. |
| 3 | done | `6fc7fdf` | Four instrument keycaps on their walls, the pen sunk in strawberry with no wall at all. `step3-keycap.png`. |
| 4 | done | `bcd2e10` | Both snap states. Lying down: pill, four instruments, three width chips, four swatches in a row. Standing up: one width chip, swatches in a column. `step4-bar-horizontal.png`, `step4-bar-vertical.png`. |
| 5 | done | `a62ea4d` | The band, flat, with the active tab sunk in the accent and its callsign badge; readout, undo/redo, the four actions and the orange seat toggle. `step5-band-*.png`. |
| 6 | done | `c0f98e2` | The seat docked right with no right line, and floating with its grab bar and hard offset. Pink body, accent strip, orange grip. `step6-seat-*.png`. |
| 7 | **partial** | `d8ad8b3` | **No screenshot.** Reaching a selection needs a layer on the page and a drag the screenshot path cannot drive. The code is there and builds; the magic loop is not built at all — see below. |
| 8 | done | `28186c6` | Switch: dark console ground, grey chrome, neon red held, neon blue toggle. Game Boy: LCD-green chrome on the shell's beige, dark green held. `step8-theme-*.png`. |
| 9 | done | `08c0bb4` | Dark Macaron: outlines come up off their fills instead of down into them, the paper still white. `step9-dark-*.png`. |

## What is not built

- **The magic lasso's 28-percent fill and its 8-point anchor dot.** PencilKit
  draws that loop, not us; `LayerSelectionView` only ever draws the box around
  a layer that is already selected. Reaching it means drawing our own
  selection path instead of the framework's, which is a build, not a restyle.
- **Lilita One and Nunito.** Neither font file is in the repository. The
  system's rounded face stands in, heavy for labels and semibold for body.
- **Paper, bookmarks and the page navigator's own entry points.** The old
  toolbar went with step 5 and the band holds only what §4.2 lists. They are
  reachable through Insert; page setup is not reachable at all on this branch.
- **Device evidence.** The iPad is `unavailable` to `devicectl`, so nothing
  was installed. The generic-iOS build succeeds (`Debug-iphoneos`, 23:50).
  Press feel, the trampoline, the peel and the snap are all unproven: the
  simulator is silent about every one of them.

## Values derived, because the document is silent

- **Which fills are pale.** §3.2 says 42 percent for a saturated fill and 55
  for a pale one and never says which is which. A fill is pale when
  `contrast(fill, paper) < 1.6` — the escape's own threshold, read from the
  other end. That classification reproduces every row of the §3.2 table:
  white, pistachio, the ground and the seat body come out pale, and
  strawberry, vanilla, sky ink and the ink itself come out saturated.
- **How far the ground travels to become its grid line.** §3.2 names
  `ground2` as "ground mixed toward ink" with no percentage. Eight percent is
  the distance at which the default theme's line carries the same contrast
  against its ground as the table's `#E6D9BE` does (1.174 against 1.173).
  The bytes differ; the weight of the line does not.
- **The floating shadow's colour.** §1 keeps the earlier kit's hard offset for
  floating things and never says what colour it is. It takes the ground's own
  outline, because nothing is black but ink and the chrome's outline reads as
  a second border rather than as a shadow.
- **The callsign.** §4.2 prints one as `L9·4`. Nothing in the format holds a
  callsign, so it is a letter off the notebook's name and two digits off its
  identity's own bytes. Not its hash: a hash is seeded per launch, and a
  callsign that changes on restart names nothing.
- **Where undo and redo sit.** §4.2 says they live in the band and leaves them
  out of the left-to-right list. They sit beside the page readout.
- **The band's spare width.** §4.2 measures the band at 1162. A band as wide
  as this iPad has slack the mock did not, so what is open sits left and the
  actions sit right.
- **Switch and Game Boy.** §10 step 8 names both themes and the document has
  no hexes for either. Switch takes the shell colours the Joy-Cons store for
  themselves (`#FF3C28`, `#0AB9E6`, `#828282`, `#414548`, `#0F0F0F`) rather
  than the louder pair the box art uses. Game Boy takes the canonical DMG four
  (`#9BBC0F`, `#8BAC0F`, `#306230`, `#0F380F`) plus the shell's commonly cited
  beige `#C2C0BC`.
- **The locked selection box.** §6 gives the lasso no locked treatment. It
  drops from the accent to the accent's own outline tint: the dimmer end of
  the one colour the lasso is allowed, rather than a grey.

## Where the document disagrees with itself

The §3.2 table is a transcription, not a generated table, and no single mix in
sRGB, OKLab or CIELAB reproduces it to the byte. Each row is internally
inconsistent by one or two least-significant bits: solving strawberry's three
channels for one mix fraction gives 0.4255, 0.4302 and 0.4333. So the build
implements the **rule** — a straight sRGB interpolation at `outlineMix` — and
the fixture asserts each channel within two of the table.

Three rows need more than that:

- **White.** The rule gives `#7E7E7E` where the table says `#7C7C7C`.
- **The seat body.** The rule in §3.2 says the accent 80 percent toward the
  paper, which gives `#FFE1E8`. The table's `#FFE5EC` sits at about 83
  percent. The build follows the rule, since the rule is what generates a new
  theme.
- **The seat body's outline.** The table says `#8C7078`. That is not reachable
  from `#FFE5EC` by any mix toward a neutral: a lerp toward grey can only
  shrink a colour's channel spread, and `#8C7078` has a wider spread than
  `#FFE5EC` does. The build takes the rule's answer and the test does not
  assert that row.

The document says the canvas wins where the two disagree. The canvas was not
opened tonight, so where the document disagrees with **itself**, the build
followed §2's rules over §3.2's transcribed values, because §2 is what the
document says generated them.

## The crash, and what it was

Two reports, one cause. `EditorViewModel.setWidth` traps on the object
eraser, the lasso and text, and `setColor` traps on anything that is not ink.
Both are deliberate, and the comment beside them says exactly what went
wrong: "reaching here is a view that drew a control the tool does not have."

That view was the writing bar. It drew the three width chips and the four
swatches unconditionally, so a width tapped while the object eraser was in
hand, or a swatch tapped while the lasso was, walked straight into the trap.
Confirmed by reaching the state from a launch argument and watching the
process go.

The fix is on the view's side, where the defect was. A width chip is offered
when the tool in hand has a width or can take one, and a swatch is offered
only to ink; otherwise the cap is dimmed and inert. It is never removed,
because the run's order is fixed and a gap in it reads as a different bar.
Asking the object eraser for a width is how it becomes the pixel eraser that
has one, which is the only behaviour added.

The lasso and text are the band's tools, not the bar's, so while one of them
is in hand the bar's widths and swatches have no owner and none is sunk.

`ToolStrip.swift` went with it. It held the same two calls and nothing had
referenced it since the band replaced the old toolbar.

## Things a reviewer should look at first

0. **The seat covers the standing bar.** With the seat open and the bar
   snapped to the right edge, the seat sits over the bar's top third. Both
   want that edge and the document does not say who wins.
1. **The shell's hard shadow.** §4.1 says the writing bar's shell is flat, so
   it has none; only the floating seat takes the 6-point offset. The first cut
   gave the bar one and it read as a second border. Worth a verdict.
2. **The bar's long axis.** The fixed sizes and gaps in §3.3 add to 444 across
   with the padding, not the 424 the mock measures. The shell hugs its
   contents rather than being pinned to 424, because density is the rule that
   generated the number. Same 12-point gap in the standing state.
3. **Dark mode's seat.** The seat body is the accent 80 percent toward the
   paper, and the paper stays white after dark, so the seat is a bright pink
   panel on a dark ground. That is what the two rules say together. It may not
   be what you want.
4. **Game Boy's accent.** `#306230` sits at 1.83 against the ink, just above
   the escape's 1.6, so it takes the plain rule and its outline lands close to
   it. The paper escape never fires on it. The greens survive, but only just.
