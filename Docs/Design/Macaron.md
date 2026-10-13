# Macaron — the notebook editor's visual identity

Status: approved by Phillip Lin on 15 September 2026. This document is the
written form of the design canvas
(https://claude.ai/artifact/ALZUswU3MadFEkxAmqMY3E, pages **Toy** and
**Build**; the board titled *The recipe — read first* is the authoritative
picture). Where this document and that board disagree, the board wins and
this document has a bug.

It covers the editor's chrome only: the band, the writing bar, the seat, the
page frame, the ground, the transients, and the theme system that colours
them. It does not cover the library, sheets, or the ink pipeline.

## 1. What it is for

TuberNotes' first Macaron build read as **neo-brutalist**: the same 3pt black
line on every element, hard zero-blur offset shadows, near-square radii, one
flat accent on a grey grid, no motion. The target is the other register the
Macaron theme names for itself: *"what if Nintendo and Teenage Engineering
made a browser for designers"* — toys, handheld consoles, stationery, printed
enamel. Playful, dense, tactile.

Four levers separate the two, and this design pulls all four:

1. **Line.** Nothing is black except ink. Every outline is its own fill
   moved toward the ink colour.
2. **Depth.** Things you press are keycaps standing on a 4pt side wall.
   Pressing them sinks them into it. Nothing you cannot press has a wall.
3. **Motion.** Squash on tap, a trampoline when a tool becomes held, a
   sticker peel when you grab something that moves.
4. **Density.** Chips nearly touch; the shell hugs them.

Everything else is deliberately held at the earlier kit (Lilita One and
Nunito, 10–16pt radii, hard offset shadow on floating things) so that a
theme, not a redesign, is what changes the look.

## 2. Principles

These are the rules that generated the values below. When a new element
turns up that this document does not name, derive its treatment from these.

- **A wall means "push me."** Only pressable controls get a keycap wall.
  Readouts, badges, the band's shell, the seat's body: flat.
- **Held is sunk.** A held tool, held width, or held swatch drops its whole
  wall and keeps none. That is the entire selected state. There is no ring,
  halo, glow, or outline change for selection, in any theme.
- **An outline is its fill, moved toward the other end of the theme.** No
  element has its own outline colour; it is derived. Nothing is black but
  ink.
- **Dashed means transient and bodiless.** A drawn thing that will vanish
  (lasso box, snap ghost, resize target) is dashed. A real object being
  moved (the bar mid-drag) keeps its solid line, because it has a body.
- **The finger never draws. The Pencil never drags chrome.** Both may tap.
  Carried over from the proposal; unchanged.
- **One tenant in the seat.** Unchanged from the proposal.
- **A theme is six hexes.** It cannot reach a number.

## 3. Tokens

### 3.1 Set by a theme (exactly six)

| token | reaches |
|---|---|
| `ground` | the wallpaper behind the page |
| `chrome` | band, writing bar, chips, readouts — one fill for all of them |
| `accent` | held tool, active tab, seat title strip, lasso, page margin |
| `secondary` | seat toggle, resize grip, dirty dot, rule lines, highlighter |
| `outlineMix` | two percentages, saturated and pale; defaults 42 / 55 |
| `ink` | what handwriting is, and what every outline is mixed toward |

**No two of the five colours a theme sets are the same hex.** `ground`,
`chrome`, `accent`, `secondary` and `ink` differ in every preset, and a
test over the presets says so by those five names. Each role is a
different thing on screen, and this design tells them apart by colour
alone: there is no ring, no label and no second line weight to fall back
on. A secondary that is the ink makes the seat toggle, the grip and the
dirty dot read as ink, and the derivation cannot rescue it, because an
identical pair takes an identical outline. Two roles may sit close enough
that one takes the paper escape; they may not coincide. The rule stops at
the five set colours: the derived `paper` is white whatever the chrome is,
so a white chrome meets it, and the palette repeats a role on purpose, the
ink first of all (decided T3; theme-06).

Default theme ("Macaron"):

