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

- **`CADFileLoader`** — `Shape` → `ViewportBody` conversion (`shapeToBodyAndMetadata`) and STEP/STL/
  OBJ/BREP loading; produces triangulated meshes plus picking metadata.
- **`CADBodyMetadata`** / **`CADLoadResult`** / **`CADFileFormat`** — face/edge/vertex indices for
  sub-body selection, the aggregated load result (bodies + metadata + shapes + GD&T), and the
  input-format enum (`.step`, `.stl`, `.obj`, `.brep`).
- **`FaceIdentityTable`** / **`EdgeIdentityTable`** / **`VertexIdentityTable`**: resolve a
  render-path face/edge/vertex ordinal (as stored in `ViewportBody.faceIndices` /
  `edgeIndices` / `vertexIndices`) back to its `Shape` and, when a `BRepGraph` is supplied, its
  durable `GraphUID`. Obtained from `CADFileLoader.shapeToBodyMetadataAndIdentity` (face only) or
  `shapeToBodyMetadataAndIdentities` (all three).
- **`ExportManager`** / **`ExportFormat`** — shape export to OBJ / PLY / STEP / BREP.
- **Per-domain converters** — `CurveConverter` (`curve2DToBody` / `curve3DToBody`),
  `SurfaceConverter` (UV isoparametric grid bodies), `WireConverter` (wire → edge polyline),
  `PointConverter` (points → point-cloud body).
- **`BodyUtilities`** — `makeMarkerSphere()`, `offsetBody()` helpers.
- **`ScriptManifest`** — JSON manifest types for script-harness integration.
