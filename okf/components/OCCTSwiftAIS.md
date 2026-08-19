---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTSwiftAIS
tags: [index, api]
description: OCCTSwiftAIS public API — one library target covering selection, manipulators, dimensions, and scene objects.
timestamp: 2026-06-22
---

# Components

`OCCTSwiftAIS` ships a single public library/target, **`OCCTSwiftAIS`** (over `OCCTSwiftTools`).
Its API surface groups into:

- **Selection-from-topology** — pick body / face / edge / vertex; round-trip the GPU pick to a
  `TopoDS_Face` / `Edge` / `Vertex` handle on the source `Shape`. `InteractiveContext`,
  `selectionMode`, `Selection`.
- **Manipulator widgets** — translate / rotate gizmos with `snapTranslate` / `snapRotateDeg` on the
  renderer's overlay layer; SwiftUI integration via `.attachManipulator(_:)`.
- **Dimensions** — `LinearDimension`, `AngularDimension`, `RadialDimension` with topology-aware
  anchors feeding OCCTSwiftViewport's `MeasurementOverlay`.
- **Standard scene objects** — `Trihedron`, `WorkPlane`, `Axis`, `PointCloudPresentation`.
- **Selection survival** — `InteractiveContext.remap(_:using:rebindingTo:)` translates a
  pre-mutation `Selection` to post-mutation shape indices via OCCTSwift history records.
