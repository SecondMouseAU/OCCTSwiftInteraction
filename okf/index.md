---
type: repo
title: OCCTSwiftCADKit
resource: https://github.com/SecondMouseAU/OCCTSwiftCADKit
tags: [cad, occt, viewport, metal, swiftui, step, stl, brep, face-picking, edge-picking, vertex-picking, durable-identity, multi-body, assembly, multi-selection, scalar-field, deviation-heatmap, comparison, reconstruction-review, clipping, section-planes, escalation, human-in-the-loop, kernel]
description: Shared SwiftUI Metal CAD viewport plus STEP/STL/BREP import (single-shape or multi-body/assembly), face/edge/vertex picking (single or multi-select), scalar field / deviation heatmap display, mesh/solid comparison, clipping/section planes, and human-in-the-loop escalation for OCCT-based apps.
timestamp: 2026-07-23
---

# OCCTSwiftCADKit

> A reusable SwiftUI Metal viewport plus CAD file import (STEP/STL/BREP, single-shape or as several
> coexisting, addressable entities for an assembly), face/edge/vertex picking (single- or
> multi-select, with aggregate summaries), scalar field display (deviation heatmaps and similar,
> per face or per triangle), mesh/solid comparison display (ghosting, deviation heatmap,
> side-by-side, spatial wipe) for reconstruction review, clipping/section planes (hollow or
> solid-capped, with clip-aware picking), and human-in-the-loop escalation (`present(_:) async ->
> EscalationResponse`, grounding a bounded question in highlighted geometry) for apps built on
> OCCTSwift and OCCTSwiftViewport. Extracted from PadCAM's `CADViewportService` /
> `CADViewportView` so multiple OCCT-based apps can share the same viewport plumbing without
> forking it.

## Role in the ecosystem

- **Cluster:** kernel
- **Depends on:** [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) (geometry kernel), [OCCTSwiftViewport](https://github.com/SecondMouseAU/OCCTSwiftViewport) (Metal renderer), [OCCTSwiftTools](https://github.com/SecondMouseAU/OCCTSwiftTools) (Shape ↔ ViewportBody bridge / file utilities), and [OCCTSwiftAIS](https://github.com/SecondMouseAU/OCCTSwiftAIS) (interactive services).
- **Feeds:** OCCT-based applications (PadCAM, the UnfoldEngine test app, and similar) that need a drop-in CAD viewport. Note: its viewport-service role is also being absorbed into OCCTSwiftUX's `OCCTSwiftUXViewportService` layer.

## Components

See [`components/`](components/index.md) for the public surface.

## References

See [`references/`](references/index.md) for sibling repos and upstream links.

## Policies

- [Query `context` first for OCCT / OCCTSwift docs](policies/context-first.md)
- [Documentation updates are mandatory](policies/docs-current.md)
- [No em-dashes, banned words in prose](policies/writing-style.md)
