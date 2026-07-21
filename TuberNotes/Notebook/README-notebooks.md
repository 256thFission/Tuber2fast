# Notebook surface

The product-facing notebook flow opens on a local library, then enters a
zoomable PencilKit page with a compact floating toolbar.

## User flow

- Create a notebook by choosing a title, cover, and paper template.
- Tap a cover to open it; long-press the card to rename or delete it.
- Draw with pen, pencil, highlighter, or eraser; change color and stroke width
  from the toolbar.
- Use the lasso to select and move strokes.
- Use the adjacent sparkle-lasso to refine a region and apply the result directly
  to the page; refinement changes drawing/image state, never an Agentic Layer.
- Add images, pages, and drawing layers without leaving the page.
- Import a version 3 `.spud` file from the library. The imported document opens
  as a new notebook, preserving its page and content identities without
  overwriting an existing library item.
- Export the complete notebook as PDF or as an editable `.spud` archive. PDF
  preserves every page's visible ink in order but remains drawing-only, with no
  Pin, citation, or conversation markup. `.spud` preserves the full notebook,
  including page identities, templates, images, drawing layers, Pins, Agentic
  Layer visibility, cover, settings, and timestamps. SPUD is a prerelease,
  version-3-only format; earlier experimental versions are not accepted.

## Agentic layers and Pins

Pins are persisted only inside `Notebook.agenticLayers` through
`ConversationLayer.conversations`. They are not stored on `NotebookPage` or
exposed as a separate global canvas tool.

Each Agentic Layer chip is an explicit hidden/active toggle. Activating one
shows only its Pins for the current page; tapping the active chip, selecting a
drawing tool, or selecting a drawing layer fully hides Agentic Layer content.
The toolbar's filled gradient, animated page-edge glow, and colored ambient
background gradients appear only while an Agentic Layer is active, not merely
while the layer picker is open. Hiding it returns the ambient background to its
neutral white/gray treatment.

“Ask on this layer” opens the frosted question panel. Its answer is persisted as
a Pin at the selection center on the active Agentic Layer, so closing the panel
does not discard the visual result.

The question panel derives a cycle-safe conversation history from those same
persisted Pins. Selecting a response continues the same lineage from that
point; the next response reuses its page region and bounded lineage context,
persists an optional parent-thread link, and becomes the active continuation.
Returning to an earlier response can diverge from the later path, but ordinary
follow-ups are presented as continuation rather than branching. Expand a
completed Pin to Continue from it directly. Drag the Pin dot to move its
page-normalized anchor; the original semantic selection region stays unchanged.

## Visual character

The editor keeps the page legible on white paper while the surrounding chrome
uses a dark ambient field, frosted controls, touch ripples, tactile button
feedback, and a small cover-opening animation. Reduce Motion is respected where
the system exposes it.

## Persistence

`NotebookStore` writes one JSON file per notebook under
`Documents/Notebooks/<uuid>.json`. PencilKit drawings are stored as serialized
data per drawing layer. Older single-drawing pages decode into a first drawing
layer so existing local notebooks remain readable.
