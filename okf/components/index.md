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

- **`CADViewportService`** — `@Observable @MainActor` service that owns the loaded geometry, drives the
  Metal viewport, and routes picking results via `selected: PickedEntity?`, gated by
  `selectionModes: Set<SelectionMode>` (default `[.face]`; add `.edge`/`.vertex` to opt in).
  `selectedFace: PickedFaceInfo?` still works as a deprecated face-only convenience.
  `load(_:id:transform:)` / `loadFile(from:id:progress:)` / `loadFromData(_:filename:id:progress:)`
  display several parts or assembly occurrences as distinct, addressable **entities**
  (`loadedShapes`, `shape(id:)`, `entityID(forBodyID:)`, `visibility`, `remove(id:)`, `removeAll()`,
  `focus(on:)`); the single-shape `loadFile(from:)`/`loadShape(_:id:)`/`loadFromData(_:filename:)`
  still work as a deprecated convenience, and are safe to mix with the new API — both register in
  the same internal entity registry. Caller geometry (stock boxes, toolpaths, flat-pattern outlines,
  annotations) is staged via
  `setOverlay(id:bodies:)` / `clearOverlay(id:)`.
- **`CADViewportView`** — SwiftUI wrapper around the Metal viewport with a selection-info banner and
  display-mode controls.
- **`PickedEntity`** — `.face(PickedFaceInfo)` / `.edge(PickedEdgeInfo)` / `.vertex(PickedVertexInfo)`,
  plus a `bodyID` accessor common to all three (pass to `entityID(forBodyID:)`).
- **`PickedFaceInfo`, `PickedEdgeInfo`, `PickedVertexInfo`, `FaceBounds`** — metadata returned by
  picking (no CAM- or unfold-specific deps). Each info type's `.shape`/`.uid` are the durable identity
  of the pick (captured from the body's `FaceIdentityTable`/`EdgeIdentityTable`/`VertexIdentityTable`);
  `.faceIndex`/`.edgeIndex`/`.vertexIndex` are ephemeral render-path ordinals only.
- **`CADViewportError`** — `unsupportedFormat`, `emptyFile`, `loadFailed`.
