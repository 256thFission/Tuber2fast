# GoodNotes 6 iPad library/folder system — specification

## Preamble

This is the Phase 1 reference specification of GoodNotes 6's iPad library layer
(document browser, folders, navigation, creation, manipulation, sort/filter,
search, trash, favorites, states, iPad structure). Phase 2 (design) and
Phase 4 (build) work from this document; it records what GoodNotes does, not
what TuberNotes will do.

**Source hierarchy** (highest wins on conflict):

1. **OBSERVED-FIRST-PARTY** — eight screenshots of the app taken from
   Phillip's own iPad library, 2026-08-08 (`images/01`–`08`; landscape, dark
   mode, sidebar open). These are the build target and outrank everything.
2. **OBSERVED-IN-IMAGE** — a retrieved web/support/App Store image, viewed.
3. **DESCRIBED-IN-PROSE** — official or third-party text (URL/source cited).
4. **INFERRED-FROM-PLATFORM** — standard iPadOS/UIKit behavior, unverified
   for GoodNotes specifically.
5. **INFERRED** — deduced from stated evidence (the evidence is named).
6. **UNKNOWN** — no evidence; listed in "Open questions" if it forces a
   design decision.

**Gen-1 vs Gen-2.** The GN6 library shipped two UI generations. Gen-1
(2023–24): dashed "New…" first tile, centered `Date | Name | Type` segmented
sort, separate ✓-circle Select and four-squares icons, Search as a sidebar
row, Gear top-right. Gen-2 (2025–26, the first-party screenshots): blue
`+ New` pill, "All" filter chip, four-squares icon opening a combined
Select / Grid-List / sort menu, search magnifier in a top-right capsule with
bell and avatar, no Search sidebar row. **Gen-2 is the build target.** Gen-1
facts appear only where they are the sole evidence for a behavior and are
flagged as such. Most web prose documents Gen-1 chrome; it is trusted here
for behavior/semantics, never for control placement.

---

## 1. iPad structure: sidebar, split view, chrome

### 1.1 Sidebar

- Floating rounded-corner panel, ~28% width, inset from the screen edges,
  slightly lighter dark grey than the near-black content background (dark
  mode). [OBSERVED-FIRST-PARTY]
