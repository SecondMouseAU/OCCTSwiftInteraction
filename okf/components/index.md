---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTSwiftCADKit
tags: [index, api]
description: OCCTSwiftCADKit public API — one library target wrapping the CAD viewport service and view.
timestamp: 2026-06-22
---

# Components

`OCCTSwiftCADKit` ships a single public library/target, **`OCCTSwiftCADKit`**. Its API surface:

- **`CADViewportService`** — `@Observable @MainActor` service that owns the loaded `Shape`, drives the
  Metal viewport, and routes face-picking results via `selectedFace: PickedFaceInfo?`. Caller geometry
  (stock boxes, toolpaths, flat-pattern outlines, annotations) is staged via
  `setOverlay(id:bodies:)` / `clearOverlay(id:)`; files load through `loadFile(from:)`.
- **`CADViewportView`** — SwiftUI wrapper around the Metal viewport with a selection-info banner and
  display-mode controls.
- **`PickedFaceInfo`, `FaceBounds`** — face metadata returned by picking (no CAM- or unfold-specific deps).
  `PickedFaceInfo.shape`/`.uid` are the durable identity of the pick (captured from the body's
  `FaceIdentityTable`); `.faceIndex` is an ephemeral render-path ordinal only.
- **`CADViewportError`** — `unsupportedFormat`, `emptyFile`, `loadFailed`.
