---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTSwiftTools
tags: [index]
description: Public modules / API surfaces exposed by OCCTSwiftTools.
timestamp: 2026-07-20
---

# Components

The library exposes a single product/target, `OCCTSwiftTools`. Its public surface (from the README
and SPEC.md):

- **`CADFileLoader`**: `Shape` → `ViewportBody` conversion (`shapeToBodyAndMetadata`) and STEP/STL/
  OBJ/BREP loading; produces triangulated meshes plus picking metadata.
- **`CADBodyMetadata`** / **`CADLoadResult`** / **`CADFileFormat`**: face/edge/vertex indices for
  sub-body selection, the aggregated load result (bodies + metadata + shapes + GD&T + per-body
  identity), and the input-format enum (`.step`, `.stl`, `.obj`, `.brep`).
- **`FaceIdentityTable`** / **`EdgeIdentityTable`** / **`VertexIdentityTable`**: resolve a
  render-path face/edge/vertex ordinal (as stored in `ViewportBody.faceIndices` /
  `edgeIndices` / `vertexIndices`) back to its `Shape` and, when a `BRepGraph` is supplied, its
  durable `GraphUID`. Each table's index space is the ordinal space, which is why the two built
  through a failable conversion hold `[Shape?]` and the vertex table holds `[Shape]`
  (OCCTSwiftInteraction#9).
- **`ShapeIdentity`**: the one place a `Shape` becomes those three tables (OCCTSwiftInteraction#7),
  holding the shape, its `BRepGraph` and all three. `init(shape:graph:)` takes a graph the caller
  holds (`nil` gives shapes without uids); `init(shape:)` mints one. A file load returns one per
  body via `CADLoadResult.identity` when called with `includeIdentity: true`, which is what stops
  a consumer pairing `shapes` with `bodies` positionally. `shapeToBodyMetadataAndIdentity` (face
  only) and `shapeToBodyMetadataAndIdentities` (all three) remain as the one-pass mesh-plus-identity
  convenience.
- **`SubShapePickResolver`**: the one canonical pick resolver: a GPU pick's primitive index in, a
  `SubShapeRef` out, handling the `faceIndices` / `edgeIndices` / `vertexIndices` indirection, the
  bounds checks, the empty-`vertexIndices` identity mapping, and the identity-table-over-re-derivation
  rule. Identity only: the selection-mode gate, clip-plane pre-filter and geometry enrichment stay in
  the layers that own them.
- **`SubShapeRef`** / **`SubShape`** / **`InteractiveObject`**: the types naming a picked piece of
  topology and the scene entry it belongs to. Moved down from the `OCCTSwiftAIS` target
  (OCCTSwiftInteraction#2), which keeps source-compatible typealiases.
- **`ExportManager`** / **`ExportFormat`**: shape export to OBJ / PLY / STEP / BREP.
- **Per-domain converters**: `CurveConverter` (`curve2DToBody` / `curve3DToBody`),
  `SurfaceConverter` (UV isoparametric grid bodies), `WireConverter` (wire → edge polyline),
  `PointConverter` (points → point-cloud body).
- **`BodyUtilities`**: `makeMarkerSphere()`, `offsetBody()` helpers.
- **`ScriptManifest`**: JSON manifest types for script-harness integration.