- Rows, top to bottom: **Documents** (blue folder glyph), **Favorites** (red
  bookmark-star glyph), **Shared** (person glyph), **Marketplace**
  (storefront glyph with a second small grey line, "500+ Items for
  Essential"). Active row gets a lighter rounded-rect pill highlight.
  [OBSERVED-FIRST-PARTY]
- Sidebar-collapse toggle icon at the sidebar's own top-right.
  [OBSERVED-FIRST-PARTY]
- The sidebar is a collapsible overlay/leading column, not a permanent
  split: an App Store iPad shot shows it dismissed with a thin rounded
  sliver peeking from the left edge. [OBSERVED-IN-IMAGE, App Store
  ASO_EN_iPad_8]
- Gen-1 sidebar additionally had a Search row and a "Goodnotes" wordmark
  header; Gen-2 drops the Search row (search moved to the top capsule).
  [OBSERVED-IN-IMAGE, support attachments]
- **No Trash row in the iPad sidebar** in any first-party or Gen-2 image.
  Sidebar Trash is documented only for Android/Windows/Web. See §9.
  [OBSERVED-FIRST-PARTY absence + DESCRIBED-IN-PROSE, support]
- **No folder tree in the sidebar** — a persistent community complaint;
  multiple feedback threads request one. [DESCRIBED-IN-PROSE,
  feedback.goodnotes.com]
- Selecting into a folder does NOT change the sidebar selection; "Documents"
  stays highlighted at depth. [OBSERVED-FIRST-PARTY, shot 05]

### 1.2 Top-right capsule

- Floating capsule: search magnifier, bell with red numeric badge, circular
  red avatar with the user's initials ("PL"). Present in root Documents and
  inside folders. [OBSERVED-FIRST-PARTY, shots 01/05/08]
- In **Favorites** the capsule shows only bell + avatar — the search
  magnifier is absent. Observed, not explained. [OBSERVED-FIRST-PARTY,
  shot 02]
- One support-era build shows a **gear** where the App Store build shows an
  avatar; one App Store build shows an **ellipsis "…" circle** in the action
  row. The top-right identity/menu affordance has varied across builds; the
  2026 first-party build has the avatar and no ellipsis.
  [OBSERVED-IN-IMAGE vs OBSERVED-FIRST-PARTY]

### 1.3 Toolbar row (above content)

- Left: filter control — three-line funnel icon + label "All".
- Right: blue **"+ New"** pill (white plus), **four-squares** view-options
  icon, thin vertical divider, **cloud** sync icon. The cloud turns red with
  an exclamation on sync error. [OBSERVED-FIRST-PARTY]
- In Favorites there is **no "+ New" pill at all**; the right side is just
  view-options, divider, cloud. [OBSERVED-FIRST-PARTY, shot 02]

### 1.4 Titles

- Root collections (Documents, Favorites): large, left-aligned title.
  Inside a folder: small centered title with a circular dark back-chevron
  button at the content pane's top-left. [OBSERVED-FIRST-PARTY]
- Whether the large title collapses on scroll: UNKNOWN.

### 1.5 Library ↔ editor relationship

- The editor is a **tabbed interface**: a tab strip with a home icon at far
  left and document tabs (title + chevron + close X). Home returns to the
  library; library and documents share one window with browser-style tabs.
  [OBSERVED-IN-IMAGE, App Store editor shots]
- Once backed out to the library there is no "return to current notebook"
  affordance — a community complaint. [DESCRIBED-IN-PROSE, feedback thread,
  weak — fetch 502'd]

### 1.6 Keyboard and pointer

- **Officially undocumented** for the library; only in-document shortcuts
  exist in the docs. [DESCRIBED-IN-PROSE, support]
- Arrow-key selection, ⌘-click multi-select, pointer hover effects, ⌘-HUD:
  all INFERRED-FROM-PLATFORM at best; UNKNOWN whether GoodNotes implements
  them. Note GoodNotes does NOT use `UIDocumentBrowserViewController` — the
  library is custom, so Files-app behaviors cannot be assumed.
  [INFERRED-FROM-PLATFORM]

---

## 2. Document browser: grid and list

### 2.1 Grid presentation

- 4 columns in landscape with the sidebar open. Folders and documents
  **interleave in a single grid with the same cell footprint** — a pink
  folder sits mid-grid among documents, consistent with one sort key
  applied to both types (dates on cells descend left→right, top→bottom).
  [OBSERVED-FIRST-PARTY, shot 01]
- Column count in portrait or with sidebar collapsed: UNKNOWN.

### 2.2 Document cell anatomy (grid)

- Portrait first-page thumbnail with realistic paper texture, a slight 3D
  page-stack edge on the right, and a drop shadow. Thumbnails show real
  content: handwritten ink, a real PDF cover, plain cream blanks.
  [OBSERVED-FIRST-PARTY]
- Official rule: **"The cover is the first page of a notebook"** — a
  coverless notebook thumbnails its first paper page. The thumbnail is
  always page 1, whatever page 1 is. [DESCRIBED-IN-PROSE, support]
- Notebooks created with a cover render as a book with a darker spine strip
  (App Store "Research" tile, default "Simple" kraft cover).
  [OBSERVED-IN-IMAGE]
- **Favorite star**: top-right ON the thumbnail. Grey/dim outline when not
  favorited; red filled bookmark-ribbon style when favorited.
  [OBSERVED-FIRST-PARTY, shots 01/02]
- Below the thumbnail: white centered single-line title with a small grey
  **chevron-down immediately right of the title** (the context-menu
  affordance), then a grey date line. [OBSERVED-FIRST-PARTY]
- Long titles wrap to **two lines with middle-truncation ellipsis**, so row
  heights vary between grid rows. [OBSERVED-FIRST-PARTY, shot 02]
- Date format: `MMM d, yyyy 'at' h:mm a` ("Jul 19, 2026 at 3:25 PM").
  [OBSERVED-FIRST-PARTY] Web images additionally show relative dates for
  recent items ("Today at 3:44 PM", "Yesterday") and shorter absolute forms
  for older ones ("18 October") — relative-recent/absolute-older behavior is
  OBSERVED-IN-IMAGE across builds; exact thresholds UNKNOWN.
- One cell showed a dark diagonal corner fold/banner with an upload-arrow
  icon — a per-document sync/upload badge. A support image shows a similar
  dark warning-triangle corner badge on a folder. Semantics unexplained.
  [OBSERVED-FIRST-PARTY + OBSERVED-IN-IMAGE]

### 2.3 Folder cell anatomy (grid)

- Flat, saturated colored folder glyph, same cell footprint as a document.
  Star at the folder glyph's top-right (tab corner); title + chevron + date
  below, identical layout to documents. [OBSERVED-FIRST-PARTY]
- Folders may carry a centered **monochrome line-art icon on the folder
  face** (observed: graduation cap, banknote, flask, bank columns, </>,
  percent-doc, apple, scales, smiley, bar chart, book).
  [OBSERVED-IN-IMAGE, support + iphonejd]
- One App Store tile ("Learning Spanish") renders as a blue open-tray/box
  with white pages — possibly an icon variant or import-stack look;
  unconfirmed what it is. [OBSERVED-IN-IMAGE, UNKNOWN semantics]

### 2.4 List presentation

- Toggle lives in the four-squares menu: Grid ✓ / List rows.
  [OBSERVED-FIRST-PARTY, shot 08]
- Row anatomy (from a 2023 review screenshot and an official Favorites-list
  image; **no Gen-2 or official Documents-list image exists** — layout for
  Gen-2 Documents is INFERRED from these): full-width rows with thin
  hairline separators; small cover thumbnail (~60 px, real page-1 art) or
  colored folder glyph → title (blue link-style in those builds) with grey
  date line beneath → spacer → chevron-down (context menu) → star.
  Folder rows add an extra grey `>` disclosure chevron after the star.
  [OBSERVED-IN-IMAGE, mynexttablet Nov 2023 + support Favorites list;
  Gen-2 appearance INFERRED]
- No size column, no page count observed. [OBSERVED-IN-IMAGE]
- Swipe actions: no source describes any; likely absent. [INFERRED from
  absence across all sources] A support tip says "swipe across a row to
  quickly select it" **in select mode** — that is multi-select swipe-select,
  not a swipe action. [DESCRIBED-IN-PROSE, support]

### 2.5 Sizing, spacing, typography

- Only qualitative evidence exists: near-black content background, white
  titles, grey secondary text, blue accent (Gen-2 dark mode); light mode
  (older builds) is white/light-grey with pale grey sidebar and blue accent.
  Exact point sizes, insets, and gutter widths: UNKNOWN — measure from the
  first-party screenshots at build time. [OBSERVED-FIRST-PARTY /
  OBSERVED-IN-IMAGE]

---

## 3. Folder model

- A folder has: **name, color, icon, favorite flag**, plus children
  (documents and folders). [OBSERVED-FIRST-PARTY, shots 03/04 +
  OBSERVED-IN-IMAGE folder menu]
- **Color**: creation sheet offers a 9×3 swatch grid — 26 fixed swatches
  (row 1 deep/dark tints, row 2 medium, row 3 pale) plus a rainbow
  custom-picker wheel occupying the 27th position. Selected swatch shows a
  white check-in-circle; the live folder preview tracks selection.
  [OBSERVED-FIRST-PARTY, shot 04] The **edit** menu (chevron popover) shows
  only a single row of 9 color dots — creation and edit surfaces differ.
  [OBSERVED-IN-IMAGE, support attachment 13796798509199]
- **Icon**: a separate "Icon" segmented tab next to "Color". Contents never
  observed. Official prose says "color/emoji"; every observed rendered icon
  is a monochrome symbol glyph; iPhone J.D. (2023) counted **21 icons**
  ("apple, scales, happy face" — generic symbols, not emoji).
  **Unresolved disagreement**: emoji prose vs symbol glyphs. [DESCRIBED-IN-
  PROSE vs OBSERVED-IN-IMAGE; contents UNKNOWN]
- **Nesting**: no numeric limit documented ("as many documents and other
  folders as you need"); third parties tested 10+ levels; marketing says
  "unlimited". [DESCRIBED-IN-PROSE, support + mynexttablet + Paperlike]
- Folder cells and document cells share footprint and metadata layout
  (§2.2–2.3); the type difference is glyph vs thumbnail, plus list view's
  extra disclosure chevron.
- **Empty folder**: designed empty state — line-art illustration (smiling
  folder, sparkles, papers), bold "This Folder is Empty", grey subtitle
  "Create a new document or move existing ones here." **No CTA button** in
  the empty state; creation happens via the still-present "+ New" pill.
  [OBSERVED-FIRST-PARTY, shot 05]
- Free tier: folders effectively a paid-tier concept (free = 3-notebook
  limit, no folders). [DESCRIBED-IN-PROSE, apps400 — weak]

---

## 4. Navigation

- **Entering a folder pushes within the content pane** (slide-in from the
  side, per level — an App Store review complains about the "half second
  delay while I wait for the contents to slide in"). Title becomes small
  and centered (folder name); a circular back-chevron appears at the pane's
  top-left. Sidebar selection unchanged. [OBSERVED-FIRST-PARTY, shot 05 +
  DESCRIBED-IN-PROSE, App Store review v7.0.50]
- **Leaving**: back chevron pops one level. Community phrasing is uniform:
  "repeatedly pressing the back arrow", one level at a time.
  [DESCRIBED-IN-PROSE, feedback threads]
- **Breadcrumbs: none on iPad.** First-party depth-1 shows no breadcrumb;
  no iPad image at any depth shows one; the support "breadcrumb trail"
  (including drag-to-breadcrumb) language comes **only from the
  Android/Windows/Web article**. **Recorded disagreement**; depth ≥ 2 iPad
  rendering is formally UNKNOWN (no image retrievable), but every community
  description implies current-folder-title + back chevron only.
  [OBSERVED-FIRST-PARTY absence + DESCRIBED-IN-PROSE conflict]
- **Where location is displayed**: only the centered current-folder title.
  There is no path display anywhere in the observed UI. Reviewers complain
  wayfinding degrades past ~3 levels. [OBSERVED-FIRST-PARTY + DESCRIBED-IN-
  PROSE, beingpaperless]
- Folder contents appear to load on navigation, masked by the push
  animation. [INFERRED from the v7.0.50 review's "hide the loading time"]

---

## 5. Creation

### 5.1 The "+ New" entry point

- One unified affordance: the blue "+ New" pill in the toolbar. It is
  **contextual** — creation lands in the currently open folder (present
  inside folders, including empty ones; absent in Favorites).
  [OBSERVED-FIRST-PARTY, shots 01/02/05]
- Popover anchored under the pill (Gen-2 contents, exactly):
  - Row 1, three large square tiles: **Notebook**, **Whiteboard** ("NEW"
    pill), **Text Doc** ("NEW" pill).
  - Row 2, two wide tiles: **Import**, **Quick Record** (mic + plus).
  - List group: **QuickNote, Scan Documents, Study Set, Image, Take Photo**.
  - **Folder** in its own single-row card at the bottom.
  - Separate bottom row: **"Import from Cloud Storage"** with a green
    padlock pill (premium-locked). [OBSERVED-FIRST-PARTY, shot 03;
    corroborated OBSERVED-IN-IMAGE App Store + support]
- Gen-1 equivalent was a dashed "New…" first grid tile with a simpler menu
  (Notebook, Study Set, Folder, Image, Scan Documents, Take Photo, Import,
  QuickNote; "double tap '+' for QuickNote" tip). [OBSERVED-IN-IMAGE,
  Gen-1 only]

### 5.2 New Folder flow

- Full-screen modal over the blurred library. Chrome: circular dark **X**
  top-left, centered title "New Folder", circular blue **check** top-right.
- Large live folder preview (color tracks selection); wide rounded text
  field with centered grey placeholder **"Untitled"**; segmented control
  **Color | Icon** (Color selected by default); the 9×3 swatch grid of §3.
  [OBSERVED-FIRST-PARTY, shot 04]
- Naming is optional at creation (placeholder implies an "Untitled"
  default if left blank — INFERRED from placeholder).

### 5.3 New Notebook flow

- Same modal shell as New Folder (X / centered title / blue check) — one
  reusable component. [OBSERVED-FIRST-PARTY, shot 06]
- Left panel: "PAPER" label over a live paper preview with the template
  name beneath. Right panel rows: **Name** (placeholder "Untitled
  Notebook"), **Language** ("Auto Detect" + chevron), **Cover** (toggle,
  observed OFF). Then "PAPER TEMPLATES" section: **Size** ("Goodnotes
  Standard, Portrait" + chevron), **Color** (yellow dot + "Yellow" +
  chevron). Below the fold, a scrollable categorized template catalog with
  a blue "Edit" action: category "Essentials" with five cards (Blank,
  Dotted Paper [selected], Squared Paper, Ruled Narrow, Ruled Wide), each
  with three small color dots (cream/white/grey); next category "Writing
  Papers" cut off. [OBSERVED-FIRST-PARTY, shot 06]
- **Size dropdown**: popover with a Portrait/Landscape segmented control on
  top (orientation orthogonal to size) and a list: Goodnotes Standard ✓,
  A3, A4, A5, A6, A7 (iPhone), Letter, Tabloid, then **Custom** with a
  right-chevron pushing its own screen. [OBSERVED-FIRST-PARTY, shot 07]
- New-notebook settings are remembered as defaults for next time.
  [DESCRIBED-IN-PROSE, support (web article)]
- Cover ON produces the book-with-spine thumbnail; default cover "Simple"
  kraft-brown. [OBSERVED-IN-IMAGE, support/App Store]

---

## 6. Manipulation

### 6.1 Per-item chevron/context menu

- Affordance: the chevron-down next to the title (grid: under the
  thumbnail; list: right of the name). [OBSERVED-FIRST-PARTY chevron +
  DESCRIBED-IN-PROSE, support]
- **Document menu** (exact, from support attachment 7623479663375):
  editable title field at top (with clear-⊗), then **Duplicate, Move,
  Open in New Window, Export, Share Link to Collaborate, Move to Trash**
  (red, last). [OBSERVED-IN-IMAGE]
- **Folder menu** (exact, attachments 7572446062223 / 13796798509199):
  editable title field, **Color | Icon** segmented tabs, a row of **9 color
  dots** (current checkmarked), then **Move, Open in New Window, Export,
  Move to Trash** (red, last). Folders get **no Duplicate and no Share
  Link**. [OBSERVED-IN-IMAGE]
- These menu images predate the Gen-2 chrome; Gen-2 contents assumed the
  same (INFERRED — no Gen-2 menu image exists).
- **Rename is inline**: tap the title field in this popover, edit, "tap
  anywhere on the screen to confirm". No separate Rename row.
  [DESCRIBED-IN-PROSE + OBSERVED-IN-IMAGE]
- Favoriting is NOT in the menu — it is only the star on the cell.
  [OBSERVED-IN-IMAGE absence + DESCRIBED-IN-PROSE]
- Long-press context menu (as distinct from the chevron): no source
  distinguishes; standard UIKit long-press menus are
  INFERRED-FROM-PLATFORM only. UNKNOWN whether GoodNotes offers one.

### 6.2 Multi-select

- Entry: four-squares menu → **"Select Items"** (first row, circled-check
  glyph). [OBSERVED-FIRST-PARTY, shot 08] (Gen-1: separate checkmark icon.)
- Chrome (support attachment 7451414670863, Gen-1 image): top bar
  **"Select All" (left) — collection title (center) — "Done" (right)**;
  beneath it a centered action row **Export, Duplicate, Move, Trash (red)**
  with icons. Selected cells get a blue ✓-circle overlay on the thumbnail.
  [OBSERVED-IN-IMAGE; Gen-2 chrome INFERRED same]
- Official tip: "Swipe across a row to quickly select it" (swipe-select
  gesture in select mode). [DESCRIBED-IN-PROSE, support]

### 6.3 Move / destination picker

- **Prose only — never imaged.** Chevron menu → Move (or multi-select →
  Move at top). Picker behavior: "Tap the destination folder; if you tap a
  folder that contains subfolders, it will expand" (expandable tree). A
  top-right icon creates a new folder inside the selected destination.
  "Search, filter or sort can be used" in the picker. Confirm label:
  **"Move to…"**. From inside a document: tap title → "Move to a Different
  Folder". [DESCRIBED-IN-PROSE, support Moving article]
- Modal vs popover, recent-folders shortcuts: UNKNOWN.
- **Side effect**: moving an item updates the modified date used by sorting,
  so a moved note jumps to the top of a date sort — community complaint.
  [DESCRIBED-IN-PROSE, feedback thread]

### 6.4 Drag & drop

- "Select and hold for 1 second, then drag to the desired folder and
  release." [DESCRIBED-IN-PROSE, support — current Apple-platform article]
- Drag a doc/folder to the screen edge → opens in a new window; drag
  between windows moves the item. [DESCRIBED-IN-PROSE, support multi-window
  article]
- Drag onto the breadcrumb: **Android/Windows/Web article only** — not iPad
  evidence (no iPad breadcrumb exists; see §4).
- Drop-target highlighting, spring-loading into folders, multi-item drag,
  drag into the sidebar: UNKNOWN for GoodNotes; standard behaviors are
  INFERRED-FROM-PLATFORM only (support's "1 second" matches stock UIKit
  lift timing).

### 6.5 Duplicate, Export, Delete

- Duplicate: documents only (not folders), duplicates into the current
  folder. [OBSERVED-IN-IMAGE menu + DESCRIBED-IN-PROSE, Sweet Setup]
- Export from library: formats GoodNotes / PDF (editable|flattened) /
  Image; a folder exports as a single .zip preserving structure,
  re-importable. Gen-2 Export sheet observed: "Export Documents" modal,
  Cancel/Export, format tiles PDF (Flattened)/Image/Goodnotes, FILENAME
  field, toggles (Include Page Background, Include Annotation, Include
  Sticky Notes, PDF Data Format, Enable Handwriting Recognition).
  [OBSERVED-IN-IMAGE + DESCRIBED-IN-PROSE, support]
- Delete = **Move to Trash** (red, last menu row). Soft delete, always
  recoverable until trash emptied. One community source says delete prompts
  a confirmation; platform convention says recoverable deletes don't
  confirm — **conflicting/weak**; dialog wording UNKNOWN.
  [DESCRIBED-IN-PROSE, conflicting]
- Free tier: trashed notebooks still count against the 3-notebook limit
  until permanently deleted; the app surfaces an explanatory notice.
  [DESCRIBED-IN-PROSE, App Store review]

---

## 7. Sort and filter

### 7.1 Sort

- Control: inside the four-squares menu, below Select Items and Grid/List:
  **Date Created, Last Modified, Name, Type**. The active key shows a check
  and a **direction chevron shown only on the active key**; defaults
  observed **Grid + Last Modified, descending**. [OBSERVED-FIRST-PARTY,
  shot 08]
- Direction toggling: re-tapping the active key presumably flips the
  chevron (Files/Photos convention) — INFERRED-FROM-PLATFORM, not observed.
- Semantics: Date = most recent first; Name = alphabetical; **Type groups
  by file type with folders listed first**. [DESCRIBED-IN-PROSE, support
  (Android/Web caveat) + beingpaperless]
- **Persistence: sort is a single global setting, not per-folder** — a
  persistent complaint ("whatever option is chosen applies globally to all
  folders"). [DESCRIBED-IN-PROSE, feedback thread]
- Anomalies on record: folders reportedly sort by created date even under a
  date sort of documents ("only note is sorted, the folder is not")
  [DESCRIBED-IN-PROSE, feedback verbatim — weak]; moving an item bumps it
  to the top of date sort (§6.3). Manual/custom ordering does not exist
  (removed in the GN4 era, never returned). [DESCRIBED-IN-PROSE]
- Gen-1 had `Date | Name | Type` only; **Date Created vs Last Modified is a
  Gen-2 split** — build to Gen-2. [OBSERVED-IN-IMAGE both]

### 7.2 Filter

- Three-line funnel + "All" label, left end of the toolbar. Options:
  **All / Documents / Folders** (support prose: "choose Documents or
  Folders"; label reads "Folders" when applied — both states observed in
  support imagery). [OBSERVED-FIRST-PARTY control + OBSERVED-IN-IMAGE
  states + DESCRIBED-IN-PROSE]
- Favorites filter label — **disagreement, adjudicated**: support imagery
  shows "Any" in Favorites [OBSERVED-IN-IMAGE], but the first-party shot
  (re-viewed to confirm) shows **"All"** [OBSERVED-FIRST-PARTY, shot 02].
  First-party wins: Gen-2 label is "All". The Favorites option list is
  likely All/Any / Documents / Pages (/ Folders) — INFERRED from Sweet
  Setup GN5 + education snippets, unverified. An accidentally-left-on
  Favorites filter is a top cause of "missing favorites" complaints.
  [DESCRIBED-IN-PROSE, support]
- Filter persistence (per-collection vs global): UNKNOWN.

---

## 8. Search

- Entry (Gen-2): magnifier in the top-right capsule. (Gen-1: a Search
  sidebar tab.) [OBSERVED-FIRST-PARTY / OBSERVED-IN-IMAGE]
- Indexed content: handwriting (background OCR, 30+ languages, offline,
  paid-tier indexing, gated by Settings → Handwriting Recognition → "Index
  PDF and Handwritten Notes"), typed text, PDF text **only when the PDF
  already has a text layer** ("Goodnotes does not perform OCR on imported
  PDFs"), scanned docs, document titles, folder names, outlines.
  [DESCRIBED-IN-PROSE, support + mynexttablet]
- Matching: word-based; **no phrase search** (quoting does nothing).
  Community reports slowness and missed matches; the background indexer can
  degrade app performance. [DESCRIBED-IN-PROSE, complaints]
- **Scope change at ~v7.0.50**: historically search inside a folder scoped
  to that subtree while home search was global; v7.0.50 made even in-folder
  search global, to user anger. Whether reverted since: UNKNOWN.
  [DESCRIBED-IN-PROSE, App Store review — disagreement/version drift
  recorded]
- Results: tapping a result jumps to the exact spot in the document.
  Education-tenant docs describe grouping by document with matching pages
  beneath; MacStories (GN5) describes sections "Titles, Typed Notes,
  Written Notes". **Results screen never observed in any image**; Gen-2
  presentation UNKNOWN. [DESCRIBED-IN-PROSE]

---

## 9. Trash

- **Soft delete, no retention window**: "The trash will not be emptied
  automatically" — items stay until recovered, moved, or permanently
  deleted. (Contradicts 30-day folklore.) [DESCRIBED-IN-PROSE, support]
- **Access on iPad: top-right Goodnotes menu → Trash** (the gear/ellipsis/
  avatar-era menu), **not** a sidebar row. Sidebar Trash is
  Android/Windows/Web. One community source claims a GN6 sidebar Trash —
  **disagreement recorded**; first-party 2026 sidebar has no Trash row, so
  build target = behind the top-right menu (presumably the avatar in
  Gen-2 — INFERRED, since the gear it replaced held it).
  [DESCRIBED-IN-PROSE + OBSERVED-FIRST-PARTY absence]
- Trash Bin screen (observed): titled "Trash Bin"; top-right **Empty**
  (red) / **Select** / **Done** (blue); its own "All" filter row,
  four-squares, cloud; sortable (Date/Name/Type in that era's build).
  [OBSERVED-IN-IMAGE, support]
- Per-item chevron in trash offers **Recover** and **Delete Permanently**;
  multi-select offers Recover or Move (single destination).
  [DESCRIBED-IN-PROSE, support]
- **Recover returns items to their original locations**; if the original
  parent folder is itself still in the trash, recovered items land in root.
  [DESCRIBED-IN-PROSE, support]
- Empty Trash is irreversible; platform convention expects a destructive
  confirmation sheet [INFERRED-FROM-PLATFORM]; exact wording UNKNOWN.
- Deleting a shared document revokes collaborators' access; trashed items
  count against the free quota. [DESCRIBED-IN-PROSE, support]

---

## 10. Favorites

- A **flat, cross-parent smart collection**: mixes starred documents and
  starred folders from different parents in one grid; bookmarked pages also
  surface there. [OBSERVED-FIRST-PARTY, shot 02 + DESCRIBED-IN-PROSE]
- Star ON the thumbnail (top-right) toggles membership; un-star removes.
  Red filled = favorited; grey outline = not. Favoriting is not in any
  menu. [OBSERVED-FIRST-PARTY + DESCRIBED-IN-PROSE]
- **Bookmarked pages carry a distinct badge**: in the re-viewed first-party
  Favorites shot, most cells wear red five-pointed stars, but the bottom
  partial row shows red **bookmark-ribbon** badges instead — consistent
  with bookmarked pages surfacing as their own entries with a ribbon, not
  a star. [OBSERVED-FIRST-PARTY, shot 02; semantics corroborated
  DESCRIBED-IN-PROSE, MacStories/support]
- **No creation in Favorites** — the "+ New" pill is absent entirely.
  [OBSERVED-FIRST-PARTY, shot 02]
- A favorited folder appears as **one entry**; its contents do not surface
  individually. [INFERRED from support "missing Favorites" article +
  folders filter coherence]
- Favorites has its own filter (see §7.2 label disagreement); view options
  and cloud remain. Long titles wrap to two lines here (§2.2).
  [OBSERVED-FIRST-PARTY]
- Delete is possible from within Favorites via the title chevron menu.
  [DESCRIBED-IN-PROSE, support]

---

## 11. Empty, loading, and error states

- **Empty folder**: illustration + "This Folder is Empty" + "Create a new
  document or move existing ones here." No CTA button.
  [OBSERVED-FIRST-PARTY, shot 05]
- **Root/first run**: web app is "initially empty"; iPad official
  screenshots historically show a "Getting started with Goodnotes 6"
  starter notebook (Gen-1). A dedicated iPad first-run empty screen is
  undocumented. UNKNOWN for Gen-2. [DESCRIBED-IN-PROSE / OBSERVED-IN-IMAGE
  Gen-1]
- **Empty Favorites / empty Trash / empty search results**: never observed.
  UNKNOWN.
- **Loading**: folder contents load on push, masked by the ~0.5 s slide
  animation [INFERRED from v7.0.50 review]. Thumbnail loading placeholders
  and staleness behavior: UNKNOWN (no corpus).
- **Errors**: sync error renders two ways at once — the toolbar cloud icon
  turns red with an exclamation, and a floating bottom banner appears (red
  (!) icon, bold "Not Enough iCloud Storage", grey explanation, "OK" text
  button, blue filled "Settings" button). Per-item sync badges also exist
  (§2.2 corner fold). [OBSERVED-FIRST-PARTY, shot 05]

---

## 12. Open questions a builder must decide

Each is an UNKNOWN (or unresolved disagreement) that forces a design
decision in Phase 2:

1. **Depth ≥ 2 navigation** — no iPad evidence beyond depth 1. Decide:
   title + back chevron only (all community evidence points here), or add
   the breadcrumb/path affordance users beg for.
2. **Icon tab contents** — 21 symbol glyphs (2023) vs "emoji" (official
   prose). Decide the icon vocabulary and count.
3. **List view, Gen-2** — only a 2023 review image and an official
   Favorites list exist. Decide Gen-2 row anatomy, and whether swipe
   actions exist (evidence says no).
4. **Move picker presentation** — prose only. Decide modal vs popover,
   tree interaction, in-picker create/search/sort affordances.
5. **Search results screen** — never imaged. Decide grouping (by document
   with matching pages vs Titles/Typed/Written sections) and in-folder
   scope (subtree vs global; GoodNotes itself flip-flopped at v7.0.50).
6. **Trash entry point in Gen-2** — behind the avatar menu is inference.
   Decide where Trash lives and whether Move-to-Trash confirms.
7. **Long-press behavior** — chevron menu is proven; long-press context
   menu and drag-lift interplay are not. Decide the long-press contract.
8. **Keyboard/pointer support** — wholly undocumented. Decide the shortcut
   and pointer story from scratch.
9. **Portrait and collapsed-sidebar layouts** — no evidence (column counts,
   capsule placement). Decide adaptivity rules.
10. **Root first-run state** — starter notebook vs designed empty state.
11. **Metrics** — exact type sizes, insets, gutters, thumbnail aspect
    handling for landscape-page documents: measure from `images/*.png` or
    choose deliberately.
12. **Favorites filter label** ("All" first-party vs "Any" support) and
    its option list; filter persistence scope generally.
13. **Per-item sync badge semantics** (corner fold / warning triangle) —
    unexplained in all sources.
14. **Date thresholds** for relative vs absolute display.
15. **Sort details** — direction-toggle gesture; whether to reproduce
    GoodNotes' global-sort limitation and its folder/date anomalies, or fix
    them (fixing diverges from parity).

## 13. Source index

**First-party (primary, outranks all):**
`/Users/phil/Documents/Build_Week/TuberNotes-postoai/images/01–08.png` —
eight GoodNotes-on-iPad screenshots, Phillip's library, 2026-08-08, read by
the managing agent; observations in
`scratchpad/screenshot-observations.md`.

**Official (support.goodnotes.com, via Wayback/proxy; attachments viewed):**
articles 15303674514191, 7353757197711, 7353696186511, 7353756250383,
7353712039055, 7353728030479, 7353743683599, 7353743683471, 7353727934095,
7378598719759; viewed attachments incl. 7623479663375 (document menu),
7572446062223 / 13796798509199 (folder menu), 7451414670863 (select mode),
15340118488463 / 15339950682383 (Gen-2 sidebar), 7571000333967 (Gen-1
sidebar); goodnoteseducation.zendesk.com (snippets only, 403);
web.goodnotes.com (login-gated).

**App Store:** id1444383602, iPad screenshots ASO_EN_iPad_1,2,3,4,7,8,10
(viewed).

**Reviews/hands-on:** mynexttablet.com (list-view image, Nov 2023, viewed;
nesting test), iphonejd.com (folder grid viewed; 21-icon count),
beingpaperless.com (sort semantics, depth complaint), Paperlike blog
(nesting), Sweet Setup (GN5 multi-select), Inkwrit 2026 tutorial,
MacStories GN5 review (search sections, favorites).

**Community:** feedback.goodnotes.com threads (navigation-at-depth, global
sort, folder sort anomaly, move-breaks-date-sort, manual ordering, sidebar
tree requests); US App Store reviews via iTunes RSS (v7.0.50 search-scope
and push-transition reviews, free-tier trash quota); MacRumors thread;
apps400 (free-tier folders).

**Locally retained images:** `scratchpad/imgs/` (support attachments),
`scratchpad/mynexttablet-ui.jpeg`, `scratchpad/iphonejd-folders.jpg`,
`scratchpad/inkwrit-lib.jpeg`.