| token | value |
|---|---|
| `ground` | `#F4EADA` warm cream |
| `chrome` | `#FFFFFF` |
| `accent` | `#FF6A8C` strawberry |
| `secondary` | `#FFB347` vanilla |
| `outlineMix` | 42% saturated / 55% pale |
| `ink` | `#141414` |

The third Macaron colour, pistachio `#DFF3C8`, is the second notebook's tab
colour in the mocks. It is a per-notebook preset, not a theme token.

### 3.2 Derived (never set)

| derived | rule |
|---|---|
| `paper` | `chrome` at full lightness (white in every shipped theme) |
| `ground2` | `ground` mixed toward `ink`; the grid line and the second colour of every ground pattern |
| outline of anything | `fill` mixed toward `ink` at `outlineMix` — 42% if the fill is saturated, 55% if pale |
| outline over the paper | by day, the ordinary outline; in a dark theme, `fill` mixed toward `ground` at the same `outlineMix`. The paper stays white after dark, so an outline come up toward white would not be there on the page it marks: the lasso box's handle borders and its lock, a page's bookmark. Where the escape fires, the two agree |
| keycap wall colour | the element's own outline colour (same hex) |
| seat body | `accent` taken 80% toward `paper`; in a dark theme, 80% toward `ground` (§4.3) |

**The paper escape.** When `contrast(fill, ink) < 1.6` the mix target flips
from `ink` to `paper` at the same percentage. This is how the ink swatch
gets an outline at all, and how Lime's purple, nearly as dark as its ink,
keeps one. Eight of thirty-six tokens across the six mocked themes take it;
the rest take the plain rule.

Default-theme results, for checking a build against the mocks:

| fill | outline |
|---|---|
| strawberry `#FF6A8C` | `#9B4558` |
| vanilla `#FFB347` | `#9B6F30` |
| pistachio `#DFF3C8` | `#6E7763` (pale, 55%) |
| white `#FFFFFF` | `#7C7C7C` (pale, 55%) |
| sky ink `#5BA8E8` | `#3C698E` |
| seat body `#FFE5EC` | `#8C7078` |
| ground `#F4EADA` | `ground2` `#E6D9BE` |

Dark mode is the same rule with the mix target inverted toward white; the
paper stays white. The escape inverts with it and runs to the `ground`,
because a dark theme's ink is a cream: a near-white fill sent toward the ink
would land on itself, and the line would not be there at all.

### 3.3 Fixed by the design (no theme can touch these)

| what | value |
|---|---|
| line weight | 3pt, everywhere, always |
| chip | 34 × 34, radius 10 |
| swatch | 18 × 18, radius 6; held swatch 26 |
| shell | 56 across the short axis, radius 16, padding 8 |
| divider | 3 × 24 |
| gap | row 6, column 8 |
| keycap wall | 4pt under chips, 3pt under swatches; no lip |
| radii | shell 16, chip 10, swatch 6, page 10, seat 14 |
| dashes | 9 on / 7 off, in the accent |
| type | Lilita One for labels and callsigns, Nunito for body |

Width chips and the grab pill are the same size class as chips (34).

## 4. The objects

### 4.1 The writing bar

Contents, in order, and nothing else:

> grab pill · pen · pencil · highlighter · eraser · divider · widths · divider · four swatches

No undo, no redo, no lasso, no text, no shapes, no fifth instrument. Four
swatches, always in **one run**. Undo lives in the band and on the Pencil
double-tap.

Two snap states, not a continuum:

| | horizontal (snapped to the top edge) | vertical (snapped to a side or corner) |
|---|---|---|
| widths | three width chips | **one** width chip showing the current width as a dot; tap opens the popover |
| swatches | four in a row | four in a column |
| gap | 6 | 8 |
| size | 424 × 56 | 56 × 366 |

**A vertical swatch column inside a horizontal bar is vetoed. In every style.**

Depth: every chip and swatch is a keycap on a wall in its own outline
colour; the shell itself is flat. The held tool, held width and held swatch
are sunk (no wall). The grab pill is flat.

Eight snap points remain from the previous build: four corners and four edge
midpoints, nearest by predicted end location, saved per orientation. The
default position follows the slack rule from the proposal.

### 4.2 The band

