# Milestone 1 — Pages and Turning

Status: specified; implementation not started
Purpose: turn the one trustworthy page of Milestone 0 into a notebook you can
page through, without giving up any of its durability guarantees.

Supersedes Just a Canvas §4's exclusion of "multiple pages, ordering, page
navigation". Thumbnails, reordering, and deletion remain excluded.

## 1. Product target

Launch TuberNotes and get one blank portrait page. Write on it. Swipe left to
turn to the next page the way you turn a page in GoodNotes: the page slides and
snaps, one page per swipe. Swipe past the last page and a new blank page is
there to write on. Leave the app, return, and find every page and every
successfully saved stroke exactly where it was, in the same order.

## 2. User journey

1. Launch the normal app and land on the first page.
2. Write with Apple Pencil.
3. Swipe left with a finger to turn to the next page; swipe right to go back.
4. The turn snaps to a page boundary — you are never left between two pages.
5. Swipe left from the last page and get a fresh blank page.
6. Zoom in, write, and turn a page without the zoom fighting the swipe.
7. Force-quit, relaunch, and find the same pages, the same order, and the same
   ink, on the page you left.

## 3. Included

- an ordered list of pages in one document, all of the same fixed geometry;
- horizontal paged navigation with snapping, one page per swipe;
- automatic creation of a new blank page when the user swipes past the last;
- a durable document format holding many pages, with migration from the
  Milestone 0 single-page file;
- per-page saving, so save cost scales with pages that changed;
- live canvases for the visible page and its immediate neighbours only, recycled
  as pages turn; and
- restoration of the current page index across launches.

## 4. Excluded

- thumbnails, a page grid, or any page overview;
- reordering, deleting, duplicating, or inserting a page anywhere but the end;
- explicit "add page" UI — creation is the swipe-past-the-end gesture only;
- vertical continuous scrolling as an alternative reading mode;
- PDF/image backgrounds, templates, or per-page geometry;
- multiple documents, a library, titles, or covers; and
- everything Just a Canvas §4 excludes and this section does not name.

## 5. Why the format has to change

Milestone 0 writes one property-list file containing the whole drawing, and
rewrites all of it on every save. With many pages that directly violates the
project rule *scale with visible or changed content, never with total notebook
size*: writing page 40 would rewrite pages 1 through 39 as well.

So the durable form becomes a directory, and `DataContract.md` §4 is amended for
it. The single-file rule and the "no package, no manifest" rule are both
superseded — see §4a there for the normative version.

## 6. The hard part, named in advance

`PKCanvasView` is a `UIScrollView` and already owns pinch-zoom. A horizontal
paging scroll view owns the swipe. Nested, they fight: a swipe on a zoomed-in
page is ambiguous between panning within the page and turning to the next one.

The resolution this milestone commits to: the page turn is only available when
the current page is at its fit-width scale, or when panning has reached the
page's own horizontal edge. Zoomed in and away from an edge, a horizontal drag
pans within the page and does not turn. This is a behavioral rule, not an
implementation note, and it is what the device gates below check.

Whether it *feels* right is Phillip's verdict, not the gate's.

## 7. Acceptance gates

Mechanical, checked by `Tools/gate.sh`:

- A document round trips through encode/decode with page order preserved.
- A Milestone 0 single-page file migrates to a one-page document, preserving the
  document ID, page ID, and drawing bytes exactly.
- Saving a document where one page changed writes only that page's file and
  leaves every other page file byte-identical, including its modification time.
- A partially written page file, or an index naming a page file that does not
  exist, fails to load without modifying anything on disk.
- Appending a page produces a document whose page count grew by exactly one,
  with the new page last.
- Live canvas count stays bounded as page index moves across many pages.
- The current page index survives a save/load round trip, and an index outside
  the page range is rejected rather than clamped.

Device, exercised by hand and recorded:

- Swipe turns exactly one page and snaps; no resting position between pages.
- Ink written on page N is on page N after turning away and back.
- Swiping past the last page yields a blank writable page that persists across a
  force-quit once written on, and — see §8 — does not persist if never written.
- At fit-width scale a horizontal swipe turns the page; zoomed in and away from
  an edge it pans instead.
- Turning pages continuously for a few minutes does not grow memory without
  bound, and `TN_TRACE` shows saves naming only changed pages.

## 8. Empty trailing pages

Swiping past the end creates a page immediately, because a turn that lands on
nothing is not a page turn. But a page created by an overswipe and never written
on is not a page the user asked for, so it is not durable: an appended page
becomes part of the saved document the first time it takes ink. A single
never-written trailing page may exist in memory and is dropped on save.

This is the one place where what is on screen and what is in the file
deliberately differ, and it is why "page count" is defined as the saved count
everywhere in this document except here.

## 9. Evidence packet

As Just a Canvas §8, plus: the save trace for a multi-page edit showing which
page files were written, and the live canvas count across a long page sweep.
