# OCCTSwiftTools — implementation spec

This document is a brief for the next agent (Claude or human) picking up implementation. Read it end-to-end before writing code.

## What this repo is

The bridge product between two intentionally-decoupled siblings:

- **[OCCTSwift](https://github.com/gsdali/OCCTSwift)**: Swift wrapper around OpenCASCADE's modeling kernel. No Metal, no rendering. Currently shipping `v0.168.0` against OCCT 8.0.0-beta1 with macOS / iOS slices (`ios-arm64`, `ios-arm64-simulator`, `macos-arm64`, and no others).
- **[OCCTSwiftViewport](https://github.com/gsdali/OCCTSwiftViewport)**: Pure-Metal viewport renderer. No OCCT dependency. Renders abstract `ViewportBody` objects.

`OCCTSwiftTools` is the only library that depends on **both**. It converts `OCCTSwift.Shape` (B-Rep topology + meshable surfaces) into `OCCTSwiftViewport.ViewportBody` (vertex / index / face-id buffers consumable by the Metal renderer), plus CAD file I/O wrappers that need both kernels working together.

It is being **promoted out of OCCTSwiftViewport's sub-product slot** into its own repo so:
1. OCCTSwiftViewport stays cleanly OCCT-free (it can build / test / version on its own).
2. `OCCTSwiftAIS` (sibling repo, sits one layer above this) can depend on a stable OCCTSwiftTools without dragging in viewport renderer changes.
3. CAD file I/O helpers (STEP/STL/IGES → renderable bodies in one call) get a clearer home.

## Architecture position

```
Application
   ↑
OCCTSwiftAIS         ← selection-from-topology, manipulators, dimensions
   ↑
OCCTSwiftTools       ← THIS REPO (bridge)
   ↑      ↑
OCCTSwift  OCCTSwiftViewport
(B-Rep)    (Metal)
```

OCCTSwiftTools depends on **both** OCCTSwift and OCCTSwiftViewport; OCCTSwiftAIS depends on OCCTSwiftTools (not the two siblings directly).

## Migration source

The current home of these types is `OCCTSwiftViewport/Sources/OCCTSwiftTools/` inside the viewport repo. **Read those files first** — they're the working starting point. Move them, don't rewrite.

```bash
# Inspect the current sub-product
ls ~/Projects/OCCTSwiftViewport/Sources/OCCTSwiftTools/
cat ~/Projects/OCCTSwiftViewport/Package.swift   # see how it was set up as a library product
```

The migration plan, in order:

1. Inventory every public type and method currently in `OCCTSwiftViewport/Sources/OCCTSwiftTools/`.
2. Move them to `OCCTSwiftTools/Sources/OCCTSwiftTools/` in this repo.
3. Move corresponding tests to `Tests/OCCTSwiftToolsTests/`.
4. Drop the `OCCTSwiftTools` library product + target from `OCCTSwiftViewport/Package.swift`. Cut a `v0.51.0` release of OCCTSwiftViewport that documents the move.
5. Tag this repo at `v0.1.0` once the move builds and tests pass.

The OCCTSwiftViewport repo continues to ship the `OCCTSwiftViewport` library; the `OCCTSwiftTools` library disappears from there in the same release that this repo's `v0.1.0` ships.

## Public API (v0.6.0)

As of v0.6.0 ([#12](https://github.com/gsdali/OCCTSwiftTools/issues/12)), file-I/O concerns live in [OCCTSwiftIO](https://github.com/gsdali/OCCTSwiftIO) — a sibling package depending on OCCTSwift only. This repo (`OCCTSwiftTools`) is now bridge-only: Shape ↔ ViewportBody. `@_exported import OCCTSwiftIO` keeps existing `import OCCTSwiftTools` call sites source-compatible (the IO types still resolve via Tools' surface).

```swift
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools   // re-exports OCCTSwiftIO transitively (@_exported)

// === Headline: file → renderable bodies ===

// CADFileFormat, ShapeLoader, ExportManager, ScriptManifest, CADBodyMetadata,
// ImportProgressClosure all live in OCCTSwiftIO now. They're re-exported here
// so existing `OCCTSwiftTools.X` references keep working.

public struct CADLoadResult: @unchecked Sendable {                               // STAYS in Tools (has bodies)
    public var bodies: [ViewportBody]
    public var metadata: [String: CADBodyMetadata]   // CADBodyMetadata is now an IO type
    public var shapes: [Shape]                       // do NOT pair positionally with bodies
    public var dimensions: [DimensionInfo]
    public var geomTolerances: [GeomToleranceInfo]
    public var datums: [DatumInfo]
    public var identity: [String: ShapeIdentity]     // keyed by body id, opt-in (#7)
}

/// The one builder for the three ordinal-to-identity tables (OCCTSwiftInteraction#7).
public struct ShapeIdentity: Sendable {
    public let shape: Shape
    public let graph: BRepGraph?
    public let faces: FaceIdentityTable
    public let edges: EdgeIdentityTable
    public let vertices: VertexIdentityTable

    public init(shape: Shape, graph: BRepGraph?)   // caller's graph, nil supported
    public init(shape: Shape)                      // mints its own
}

public enum CADFileLoader {
    /// Façade over `OCCTSwiftIO.ShapeLoader.load(...)` — loads via IO, then
    /// bridges each shape to a `ViewportBody` + `CADBodyMetadata`.
    public static func load(
        from url: URL, format: CADFileFormat,
        progress: ImportProgress? = nil,
        includeIdentity: Bool = false
    ) async throws -> CADLoadResult
    public static func loadFromManifest(
        at url: URL, includeIdentity: Bool = false
    ) throws -> CADLoadResult
    public static func shapeToBodyAndMetadata(
        _ shape: Shape, id: String, color: SIMD4<Float>,
        stl: Bool = false, deflection: Double? = nil, gpuTessellation: Bool = false,
        includeMeasurements: Bool = false
    ) -> (ViewportBody?, CADBodyMetadata?)
    public static let highQualityMeshParams: MeshParameters
    public static let tessellationMeshParams: MeshParameters
}

// For headless / shape-only use, call `OCCTSwiftIO.ShapeLoader.load` directly
// and avoid the Viewport dep entirely. See OCCTSwiftIO's README + CHANGELOG.

// === Bridge converters (Shape sub-types → ViewportBody) ===

public enum CurveConverter {
    public static func curve2DToBody(_ curve: Curve2D, id: String, color: SIMD4<Float>) -> ViewportBody
    public static func curve3DToBody(_ curve: Curve3D, id: String, color: SIMD4<Float>) -> ViewportBody
}

public enum SurfaceConverter {
    public static func surfaceToGridBodies(
        _ surface: Surface, idPrefix: String,
        offset: SIMD3<Double> = .zero,
        uColor: SIMD4<Float>, vColor: SIMD4<Float>,
        uLines: Int = 10, vLines: Int = 10
    ) -> [ViewportBody]
}

public enum WireConverter {
    public static func wireToBody(_ wire: Wire, id: String, color: SIMD4<Float>) -> ViewportBody
}

// === Pure-viewport utilities (no OCCT dep) ===

public enum BodyUtilities {
    public static func makeMarkerSphere(at: SIMD3<Float>, radius: Float, id: String,
                                        color: SIMD4<Float>, segments: Int = 8, rings: Int = 4) -> ViewportBody
    public static func offsetBody(_ body: ViewportBody, dx: Float, dy: Float = 0, dz: Float = 0) -> ViewportBody
    public static func offsetBody(_ body: inout ViewportBody, dx: Float, dy: Float = 0, dz: Float = 0)
}

// === Export, manifest, format enums, progress closure → all in OCCTSwiftIO ===

// ExportManager / ExportFormat / ScriptManifest / CADFileFormat /
// ImportProgressClosure / CADBodyMetadata moved to OCCTSwiftIO in v0.6.0.
// Tools re-exports them via @_exported import for source compatibility.
```

### Load-bearing contracts: pick-index arrays

Three pairs of arrays on `ViewportBody` map GPU pick results back to B-Rep topology for OCCTSwiftAIS' selection layer. Preserve their semantics bit-for-bit:

- **`faceIndices: [Int32]`** — per-triangle source-face index, parallel to the triangle list (`indices.count / 3 == faceIndices.count`). Mirrored by `CADBodyMetadata.faceIndices`. Picked triangle → `TopoDS_Face`.
- **`edgeIndices: [Int32]`** *(populated since v0.4.1)* — per-segment source-edge index, parallel to the flattened line-segment list. A polyline of N points contributes (N − 1) segments; each segment carries its source edge's index. Picked segment → `TopoDS_Edge`. Source data is `CADBodyMetadata.edgePolylines` (polyline-keyed); `flattenEdgeIndices(_:)` produces the segment-keyed array.
- **`vertices: [SIMD3<Float>]`** + **`vertexIndices: [Int32]`** *(source-shape convention since v0.5.0)* — point sprites for the vertex-pick pass. We populate `vertices` directly from `shape.vertices()` (Float-converted) and `vertexIndices` as the explicit identity array `[0, 1, …, n-1]`. This lets a consumer round-trip a picked `primitiveIndex` back to a `TopoDS_Vertex` via `shape.vertex(at: primitiveIndex)`. `CADBodyMetadata.vertices` carries the same data.
  - **v0.4.1 used a different (incompatible) convention** — deduplicated polyline endpoints. That broke AIS' `Selection.vertices` round-trip, see [#10](https://github.com/gsdali/OCCTSwiftTools/issues/10). v0.5.0 converged on the source-shape convention; AIS can drop its v0.6.1 workaround whenever convenient.

Semantic drift on any of these breaks pick-to-topology mapping one layer up. Wiring lives in `CADFileLoader.shapeToBodyAndMetadata`.

## Repo conventions

Match OCCTSwift's conventions exactly. Cribbed verbatim from that repo's CLAUDE.md and memory:

- **License**: LGPL 2.1 (same as OCCT itself, with the OCCT_LGPL_EXCEPTION). Copy from OCCTSwift.
- **swift-tools-version**: 6.1. Language mode: `.v6`.
- **Platforms**: `.iOS(.v18)`, `.macOS(.v15)`, and nothing else. (The higher of OCCTSwift's and OCCTSwiftViewport's floors, and the only two platforms `OCCT.xcframework` ships a slice for. This line used to add `.visionOS(.v1)` / `.tvOS(.v15)`, which was never true: [OCCTSwift#978](https://github.com/SecondMouseAU/OCCTSwift/issues/978).)
- **Tests**: Swift Testing (`@Suite` / `@Test` / `#expect`). Never `#expect(x != nil); #expect(x!.isValid)` — Swift Testing does not short-circuit. Always `if let x { #expect(x.isValid) }`.
- **Test naming**: `@Test func` names must NOT shadow API method names used inside the test body (test runner gets confused). Prefix with `t_` or use descriptive English.
- **OCCT race**: when running tests, set `OCCT_SERIAL=1 swift test --parallel --num-workers 1`. There's a known NCollection container-overflow race in OCCT on arm64 macOS that segfaults parallel runs.
- **Versioning**: tiny additive features = patch bump (x.y.z+1), not minor. Minor bumps for new public API surface.
- **Release pattern**: every shipped version commits + pushes + tags + creates a GitHub release with notes. Release notes go in `docs/CHANGELOG.md` (most recent first, "Current" header pinned to the new version).
- **Pre-1.0**: free to break. Document deprecations in CHANGELOG.
- **README**: shields.io SPI badges (Swift versions / platforms / license), install snippet pinning to the most recent semver, "Supported Platforms" table, link to ecosystem repos.
- **CODE_OF_CONDUCT.md**: short pointer to Contributor Covenant 2.1, **never** inline the full text — Anthropic's content filter blocks it.
- **`.spi.yml`**: SPI build matrix for Swift 6.0 / 6.1 / 6.2 / 6.3 + iOS, with `documentation_targets: [OCCTSwiftTools]`. Submission to swiftpackageindex.com is gated on v1.0.0.

## Distribution

This repo does **not** ship a binary. It depends on OCCTSwift (which ships `OCCT.xcframework` as a release asset) and OCCTSwiftViewport (pure Swift). SPM resolves both transitively.

```swift
// Package.swift dependencies
.package(url: "https://github.com/gsdali/OCCTSwift.git",         from: "0.168.0"),
.package(url: "https://github.com/gsdali/OCCTSwiftViewport.git", from: "0.55.0"),
```

Pin to specific versions in `Package.resolved`; bump deliberately.

## Tests

OCCTSwift ships no fixture files (its test geometry is generated at runtime), and STEP/BREP/STL samples in this repo would bloat the package. So tests **generate geometry at runtime** via `Shape.box`, `Shape.cylinder`, etc. Temp files for export round-trips go to `/tmp` — never under `Tests/`.

At minimum:

- `CADFileLoaderTests` — `Shape.box → shapeToBodyAndMetadata → ViewportBody` round-trip; verify `vertexData.count % 6 == 0`, `indices.count % 3 == 0`, `faceIndices.count == indices.count / 3`. Cylinder body's `metadata.faceIndices` covers all 3 source faces (top, bottom, lateral).
- `BodyUtilitiesTests` — `offsetBody` shifts every vertex by the given delta; `makeMarkerSphere` produces the expected vertex count for default segments/rings.
- `CurveConverterTests` — 2D curve maps to Y=0 plane; 3D curve preserves Z.
- `SurfaceConverterTests` — emits 1–2 bodies with `-u`/`-v` ID suffixes; edge counts match `uLines`/`vLines`.
- `ExportManagerTests` — round-trip box export to OBJ/STEP/BREP/glTF/GLB into `/tmp`; assert files exist and are non-empty.
- `ScriptManifestTests` — Codable round-trip including `colorArray` ↔ `color: SIMD4<Float>` mapping.
- `ShapeMeasurementsTests` — `includeMeasurements: true` populates `CADBodyMetadata.measurements` via `CADFileLoader.shapeToBodyAndMetadata`. The numeric correctness cases (box totals, centroid bounds, cap-on-axis) live in the OCCTSwift kernel suite as of v0.5.1's hoist.

## Sequencing

1. **v0.1.0** *(shipped)* — Wholesale migration out of OCCTSwiftViewport's sub-product slot. See [docs/CHANGELOG.md](docs/CHANGELOG.md).
2. **v0.2.0** *(shipped)* — `Shape.measure(linearTolerance:)` + `ShapeMeasurements` for AIS dimension widgets; IGES loader (`.iges` / `.igs` via `Shape.loadIGES` with `loadIGESRobust` fallback); glTF/GLB export (`.gltf` JSON+`.bin`, `.glb` single-binary container).
3. **v0.3.0** *(shipped)* — `ShapeMeasurements.faceCentroids` (via `Face.surfaceInertia` / `BRepGProp_Sinert`) + `facePerimeters` (via `Face.outerWire?.length`). Progress callbacks for STEP/IGES import deferred to v0.4.0 — gated on upstream OCCTSwift adding wrappers for `Message_ProgressIndicator` (none exist at v0.167.0).
4. **v0.4.0** *(shipped)* — STEP/IGES import progress + cancellation, plumbed from upstream `OCCTSwift.ImportProgress` (added in OCCTSwift v0.168.0, closed [OCCTSwift#98](https://github.com/gsdali/OCCTSwift/issues/98)). `CADFileLoader.load(from:format:progress:)` and an `ImportProgressClosure` ergonomic adapter. STL/OBJ/BREP unchanged — those upstream loaders don't surface progress.
5. **v0.4.1** *(shipped)* — populate `ViewportBody.edgeIndices` / `vertices` for AIS edge + vertex GPU picking (closes [#8](https://github.com/gsdali/OCCTSwiftTools/issues/8)). Pure data-wiring change in `shapeToBodyAndMetadata` — no API surface change. Floor bumped to OCCTSwiftViewport ≥ 0.55.0 for the new init parameters.
6. **v0.5.0** *(shipped)* — converge `body.vertices` / `body.vertexIndices` / `metadata.vertices` on the source-shape convention so AIS can round-trip a picked `primitiveIndex` back to `TopoDS_Vertex` via `shape.vertex(at:)` (closes [#10](https://github.com/gsdali/OCCTSwiftTools/issues/10)). Pre-1.0 behavior change — no signature change.
7. **v0.5.1** *(shipped)* — remove duplicate `ShapeMeasurements` after the OCCTSwift v0.170.1 kernel hoist (closes [#13](https://github.com/gsdali/OCCTSwiftTools/issues/13)). No public API change — the type still resolves at every call site, now via `import OCCTSwift`. Floor bumped to OCCTSwift ≥ 0.170.1.
8. **v0.6.0** *(shipped)* — split file-I/O concerns into [OCCTSwiftIO](https://github.com/gsdali/OCCTSwiftIO) (closes [#12](https://github.com/gsdali/OCCTSwiftTools/issues/12)). `CADFileFormat`, `ShapeLoader`-style file loading, `ExportManager`, `ScriptManifest`, `ImportProgressClosure`, `CADBodyMetadata` all live in OCCTSwiftIO now (depends on OCCTSwift only — no Viewport). `OCCTSwiftTools` retains the Shape ↔ ViewportBody bridge: `CADFileLoader.shapeToBodyAndMetadata`, `.load(from:format:progress:)` (façade over IO), `loadFromManifest`, `CADLoadResult`. `@_exported import OCCTSwiftIO` keeps existing `import OCCTSwiftTools` call sites source-compatible.

After v0.6 both packages are in their stable shape; tag v1.0.0 against OCCT 8.0.0 GA when upstream lands.

## Ecosystem context to read before coding

- `~/Projects/OCCTSwift/CLAUDE.md` — project conventions for the kernel
- `~/Projects/OCCTSwift/docs/visualization-research.md` — why this layer cake exists
- `~/Projects/OCCTSwift/docs/platform-expansion.md` — platform reasoning
- `~/.claude/projects/-Users-elb-Projects-OCCTSwift/memory/MEMORY.md` — saved conventions / feedback (LGPL, /tmp staging, Swift Testing patterns, content-filter CoC, SPM packaging)

## What is explicitly out of scope

- Selection / picking semantics (that's OCCTSwiftAIS).
- Manipulator widgets (OCCTSwiftAIS).
- Dimension annotations (OCCTSwiftAIS).
- A full headless ray-tracing renderer (use CADRays separately).
- Linux / Windows / Android — see `OCCTSwift/docs/platform-expansion.md`.
- Apple Watch (memory-constrained).