56 tall, 1162 wide (16 inset from each edge), gap 9, padding 13. Contents,
left to right: round library chip · notebook tabs (name, callsign badge such
as `L9·4`, dirty dot) · overflow `+n` chip · page readout `7 / 18` · lasso ·
text · insert · export · seat toggle. Undo/redo live here.

Depth: **tabs are keycaps and the active tab is sunk.** Everything else in
the band is flat: the shell, the library chip, the action chips, the seat
toggle, the readout. ("Stop it with the keycap thing for the top.")

The overflow chip is in the ground colour, so it does not read as a fifth
tab.

### 4.3 The seat

250 × 300 in the mocks. Flat everywhere: body in the derived seat colour,
title strip in the accent, a `×` top-trailing, an orange (secondary) grip
bottom-trailing. Docked to the right edge it drops its right border and right
radius and casts no shadow. Floating, it takes the 6pt hard offset shadow and
shows the grab bar in its title strip. `LOCKED` and similar badges are flat
because they are readouts.

**In a dark theme the seat body is the accent taken 80% toward the ground,
not toward the paper.** By day the seat is the accent let most of the way
to white. The paper stays white after dark, so the same mix would make the
seat the one near-white panel on a dark chrome; toward the ground it stays
a dark panel with the accent still in it, about `#513032` in Macaron Dark.
The mix turns with the outlines, on the one flag that makes a theme dark,
and no theme sets it separately. The seat's rows letter in the seat body's
outline, which after dark comes up toward white, so the current page's
row, filled with the paper by day, is filled with the chrome after dark:
on white that lettering would not be there (decided T4; theme-03).

### 4.4 The page

White paper, radius 10, 3pt outline in the derived white outline `#7C7C7C`,
on the cream grid ground. Fit-page by default. Nothing in this design draws on
the paper except ink and the transients in §6.

## 5. Ground

Grounds are **two-colour inline SVG `<pattern>` tiles**, data-driven by
`ground` and `ground2`. No raster, no gradient, no texture, no third colour.

Default: **grid 34**, a 34 × 34 tile with 1.5pt lines in `ground2`. The
catalogue on the *Two-colour SVG grounds* board has twelve tiles (plain,
grid, checkerboard, dots, half-drop dots, hatch, isometric, cross-stitch,
plus signs, scallops, brick, waves); a theme may pick any. Known behaviours:
grid has a register problem under a floating bar (accept it, or snap travel
to 34); dots have none; brick's joints read as rules under a hovering bar.

Cream was chosen over the grey grid because it is one value wherever the bar
parks. Measured contrast of the white chip's `#7C7C7C` outline against cream
is 3.5:1.

## 6. Transients

| thing | treatment |
|---|---|
| width popover | **speech bubble with a tail** pointing at the width chip that owns it; body radius 19, three round 34pt selectors, 3pt line in the chrome's outline, no wall; vertical snap only |
| lasso box | 3pt dashed box in the accent over a 10% accent fill; four **plain flat squares** r5, 15pt, no walls |
| magic lasso | the loop you drew, filled **28% of the accent**, dashed accent outline, 8pt anchor dot; never borrows the ink colour |
| bar mid-drag | **lifted peel, solid line**: keeps its outline, tips −4°, lifts 5pt, casts a real blurred shadow (0 12 18 at 42%) |
| snap-slot ghost | **dashed** outline of the exact shell the bar will become at the target corner (56 × 366 or 424 × 56), radius 16, so an orientation change is previewed before release |
| dirty dot | 11pt in `secondary` with a 1.5pt line in its own outline, derived by §3.2's *outline of anything* row like every other line in the chrome, so no preset gets a tint fixed by hand (U39; theme-matrix `u-dirtydot`); hung off the tab's top-right corner, no wall; overshoots to 150% on arrival, collapses to zero on save |
| seat resize | the body holds its committed frame; a dashed accent-pale target runs ahead to the requested size; the grip squashes like any held cap and travels with the dash; on release the body takes the frame in one step |

## 7. Motion

