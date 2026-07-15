---
name: spatial-debugging
description: Diagnose TuberNotes coordinate conversion and spatial anchoring defects, including crop-relative, page-normalized, canvas, and view coordinates or Pin drift during pan and zoom.
---

# Spatial debugging

1. Label every value with its coordinate space and bounds. Never persist screen coordinates.
2. Trace one known point: crop-normalized → crop pixels → page-normalized → canvas content → view.
3. Verify the crop origin is added exactly once; scale and content offsets are applied in the correct order; y-axis conventions match; and zoom is not applied twice.
4. Use deterministic DEBUG Pins or a fixture at corners, center, and a non-symmetric point such as `(0.69, 0.49)`.
5. Check the same anchors before and after pan, zoom, rotation, and layout changes. A correct Pin moves with page content and keeps its page-normalized location. Capture before/after via `DeveloperTools/verify-scenario.sh` (`fake-pin` and `multi-pin`) once viewport transforms exist.
6. Keep conversion functions small and explicit. Add focused tests only for transforms that can regress independently, then inspect the simulator.
7. Report coordinate-space findings in the evidence packet (`Docs/templates/EvidencePacket.md`); stop after repeated failure rather than inventing a parallel coordinate system.

