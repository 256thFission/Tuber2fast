# First-class PDF and image annotation support

Status: deferred vision, not an active contract  
Scope: design direction only. No implementation, no prescribed types, no future abstractions in code.

## Purpose

This note records what "first-class" PDF and image annotation means for TuberNotes, why it is better than treating a PDF as a static background, and why `Just a Canvas` does not attempt any of it. It exists so later milestones do not have to rediscover these requirements.

## What first-class means

PDFs and images are addressable, transformable, replaceable layers with durable semantic relationships to ink, highlights, text comments, and shapes. The app can import, annotate non-destructively, edit, and export to standard formats without losing meaning.

## Better-than-GoodNotes properties

GoodNotes stores annotations in a proprietary stroke model and typically exports a PDF with flattened ink. TuberNotes should win on semantic fidelity, editability, and interchange.

### 1. Source-aware layers

A page is a composition of layers. A layer can be:

- a PDF page, preserved as the original PDF bytes;
- a raster image, preserved at original resolution;
- an ink group;
- a highlight;
- a text comment; or
- a shape.

Each layer carries a page-space transform (translate, scale, rotation). Replacing or moving the PDF layer leaves attached annotations correctly positioned. Rotation and crop are transforms, not destructive rewrites.

### 2. Real coordinate mapping

Page space remains the durable truth. Every asset layer also exposes its source coordinate space:

- PDF page points,
- image pixels,
- normalized `[0,1]` coordinates only for interchange.

There is an explicit, invertible mapping from source space to page space. Ink can be authored in page space or anchored to a source layer. View and canvas spaces stay non-durable and owned by the canvas runtime.

### 3. Semantic annotations, not just strokes

- **Highlights** are vector rectangles anchored to PDF text bounds, so underlying text can be extracted and highlights survive source reflow where possible.
- **Ink annotations** remain vector strokes.
- **Text comments** are stored as text, not rendered bitmaps.
- **Signatures** are a distinct ink type that can be exported as an annotation or flattened.

### 4. Non-destructive persistence

The file model moves from the single binary property list to a document package or manifest-plus-assets model:

- original PDF/image assets stored with checksums;
- vector ink and annotation metadata stored separately;
- incremental saves that touch only changed layers;
- a defined migration from `Just a Canvas`'s single-file format.

### 5. Performance at notebook scale

- Tile-based, on-demand PDF rendering. Never rasterize a whole document at import.
- Lazy page and asset loading.
- Spatial index for strokes so hit-testing, lasso, and eraser scale with visible content, not total notebook size.
- All decoding, OCR, and file work stays off the interaction path and main thread.

### 6. Search and export

- Search across PDF text, OCR'd image text, and annotation text.
- Export to standard PDF with real annotations preserved, not just a flattened bitmap.
- Export pages/images with annotations baked when the target format requires it.

### 7. Precise tools

- Vector eraser.
- Lasso selection across ink and embedded objects.
- Shape recognition.
- Selection that understands layers and anchors.

## Relationship to `Just a Canvas`

`Just a Canvas` deliberately excludes PDFs, images, rotation, crop, multiple pages, layers, and annotation semantics. Its job is to prove that the live ink runtime, ownership boundaries, and atomic save loop can be trusted on a single blank page.

When PDF/image support becomes the active milestone, the contract, file format, page model, and possibly the ownership boundaries may need to be retooled or torn down. That is an intended outcome. The foundation is meant to be proven, not assumed to scale.
