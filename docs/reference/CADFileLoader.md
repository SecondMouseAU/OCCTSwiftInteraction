---
title: CADFileLoader
parent: API Reference
---

# CADFileLoader

The bridge between CAD files and renderable geometry. `CADFileLoader` wraps
OCCTSwiftIO's headless `ShapeLoader` and converts the resulting shapes into
`ViewportBody` + `CADBodyMetadata` for renderable, pickable consumers. It also
exposes the standalone `Shape` → body bridge (`shapeToBodyAndMetadata`) and two
mesh-quality presets. For headless, shape-only work with no Viewport dependency,
use `OCCTSwiftIO.ShapeLoader` directly instead.

## Topics

- [load](#cadfileloaderload) · [loadFromManifest](#cadfileloaderloadfrommanifest) · [shapeToBodyAndMetadata](#cadfileloadershapetobodyandmetadata)
- Identity-table overloads: [shapeToBodyMetadataAndIdentity](#cadfileloadershapetobodymetadataandidentity) · [shapeToBodyMetadataAndIdentities](#cadfileloadershapetobodymetadataandidentities)
- Presets & defaults: [`highQualityMeshParams`](#mesh-presets) · [`tessellationMeshParams`](#mesh-presets) · [`defaultEdgeDeflection`](#static-defaults) · [`defaultMaxPointsPerEdge`](#static-defaults)
- [`CADLoadResult`](#cadloadresult)

---

## `CADFileLoader.load(...)`

Loads a CAD file and returns viewport bodies with selection metadata. STL and
IGES loads that fail the primary bridge are transparently re-loaded via the
robust sewing/healing variants (`Shape.loadSTLRobust` / `Shape.loadIGESRobust`);
STEP / OBJ / BREP have no fallback.

When the robust reload returns a multibody result — since OCCTSwift v1.11.3 a
sewn multibody STL comes back as a compound of solids
([OCCTSwift#302](https://github.com/SecondMouseAU/OCCTSwift/issues/302)) — it is
split into **one `ViewportBody` per body** rather than one lumped body, matching
the STEP path. Note the *primary* STL path meshes loose faces as a single body:
per-body identity for a mesh file only arises once sewing has recovered solids,
i.e. on the robust reload.

```swift
public static func load(
    from url: URL,
    format: CADFileFormat,
    progress: ImportProgress? = nil
) async throws -> CADLoadResult
```

- **Parameters:**
  - `url` — file URL to load.
  - `format` — the `CADFileFormat` (`.step`, `.iges`, `.stl`, `.obj`, `.brep`, …).
  - `progress` — optional progress + cancellation observer. Honoured by `.step` and `.iges` only — STL / OBJ / BREP are single-call upstream. If `progress.shouldCancel()` returns `true`, the import throws `OCCTSwift.ImportError.cancelled`.
- **Returns:** a `CADLoadResult` with bridged bodies, per-body metadata, raw shapes, and any PMI (dimensions / tolerances / datums).
- **Example:**
  ```swift
  let result = try await CADFileLoader.load(
      from: URL(fileURLWithPath: "/path/bracket.step"),
      format: .step
  )
  ```

---

## `CADFileLoader.loadFromManifest(...)`

Loads bodies from a script manifest (`manifest.json` plus its referenced BREP
files), applying each body's recorded colour. Synchronous.

```swift
public static func loadFromManifest(at url: URL) throws -> CADLoadResult
```

- **Parameters:**
  - `url` — file URL of the `manifest.json`.
- **Returns:** a `CADLoadResult` whose bodies use ids of the form `"script-<descriptor.id>"` and fall back to grey `(0.7, 0.7, 0.7, 1)` where no colour was recorded.
- **Example:**
  ```swift
  let result = try CADFileLoader.loadFromManifest(
      at: URL(fileURLWithPath: "/path/output/manifest.json")
  )
  ```

---

## `CADFileLoader.shapeToBodyAndMetadata(...)`

Converts an OCCTSwift `Shape` to a `ViewportBody` and optional
`CADBodyMetadata`. Meshes the shape (using the high-quality preset by default),
applies crease-aware normal smoothing, extracts wireframe edge polylines, and
gathers source-shape vertices for picking. If meshing fails it still returns an
edge-only body when edge polylines could be extracted.

```swift
public static func shapeToBodyAndMetadata(
    _ shape: Shape,
    id bodyID: String,
    color rgba: SIMD4<Float>,
    stl: Bool = false,
    deflection customDeflection: Double? = nil,
    gpuTessellation: Bool = false,
    edgeDeflection: Double = defaultEdgeDeflection,
    maxPointsPerEdge: Int = defaultMaxPointsPerEdge,
    includeMeasurements: Bool = false
) -> (ViewportBody?, CADBodyMetadata?)
```

- **Parameters:**
  - `shape` — the OCCTSwift shape to bridge.
  - `id` — body identifier.
  - `color` — RGBA body colour.
  - `stl` — if `true`, uses a coarser deflection (1.0) suitable for pre-tessellated STL data.
  - `deflection` — custom linear deflection override; lower = smoother.
  - `gpuTessellation` — if `true`, uses the coarser `tessellationMeshParams` preset (GPU PN triangles refine it).
  - `edgeDeflection` — linear deflection for the **wireframe edge polylines** (independent of the triangle deflection). Defaults to `defaultEdgeDeflection` (0.005).
  - `maxPointsPerEdge` — hard cap on points per edge polyline. Defaults to `defaultMaxPointsPerEdge` (1000).
  - `includeMeasurements` — if `true`, populates `metadata.measurements` with per-face areas and per-edge lengths (via `Shape.measure`). Off by default — O(faces).
- **Returns:** a tuple `(ViewportBody?, CADBodyMetadata?)`. Both elements are `nil` when meshing fails **and** no edge polylines could be extracted.
- **Example:**
  ```swift
  let (body, meta) = CADFileLoader.shapeToBodyAndMetadata(
      Shape.box(width: 10, height: 5, depth: 3)!,
      id: "box",
      color: SIMD4<Float>(0.6, 0.6, 0.65, 1),
      includeMeasurements: true
  )
  ```

---

## `CADFileLoader.shapeToBodyMetadataAndIdentity(...)`

Overload of `shapeToBodyAndMetadata` that also emits a [`FaceIdentityTable`](FaceIdentityTable)
mapping every ordinal in the returned metadata's `faceIndices` back to the `Shape` it was
tessellated from, and, when `graph` is supplied, to the durable `GraphUID` minted from that graph.
See [FaceIdentityTable](FaceIdentityTable) for why this exists: a face ordinal resolved via
`shape.subShapes(ofType: .face)[ordinal]` silently misaligns once a face is shared between two
shells, and this captures the correspondence directly instead.

```swift
public static func shapeToBodyMetadataAndIdentity(
    _ shape: Shape,
    id bodyID: String,
    color rgba: SIMD4<Float>,
    stl: Bool = false,
    deflection customDeflection: Double? = nil,
    gpuTessellation: Bool = false,
    edgeDeflection: Double = defaultEdgeDeflection,
    maxPointsPerEdge: Int = defaultMaxPointsPerEdge,
    includeMeasurements: Bool = false,
    directMesh useDirectMesh: Bool = false,
    graph: TopologyGraph? = nil
) -> (ViewportBody?, CADBodyMetadata?, FaceIdentityTable?)
```

- **Parameters:** same as `shapeToBodyAndMetadata`, plus `graph`, an optional `TopologyGraph` built from this same `shape`. When supplied, it populates `FaceIdentityTable.uids`, minted via `graph.findNode(for:)` on each ordinal's face so `IsSame` semantics hold. Without a graph, only `FaceIdentityTable.shapes` is populated.
- **Returns:** a tuple `(ViewportBody?, CADBodyMetadata?, FaceIdentityTable?)`. `shapeToBodyAndMetadata` itself is unchanged; this is a separate, additive overload.
- **Example:**
  ```swift
  let box = Shape.box(width: 10, height: 5, depth: 3)!
  let graph = TopologyGraph(shape: box)!
  let (body, meta, faceTable) = CADFileLoader.shapeToBodyMetadataAndIdentity(
      box, id: "box", color: SIMD4<Float>(0.6, 0.6, 0.65, 1), graph: graph
  )
  ```

---

## `CADFileLoader.shapeToBodyMetadataAndIdentities(...)`

Overload of `shapeToBodyAndMetadata` that emits identity tables for all three pickable sub-shape
kinds: [`FaceIdentityTable`](FaceIdentityTable), [`EdgeIdentityTable`](EdgeIdentityTable),
[`VertexIdentityTable`](VertexIdentityTable). Each maps the render-path ordinal stored in the
corresponding `ViewportBody` array (`faceIndices` / `edgeIndices` / `vertexIndices`) back to the
`Shape` it was extracted from, and, when `graph` is supplied, to the durable `GraphUID` minted from
that graph.

```swift
public static func shapeToBodyMetadataAndIdentities(
    _ shape: Shape,
    id bodyID: String,
    color rgba: SIMD4<Float>,
    stl: Bool = false,
    deflection customDeflection: Double? = nil,
    gpuTessellation: Bool = false,
    edgeDeflection: Double = defaultEdgeDeflection,
    maxPointsPerEdge: Int = defaultMaxPointsPerEdge,
    includeMeasurements: Bool = false,
    directMesh useDirectMesh: Bool = false,
    graph: TopologyGraph? = nil
) -> (ViewportBody?, CADBodyMetadata?, FaceIdentityTable?, EdgeIdentityTable?, VertexIdentityTable?)
```

- **Parameters:** same as `shapeToBodyMetadataAndIdentity`. Pass a `TopologyGraph` built from this same `shape` to populate every table's `uids`; without one, only `shapes` is populated on each table.
- **Returns:** a five-element tuple. `shapeToBodyAndMetadata` and `shapeToBodyMetadataAndIdentity` are both unchanged; this is a separate, additive overload rather than an extension of either existing return shape.
- **Example:**
  ```swift
  let box = Shape.box(width: 10, height: 5, depth: 3)!
  let graph = TopologyGraph(shape: box)!
  let (body, meta, faceTable, edgeTable, vertexTable) = CADFileLoader.shapeToBodyMetadataAndIdentities(
      box, id: "box", color: SIMD4<Float>(0.6, 0.6, 0.65, 1), graph: graph
  )
  ```

---

## Mesh presets

Two `MeshParameters` presets steer `shapeToBodyAndMetadata`. They are public so
you can inspect or reuse them.

```swift
public static let highQualityMeshParams: MeshParameters
public static let tessellationMeshParams: MeshParameters
```

- `highQualityMeshParams` — fine CPU mesh for smooth curved surfaces without GPU tessellation (deflection 0.03, ~11° angle, controlled surface deflection, parallel). The default used by `shapeToBodyAndMetadata`.
- `tessellationMeshParams` — moderate CPU mesh for GPU PN-triangle tessellation (deflection 0.1, ~20° angle). Selected by `gpuTessellation: true`.

---

## Static defaults

```swift
public static let defaultEdgeDeflection: Double = 0.005
public static let defaultMaxPointsPerEdge: Int = 1000
```

- `defaultEdgeDeflection` — default linear deflection for wireframe edge polyline extraction.
- `defaultMaxPointsPerEdge` — default per-edge point cap for wireframe polyline extraction.

> Note: `WireConverter` defines its own constants of the same names with a
> different cap (10000) — see [WireConverter](WireConverter).

---

## `CADLoadResult`

The value type returned by every `CADFileLoader` load. `@unchecked Sendable`.

```swift
public struct CADLoadResult: @unchecked Sendable {
    public var bodies: [ViewportBody]
    public var metadata: [String: CADBodyMetadata]
    public var shapes: [Shape]
    public var dimensions: [DimensionInfo]
    public var geomTolerances: [GeomToleranceInfo]
    public var datums: [DatumInfo]

    public init(
        bodies: [ViewportBody] = [],
        metadata: [String: CADBodyMetadata] = [:],
        shapes: [Shape] = [],
        dimensions: [DimensionInfo] = [],
        geomTolerances: [GeomToleranceInfo] = [],
        datums: [DatumInfo] = []
    )
}
```

- `bodies` — bridged, renderable bodies.
- `metadata` — per-body selection metadata, keyed by body id.
- `shapes` — the raw OCCTSwift shapes that were loaded.
- `dimensions` / `geomTolerances` / `datums` — PMI (product manufacturing information) surfaced by formats that carry it. The types come from OCCTSwiftIO.

---
