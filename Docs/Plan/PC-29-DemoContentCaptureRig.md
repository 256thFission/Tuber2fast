# PC-29 — Demo content and capture rig

Status: **content artifacts prepared — manual capture deferred**

Target branch: `main`

Owner: DeveloperSupport / non-product. Phillip owns final content and capture
judgment.

Parent: `Docs/Plan/PLAN.md` § Textbook citation demo (PC-24 … PC-29)

## Objective

Prepare the two documents and the capture setup the recorded demo runs on. This
thread ships no product code and gates the usefulness of every other thread, so
it starts first and runs throughout.

## Scope

Content:

- A CC-licensed organic chemistry chapter PDF (OpenStax or equivalent), trimmed
  to roughly 20 pages, with a **verified real text layer** — PC-25 produces no
  corpus from a scanned book.
- A citation target page whose figure remains legible **at final video
  resolution**, checked before any other thread commits to it. A dense
  two-column page with a small mechanism diagram will not survive capture.
- A handwritten worksheet notebook: (S)-2-bromobutane + NaOH, worked as SN1 with
  a drawn carbocation and retained configuration — a clean, single, legible
  error whose correction is exactly what the chapter page states.

Capture:

- iPad screen recording plus a picture-in-picture hand shot, per Phillip's
  decision on 2026-07-21.
- PiP framing on the Pencil hand during the lasso; focus locked; a sync method
  between the two sources decided before the first take.
- Device hygiene: Focus mode on, notifications suppressed, clean status bar,
  sufficient battery, no Debug surfaces reachable from the recorded journey.
- Attribution for the textbook visible at least once — the notebook title in the
  library satisfies this for free.

## Non-goals and dependencies

Non-goals: editing, narration script, music, any product code change, staging
that would misrepresent retrieval as working when it did not.

Dependencies: none. Blocks the usefulness of PC-24 through PC-28.

## Ordered work

1. Select and verify the chapter PDF's text layer; trim it.
2. Choose the citation target page and confirm legibility at capture resolution.
3. Author the worksheet page on the pinned iPad.
4. Stand up and rehearse the PiP rig; confirm the lasso gesture reads clearly in
   the composited frame.
5. Confirm device hygiene immediately before the first real take.

## Acceptance evidence and stop conditions

- Chapter PDF selected, text layer confirmed, license and attribution recorded
  in this log.
- Citation target page named here so PC-25 through PC-28 can verify against it.
- A test composite (screen + PiP) reviewed at final resolution, with the lasso
  and the citation chip both legible.

Stop when Phillip confirms the content and the composite. Retakes are cheap;
unreadable source material is not.

## Session log

- 2026-07-21 — Resumed from Phillip's valid 50,260,428-byte local copy of the
  official PDF (467 pages, unencrypted; SHA-256
  `e68d37ade81916e25869970b9b6e2d0b8b5cf4571c57b42b45927fd22885435f`).
  Poppler text extraction located Section 11.2 on source PDF page 356 / printed
  page 344 and Problem 11-2 on source PDF page 358 / printed page 346. Direct
  extraction of “What product would you expect to obtain from SN2 reaction of
  OH– with (R)-2-bromobutane?” from both source and derivative proves the
  embedded text layer without OCR.
- 2026-07-21 — Prepared the 20-page contiguous Chapter 11 derivative from
  source PDF pages 353...372 (printed pages 341...360):
  `tmp/verify/pc29-demo-content-capture/trim/OpenStax-OrganicChemistry-Ch11-pages-353-372.pdf`.
  Problem 11-2 maps to local page 6. The trim is 2,799,677 bytes, unencrypted,
  and has SHA-256
  `0e9016896ac017e57a86457c4400d08e06223b7d3f95e18c18e218780cc77f66`.
  License, attribution, commands/results, mapping, and text evidence are in the
  adjacent artifact README.
- 2026-07-21 — Rendered local page 6 to an aspect-preserving 835 × 1080 PNG at
  `tmp/verify/pc29-demo-content-capture/render/target-local-page-6-1080h.png`
  (SHA-256
  `ecd423af846c1fef17758b5959ecc66abfe772bbb74c12faa45e5a8535aff899`).
  Bounding-box evidence puts the target line fully within the page and its
  principal glyph height at approximately 16 pixels in this 1080-line proxy;
  the render is mechanically complete and unclipped. Phillip's final
  readability/taste verdict remains required. No iPad, worksheet, or PiP work
  was attempted. Generated bulky page-splitting intermediates were removed
  from the artifact tree after final-PDF validation.
- 2026-07-21 — Selected the official OpenStax *Organic Chemistry: A Tenth
  Edition* preliminary PDF (Chapters 1–12) as the source candidate:
  `https://assets.openstax.org/oscms-prodcms/media/documents/OrganicChemistry-SAMPLE_9ADraVJ.pdf`.
  The primary OpenStax book page identifies John McMurry / OpenStax, publication
  date 2023-09-20, and license CC BY-NC-SA 4.0. The PDF's own prefatory license
  text likewise permits distribution and adaptation with attribution under CC
  BY-NC-SA 4.0. Intended attribution: “Organic Chemistry: A Tenth Edition,
  John McMurry, OpenStax, CC BY-NC-SA 4.0.” Primary license page:
  `https://openstax.org/details/books/organic-chemistry`.
- 2026-07-21 — Selected Section 11.2, “The SN2 Reaction,” specifically Problem
  11-2 (“SN2 reaction of OH- with (R)-2-bromobutane”) as the citation target.
  It directly matches the planned erroneous worksheet and the surrounding
  section explains backside attack and inversion of configuration. Primary
  section URL:
  `https://openstax.org/books/organic-chemistry/pages/11-2-the-sn2-reaction`.
  Exact PDF source-page/local-page mapping and final-resolution legibility are
  **not yet established** and must not be inferred from the web section.
- 2026-07-21 — Local acquisition blocked before a lawful trim could be made.
  The primary server reports a 50,260,428-byte PDF and supports byte ranges, but
  repeated whole-file transfers terminated early; the resulting local file was
  corrupt and was rejected. Durable HTTP range proof is under
  `tmp/verify/pc29-demo-content-capture/evidence/`. No selected or trimmed PDF
  is approved for PC-24/PC-25 yet. Stop reason: coordinator requested the best
  current packet without further source research; no iPad/capture work was
  attempted.
- 2026-07-21 — Remaining human/content gate: acquire the complete PDF; extract
  text to locate Section 11.2; record exact source page; trim approximately 20
  pages around it and record the local page; render that local target at the
  final video dimensions; then Phillip confirms mechanism-text/figure
  legibility and later creates the handwritten page and operates/reviews the
  screen-plus-PiP rig.
- 2026-07-21 — Content-source and capture-rig preparation started in parallel
  with Wave 1 product implementation. No product code is in scope.
- 2026-07-21 — Created for the recorded textbook-citation demo. Phillip selected
  screen recording plus a PiP hand shot over an overhead camera. Not started.