Seven curves, no more: `out-back(1.7)`, `out-back(2.6)`, `spring(m1 k420
d22)`, `out-quint`, `in-out-sine`, `out-elastic(.35)`, `steps(n)`.

| gesture | dialect | keys |
|---|---|---|
| tap a chip | **squash** | 1.14 × 0.82 at 60ms (out-quint) → 0.86 × 1.24 at 130ms (out-back 2.6) → spring to 1.0 by 260ms; volume conserved; fill commits on the stretch, not on contact |
| a tool becomes held | **trampoline** | squash to 86%, throw the cap 7pt above rest leaving an 11pt wall behind, settle sunk |
| grab the bar or seat | **sticker peel** | −4° tilt, 5pt lift, shadow grows from hard to blurred; lands on one rebound |
| release a drag | snap | nearest of eight points, `out-back(1.7)` |

Budget rules: nothing animates while a Pencil touch is down; nothing touches
the ink layer; Reduce Motion collapses every dialect to a 120ms cross-fade.

## 8. Additive rules and optional settings

- **Outline follows ink** — a theme setting, off by default: outlines and
  walls take the current ink colour instead of the derived tint.
- **Dashed = transient** — already in force above; listed here because it
  was chosen as a rule that rides on top of the main line, not as the line.

## 9. What was cut, so it stays cut

- Black outlines on anything but ink.
- Undo/redo, lasso, text, or any fifth instrument on the writing bar.
- Seven swatches; any 2-wide swatch grid; a vertical swatch column in a
  horizontal bar.
- Rings, halos, or glows for selection.
- Keycap walls on the band's shell, chips, readout, or toggle; on the seat;
  on any badge.
- The moulded lip (1pt 12% highlight on the wall). Proposed twice, declined
  twice.
- Wall heights 3, 6, 8; capsule and radius-14 caps; the shell as a keycap.
- Hairline (1.5pt) line; graded 4/3/2/0 weights; white-ring line; no-line.
- Raster or gradient grounds; felt, desk mat, plastic shell, vignette.
- Three-dialect press (pop, sink, wiggle) — squash is the tap.

Left as the recipe draws them, without a separate verdict: type (Lilita One /
Nunito) and the seat's panel chrome.

## 10. Build order

Each step ends in something that can be looked at on the iPad.

1. **Theme record and derivation.** A `Theme` value with the six tokens and
   the derived outline, wall, `ground2`, seat body, and the paper escape.
   Unit-testable: the default-theme table in §3.2 is the fixture.
2. **Ground.** Cream + grid-34 SVG pattern from `ground`/`ground2`, behind
   the page. Page frame outline in the derived white outline.
3. **Keycap chip.** One view: fill, derived outline, 4pt wall, sunk state.
   Squash on tap. This is the atom; everything pressable is made of it.
4. **Writing bar**, both snap states at D3 with gap 6/8, eight snap points,
   width chip → speech bubble in the vertical state. Peel on grab, dashed
   ghost at the target, trampoline when a tool becomes held.
5. **Band** with keycap tabs (active sunk), flat everything else, dirty dot.
6. **Seat**, flat, docked and floating, resize with the dashed target.
7. **Lassos**: box with flat handles, magic loop at 28%.
8. **Theme switching** with at least two presets beyond the Macarons, to
   prove the derivation and the paper escape on real chrome.
9. **Dark mode** (mix toward white).

## 11. Verification

The simulator proves layout; only the iPad proves press feel. For every step
above, the evidence is a screenshot in both snap states and, for 3–6, a
short screen recording of the press dialect on the device. Compare against
the *Recipe* board's three compositions. The specific failure to check for
each time the bar is touched: swatches stacked in a column inside a
horizontal bar.

## 12. Sources

- Canvas page **Toy**: Depth, Silhouette, Line (03 fleshed, 09 fleshed),
  Colour, Ground, Type, Motion, Hardware, Panel, Density, eight whole
  screens.
- Canvas page **Build**: Keycap on the tinted line, Band and seat, Six
  themes, Ground, Transients, *The recipe*, Two-colour SVG grounds.
- The proposal (canvas page **Proposal**) for the twelve interaction rules
  this identity sits on; nothing here changes them.
