---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTSwiftAIS
tags: [index, api]
description: OCCTSwiftAIS public API: one library target covering selection, manipulators, dimensions, and scene objects.
timestamp: 2026-06-22
---

# Components

`OCCTSwiftAIS` ships a single public library/target, **`OCCTSwiftAIS`** (over `OCCTSwiftTools`).
Its API surface groups into:

- **Selection-from-topology**: pick body / face / edge / vertex; round-trip the GPU pick to a
  `TopoDS_Face` / `Edge` / `Vertex` handle on the source `Shape`. `InteractiveContext`,
  `selectionMode`, `Selection`. Identity resolution itself is
  `OCCTSwiftTools.SubShapePickResolver`'s since OCCTSwiftInteraction#2; what stays here is the
  selection-mode gate and the whole-body fallback, both selection-mode decisions rather than
  identity ones. `SubShapeRef` / `SubShape` / `InteractiveObject` moved down to `OCCTSwiftTools`
  with source-compatible typealiases left behind.
  **`InteractiveContext.selection` is the package's only selection store since
  OCCTSwiftInteraction#3**: `OCCTSwiftCADKit.CADViewportService` drives it rather than keeping a
  parallel one, so `CADViewportService.selection` is a projection of it and
  `CADViewportService.selectionModes` is `selectionMode` itself. `select(_:scheme:)` gained the
  four-scheme parameter from CADKit's version; `select(_:)` is unchanged and still means `.add`.
  `displaysBody(withID:)` lets such a host tell its own composited bodies from this context's.
- **Manipulator widgets**: translate / rotate gizmos with `snapTranslate` / `snapRotateDeg` on the
  renderer's overlay layer; SwiftUI integration via `.attachManipulator(_:)`.
- **Dimensions**: `LinearDimension`, `AngularDimension`, `RadialDimension` with topology-aware
  anchors feeding OCCTSwiftViewport's `MeasurementOverlay`.
- **Standard scene objects**: `Trihedron`, `WorkPlane`, `Axis`, `PointCloudPresentation`.
- **Selection survival**: `InteractiveContext.remap(_:using:rebindingTo:)` translates a
  pre-mutation `Selection` to post-mutation shape indices via OCCTSwift history records.
- **Presentation styles**: `PresentationStyle` (`.default`/`.ghosted`/`.highlighted`/
  `.hovered`/`.agentHighlight`), `DisplayMode`, `HighlightStyle`. `.agentHighlight`
  (OCCTSwiftInteraction#16) is a distinct hollow (`.wireframe`) treatment for a highlight an
  agent requested via `OCCTSwiftCADKit.CADViewportService.startSelectionSidecar(directory:)`,
  so a viewer can tell it apart from a human's ordinary `.highlighted` selection.
