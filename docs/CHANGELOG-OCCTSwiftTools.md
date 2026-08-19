# Changelog

Most recent first. Pre-1.0 was free to break; SemVer-stable from v1.0.0 per the [cohort SemVer policy](https://github.com/gsdali/OCCTSwift/blob/main/docs/SEMVER.md).

## Unreleased

### Platforms narrowed to iOS and macOS

A 1.0.0 blocker. `Package.swift` declared `.visionOS(.v1)` and `.tvOS(.v18)`, and both were false. `OCCT.xcframework`'s `Info.plist` carries exactly three slices, `ios-arm64`, `ios-arm64-simulator` and `macos-arm64`, supporting two platforms, and OCCTSwift's own v3.0.0 release notes open with "macOS / iOS (device + simulator)". Anything linking the kernel on visionOS or tvOS cannot link at all, so the manifest promised a build that never existed.

The merge took the union of what OCCTSwiftTools, OCCTSwiftAIS and OCCTSwiftCADKit declared, so as not to regress the two targets with the most dependents. That reasoning was wrong in a way invisible from the manifests: the wider claim was never true for any of the three, so there was nothing to regress. Root cause is filed upstream as [OCCTSwift#978](https://github.com/SecondMouseAU/OCCTSwift/issues/978).

`platforms` is now `.iOS(.v18)`, `.macOS(.v15)`. A consumer that declares a visionOS or tvOS target and depends on this package is now told so at resolution time rather than discovering it at link time.

### A failed sub-shape conversion no longer shifts every later ordinal

Closes [OCCTSwiftInteraction#9](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/9). A 1.0.0 blocker.

`ShapeIdentity` built its face and edge tables with `compactMap`, so a failed `Shape.fromFace` / `Shape.fromEdge` was dropped rather than held in place. The ordinals in `ViewportBody.faceIndices` index the **full** `faces()` enumeration, because that is what the mesher walks, so one failure at ordinal `k` moved every later face down one: `shapes[ordinal]` returned the face *after* the one the pick hit, and `uid(forOrdinal:)` minted a durable identity for it. No error, no assertion, no diagnostic. The pick resolved and highlighted confidently on a neighbour.

**Breaking, and the reason for it.** `FaceIdentityTable.shapes` and `EdgeIdentityTable.shapes` are now `[Shape?]` rather than `[Shape]`, built with `map`, so a failed conversion is a `nil` at its own ordinal and the index space is the ordinal space by construction. Reading an element now needs unwrapping; `shapes.count`, `shapes.indices`, `shape(forOrdinal:)` and `uid(forOrdinal:)` are unchanged in both spelling and meaning, and the initialisers still accept a `[Shape]` unchanged (Swift promotes it). Nothing outside this package referenced either type at the time of the change.

**`VertexIdentityTable.shapes` stays `[Shape]`**, deliberately. `subShapes(ofType: .vertex)` returns `Shape` values directly, with no failable conversion in front of it, so its alignment holds for free. The asymmetry records that the hazard is the conversion rather than the enumeration.

The failure now degrades instead of corrupting: the one ordinal that failed loses its captured shape and its durable uid, and no other ordinal moves. A pick landing on it still names the sub-shape it hit, because `SubShapePickResolver` reads a `nil` entry as a table miss and re-derives through `subShape(type:index:)`, which walks the same `TopTools_IndexedMapOfShape`. Refusing the whole table, and asserting on a count mismatch, were both considered and are recorded in [`docs/reference/ShapeIdentity.md`](reference/ShapeIdentity.md#ordinal-alignment-is-the-invariant).

**Tests:** 3 new in the `ShapeIdentity` suite, 360 total. A genuine conversion failure cannot be provoked through the public API (every `Face` and `Edge` the enumerations hand back already holds a live handle), so they drive it through a new internal seam on `ShapeIdentity.init`, which takes the two conversions as parameters. Same treatment, and same reason, as `edgePolylineOnlyBridge`. Mutation-checked: reinstating `compactMap` fails all three and no others, which also confirms the issue's claim that the shared-face regression test does not catch this, since its fixture converts cleanly.

### One canonical identity-table builder, and a file load can finally return identity

Closes [OCCTSwiftInteraction#7](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/7).

Phase 2 (below) made `SubShapePickResolver` the one place a render-path ordinal becomes a `SubShapeRef`. It did not consolidate the step before that, building the tables the resolver reads, and three copies of it had accumulated: this package's private helpers, `OCCTSwiftCADKit`'s statics (whose own comment said it mirrored them), and `OCCTSwiftUX`'s `ShapeIdentity`.

New API, both additions:

- **`ShapeIdentity`**: the `Shape`, its `BRepGraph` and all three identity tables, built once. `init(shape:graph:)` uses a graph the caller holds, with `nil` still meaning "tables without durable uids"; `init(shape:)` mints one, which is the convenience CADKit and UX each hand-rolled. The uid loop is written once, generic over `[Shape]`, rather than three times.
- **`CADLoadResult.identity: [String: ShapeIdentity]`**, keyed by `ViewportBody.id`, plus **`includeIdentity: Bool = false`** on `load(from:format:progress:)` and `loadFromManifest(at:)`. New stored property with a default and new defaulted parameters, so no source break.

**The reason both landed rather than just the builder.** They fix different halves. A public builder removes the duplicated *construction* but leaves every consumer pairing `shapes[i]` with `bodies[i]` after a file load, which is not safe: the STL/IGES robust reload appends a shape even when that input produced no body, so every later pairing shifts and a body gets another body's geometry. `CADLoadResult.identity` removes the duplicated *pairing*, since the loader keys it by body id in the same branch that creates each body. Neither alone makes the downstream copies deletable, because `CADViewportService.load(_:id:transform:)` and `loadShape(_:id:)` take an in-memory `Shape` and never produce a `CADLoadResult` at all.

**Why identity is off by default.** `BRepGraph.init` serialises the whole shape to a BREP string. Measured against a 14-face, 36-edge solid: meshing 9.6ms, `BRepGraph(shape:)` 5.0ms, of which 3.8ms is that serialisation. Headless consumers of `load` (reprojection, batch render, parts extraction) never pick and should not pay for it.

**One behaviour change, on a path no test could reach.** The bridge's edge-polyline-only branch (taken when `mesh(...)` returns nil) used to substitute an empty `FaceIdentityTable`; it now builds the ordinary one. That was the only place any copy of this logic varied a table's *content*, and it was asymmetric with the edge and vertex tables built in full on the same branch. It is inert through picking either way, because `SubShapePickResolver.resolveFace` bounds-checks against `faceIndices`, which is empty there. The branch is now reachable from tests through the internal `edgePolylineOnlyBridge` seam, the same treatment `bodyEntries` already had, because it cannot be provoked from a synthetic shape: a wire, an edge and a lone vertex all mesh to an empty `Mesh` rather than to nil.

**A small performance fix on the way through.** `shapeToBodyAndMetadata` used to build all three identity tables and discard them. It now skips construction entirely, which is three fewer shape-map walks per body, on the path every `load` body takes.

**Tests:** 14 new across two new suites (`ShapeIdentity`, `CADFileLoader identity`), 357 total. The failure cases the three copies disagreed about (nil graph, no faces, the edge-polyline-only branch, and the shape-to-body pairing) had no shared coverage at all before. The pairing test asserts by geometry rather than by index, and was mutation-checked: deliberately shifting the pairing inside the loader fails it.

**One thing in the issue that did not survive contact with the code.** The issue describes `CADViewportService`'s count-mismatch guard as the thing to preserve. Two of its three implementations were redundant: `loadFile(from:id:)` pre-detected the mismatch at the call site *and* `addIdentity` re-detected it, and `rebuildIdentity`'s wholesale wipe ran against dictionaries `resetAllModelState()` had emptied a line earlier. All of it is gone, because the hazard it detected cannot arise once the loader keys identity by body id.

### One canonical pick resolver, and the types that name picked topology move down here

Closes [OCCTSwiftInteraction#2](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/2), phase 2 of [ecosystem#43](https://github.com/SecondMouseAU/ecosystem/issues/43).

New API:

- **`SubShapePickResolver`**: `resolveFace(triangleIndex:faceIndices:identity:shape:)`, `resolveEdge(segmentIndex:edgeIndices:identity:shape:)`, `resolveVertex(pointIndex:pointCount:vertexIndices:identity:shape:)`. A GPU pick's primitive index in, a `SubShapeRef` out. Owns the `faceIndices` / `edgeIndices` / `vertexIndices` indirection, the bounds checks, the empty-`vertexIndices` identity mapping, and the rule that the identity table beats re-deriving from the shape's own sub-shape enumeration.
- **`SubShapeRef`**, **`SubShape`** and **`InteractiveObject`**, moved down from the `OCCTSwiftAIS` target. The type naming a piece of topology belongs in the lowest layer that can produce it, which is the layer holding the identity tables and minting the `BRepGraph.GraphUID`. `OCCTSwiftAIS` keeps source-compatible typealiases, so no consumer changes.

**A real bug fixed on the way in.** `ViewportBody` documents an empty `vertexIndices` as identity mapping, where the point index *is* the vertex ordinal. `OCCTSwiftCADKit`'s copy of the resolver implemented that; `OCCTSwiftAIS`'s bounds-checked the pick against `vertexIndices.count` and therefore never resolved a vertex pick on such a body. The shared resolver takes CADKit's handling, so a vertex pick is bounded by how many points the body renders and never by `vertexIndices.count`.

**Deliberately not absorbed**, per the behaviour matrix on ecosystem#43: clip-plane awareness (the caller's, since clip planes are the viewport service's state and this target has no business knowing about them), geometry enrichment (presentation, and it belongs above), and the whole-body fallback (a selection-mode decision, so it stays in `OCCTSwiftAIS`). The shared resolver is the identity concern only.

**Tests:** 13 new in a new `SubShapePickResolver` suite, covering both indirection paths, the bounds checks, the empty-array cases in both directions, the table-over-re-derivation rule, and every vertex case the AIS copy used to get wrong.

## v1.6.3 (2026-08-10)

**Repin OCCTSwift floor to 2.0.0.** OCCTSwift's v2.0.0 ([`docs/SEMVER.md#v200`](https://github.com/SecondMouseAU/OCCTSwift/blob/main/docs/SEMVER.md#v200)) is a correctness major (Pass 1a/1b duplication+bug-fix audit, [#377](https://github.com/SecondMouseAU/OCCTSwift/issues/377)/[#669](https://github.com/SecondMouseAU/OCCTSwift/issues/669); OCCT absorbed to 8.0.1), 17 breaking API changes. A full audit of this repo's own `FaceIdentityTable`/`EdgeIdentityTable`/`VertexIdentityTable` and `shapeToBodyMetadataAndIdentities(...)` surface against the whole break table found one real thing: `Mesh.Triangle.faceIndex`, read in `CADFileLoader.swift` to build `FaceIdentityTable`, moved onto the same deduplicated `Shape.faces()` enumeration OCCTSwift's #541/#613 already put `Shape.faces()` itself on ([#642](https://github.com/SecondMouseAU/OCCTSwift/issues/642) generalizes this — both were the raw, non-deduplicating enumeration before, exactly why `FaceIdentityTable` existed per issue #42). `makeFaceIdentityTable()` needed no logic fix (it already calls `shape.faces()` dynamically, not a hardcoded enumeration), but its own doc comments, `FaceIdentityTable.swift`'s type docs, and `docs/reference/FaceIdentityTable.md` described the old, now-incorrect behaviour in the present tense; updated all three. Fixed a hardcoded pre-dedup face count (`compound.faces().count == 7`) in `FaceIdentityTableTests` (and the same fixture reused in `EdgeIdentityTableTests`/`VertexIdentityTableTests`), rewritten to check the new contract directly rather than just patching the number.

Bumped to **PATCH** per the cohort SemVer policy: no production logic change, doc/test corrections plus the floor bump.

**Dep bump:** `OCCTSwift from: "1.17.0"` → `from: "2.0.0"`.

## v1.6.2 (2026-07-30)

**Repin OCCTSwift floor to 1.17.0.** Picks up Pass 1a of OCCTSwift's [#377/#380](https://github.com/SecondMouseAU/OCCTSwift/issues/377) duplication/bug-fix audit: nine duplicated continuity enums consolidated into two (source-compatible via deprecated-alias shims), several dedup cleanups, and edge-case bug fixes (arc-length failure sentinels, `Surface.normal` at singularities, `Curve2D.circle` at radius zero). One real API break — `Surface.drawMesh`/`evaluateGrid` now return a `SurfaceGrid` struct instead of `[[SIMD3<Double>]]` — is unused in this repo (grep-verified).

Bumped to **PATCH** per the cohort SemVer policy: floor bump only, no new API surface, no behaviour change here.

**Dep bump:** `OCCTSwift from: "1.15.0"` → `from: "1.17.0"`.

## v1.6.1 (2026-07-20)

**Renamed `TopologyGraph` to `BRepGraph` throughout, matching OCCTSwift v1.15.0.** Closes [#45](https://github.com/SecondMouseAU/OCCTSwiftTools/issues/45).

OCCTSwift renamed `TopologyGraph` to `BRepGraph` ([OCCTSwift#333](https://github.com/SecondMouseAU/OCCTSwift/issues/333)) to match the C++ package it wraps, keeping a deprecated typealias so existing code compiled unchanged. This repo used the old name in its own public API (`graph: TopologyGraph? = nil` on the identity-table entry points, `uids: [TopologyGraph.GraphUID?]?` on `FaceIdentityTable` / `EdgeIdentityTable` / `VertexIdentityTable`), which surfaced as a deprecation warning on every build. Mechanical rename across `Sources/`, `Tests/`, and the current-state docs; no behaviour change, and source-compatible for callers since `TopologyGraph` and `BRepGraph` are the identical type via OCCTSwift's typealias.

Bumped to **PATCH** per the cohort SemVer policy: pure rename, no new API surface, no behaviour change.

**Dep bump:** `OCCTSwift from: "1.12.9"` → `from: "1.15.0"`. Required for `BRepGraph`.

## v1.6.0 (2026-07-20)

**`EdgeIdentityTable` and `VertexIdentityTable` extend the tessellation-time identity capture from #42 to edges and vertices.** Closes [#43](https://github.com/SecondMouseAU/OCCTSwiftTools/issues/43).

OCCTSwiftAIS#31 needed durable `GraphUID`s for edge and vertex sub-shape selections, not just faces, and had to hand-roll the resolution (`shape.subShape(type: .edge/.vertex, index: ordinal)` then `graph.findNode(for:)` then `graph.uid(ofNodeKind:index:)`) at pick time instead of getting it from a captured table the way `FaceIdentityTable` already provides for faces.

Verified against the OCCTBridge source while implementing this: edges and vertices do not carry the same raw-vs-deduplicated ordinal split that motivated `FaceIdentityTable`. `Shape.faces()` (and the mesher's `faceIndex`) walk with a raw, non-deduplicating `TopExp_Explorer`, so a face shared between two shells is visited once per shell. `Shape.edge(at:)` / `Shape.vertex(at:)`, the bulk edge-polyline extractor behind `ViewportBody.edgeIndices`, and `Shape.subShapes(ofType: .edge/.vertex)` all build one `TopTools_IndexedMapOfShape` instead, which deduplicates up front, so `ViewportBody.edgeIndices` / `vertexIndices` are already in the same ordinal space `subShape(type:index:)` resolves against. The two new tables still earn their keep: they capture the ordinal to `Shape` to `GraphUID` correspondence once at tessellation time, so a consumer doesn't re-walk the shape's edge/vertex map on every pick or reimplement the graph resolution `FaceIdentityTable` already does, and edge/vertex identity keeps working even if that deduplication behaviour ever changed.

New API:

- `EdgeIdentityTable` / `VertexIdentityTable`: same shape as `FaceIdentityTable`. `shapes: [Shape]` indexed by the ordinal in `ViewportBody.edgeIndices` / `vertexIndices`, plus an optional `uids: [TopologyGraph.GraphUID?]?` when a graph is supplied. `shape(forOrdinal:)` / `uid(forOrdinal:)` accessors.
- `CADFileLoader.shapeToBodyMetadataAndIdentities(..., graph: TopologyGraph? = nil)`: overload of `shapeToBodyAndMetadata` returning `(ViewportBody?, CADBodyMetadata?, FaceIdentityTable?, EdgeIdentityTable?, VertexIdentityTable?)`. `shapeToBodyAndMetadata` and `shapeToBodyMetadataAndIdentity` are both unchanged; the three-table tuple is additive rather than an extension of either existing overload's return shape, so no caller destructuring those tuples breaks.

Bumped to **MINOR** per the cohort SemVer policy: new opt-in API, no behaviour change for existing callers. No dep bump.

## v1.5.0 — 2026-07-20

**`FaceIdentityTable` captures face-ordinal identity at tessellation time.** Closes [#42](https://github.com/gsdali/OCCTSwiftTools/issues/42).

`ViewportBody.faceIndices` (mirrored in `CADBodyMetadata.faceIndices`) stores one render-path face ordinal per triangle. Consumers have resolved that ordinal back to a `TopoDS_Face` via `shape.subShapes(ofType: .face)[ordinal]` — which assumes the render-path ordinal agrees with that deduplicated enumeration. It doesn't, reliably: the mesher assigns `faceIndex` by walking faces with a raw, non-deduplicating `TopExp_Explorer` (the same traversal `Shape.faces()` uses), while `subShapes(ofType:)` and a `TopologyGraph`'s node ordering both collapse a face shared between two shells into one entry. The two enumerations coincide on a clean single solid and silently diverge — shifting every later index — on multi-shell, mixed-orientation topology.

New API:

- `FaceIdentityTable` — `shapes: [Shape]` indexed by render-path ordinal (built from `Shape.faces()`, so it's exact by construction, not reconstructed from a mismatched enumeration), plus an optional `uids: [TopologyGraph.GraphUID?]?` when a graph is supplied. `shape(forOrdinal:)` / `uid(forOrdinal:)` accessors.
- `CADFileLoader.shapeToBodyMetadataAndIdentity(..., graph: TopologyGraph? = nil)` — overload of `shapeToBodyAndMetadata` returning `(ViewportBody?, CADBodyMetadata?, FaceIdentityTable?)`. Pass a `TopologyGraph` built from the same shape to populate `uids`, minted via `graph.findNode(for:)` on each ordinal's face so `IsSame` semantics hold. `shapeToBodyAndMetadata` itself is unchanged.

Bumped to **MINOR** per the cohort SemVer policy: new opt-in API, no behaviour change for existing callers. No dep bump — `TopologyGraph.GraphUID.graphID` provenance shipped in OCCTSwift v1.12.0, already inside the existing `1.12.9` floor.

## v1.4.4 — 2026-07-20

**Repin OCCTSwift floor to 1.12.9.** OCCTSwift v1.12.8 added kernel patch 0006 (a `BRepGProp_EdgeTool` null-curve-on-surface guard, [OCCTSwift#318](https://github.com/SecondMouseAU/OCCTSwift/issues/318)) and v1.12.9 added patches 0007 through 0009 (free-bounds `lwire` reset, boolean-path BSpline O(1) periodic normalization, STEP-writer oversized-string split; [OCCTSwift#323](https://github.com/SecondMouseAU/OCCTSwift/issues/323)), on top of the earlier patches. Ecosystem-wide floor bump; no API or behaviour change.

## v1.4.3 — 2026-07-19

**Repin OCCTSwift floor to 1.12.7.** OCCTSwift v1.12.7 carries OCCT kernel patch 0005: `ShapeFix_Face::FixPeriodicDegenerated` guards a null `Context()`, fixing the SIGSEGV in [OCCTSwift#317](https://github.com/SecondMouseAU/OCCTSwift/issues/317) (upstream [OCCT#1380](https://github.com/Open-Cascade-SAS/OCCT/pull/1380)), on top of the free-bounds (#310) and thread-safe-fillet (#298) patches. Ecosystem-wide floor bump; no API or behaviour change.

## v1.4.2 — 2026-07-19

**Repin OCCTSwift floor to 1.12.6.** OCCTSwift v1.12.6 carries OCCT kernel patch 0004 — `ShapeAnalysis_FreeBounds` no longer returns a null `owires` on empty input, fixing the uncatchable free-bounds SIGSEGV ([OCCTSwift#310](https://github.com/SecondMouseAU/OCCTSwift/issues/310), upstream [OCCT#1377](https://github.com/Open-Cascade-SAS/OCCT/pull/1377)) — on top of the thread-safe-fillet patch 0003 (#298). Ecosystem-wide floor bump; no API or behaviour change.

## v1.4.1 — 2026-07-18

**Repin OCCTSwift floor to 1.12.3.** OCCTSwift v1.12.3 carries OCCT kernel patch 0003, making 3D fillet/chamfer reentrant across threads ([OCCTSwift#298](https://github.com/SecondMouseAU/OCCTSwift/issues/298) / upstream [OCCT#1374](https://github.com/Open-Cascade-SAS/OCCT/pull/1374)) — concurrent fillet builds no longer corrupt each other into wrong-but-plausible solids. Ecosystem-wide floor bump; no API or behaviour change.

## v1.4.0 — 2026-07-18

**The robust STL/IGES reload splits a multibody file into one `ViewportBody` per body.** Closes [#36](https://github.com/SecondMouseAU/OCCTSwiftTools/issues/36).

OCCTSwift v1.11.3 ([OCCTSwift#302](https://github.com/SecondMouseAU/OCCTSwift/issues/302)) changed the robust importers to return a **compound of solids** for a multibody file, where before they silently dropped all but the first body. The robust-reload fallback in `CADFileLoader` (which calls `Shape.loadSTLRobust` / `loadIGESRobust` directly, bypassing `OCCTSwiftIO.ShapeLoader`) wrapped that whole compound in a single `shapesWithColors` entry, so it meshed as **one** `ViewportBody` — one selectable unit, one colour, one metadata blob for the entire multibody model.

**Change:** the reload now splits a compound into one entry per solid (`.solid` → one; no-solids result → the whole shape, never zero), so each body becomes its own `ViewportBody`. This mirrors the split `OCCTSwiftIO.ShapeLoader` gained in v1.7.0 for its own primary path — the reload needs its own copy because it calls the loader directly and is synchronous, where `ShapeLoader.loadRobust` is async.

**Scope note:** this covers the robust-reload path, which fires when the *primary* mesh bridge fails. A well-formed multibody STL loads through the primary path as loose faces and still meshes as one body — per-body identity for a mesh file only exists once sewing has recovered solids, which is the robust path. Splitting a valid raw mesh into components is connected-component analysis, a separate feature.

Pins bumped: OCCTSwift `1.11.3` (the reload has nothing to split without #302), OCCTSwiftIO `1.7.0` (so the primary path splits too).

## v1.3.1 — 2026-07-16

Wireframe edge extraction is now **O(edges), not O(edges²)** — the Tools half of [OCCTSwift#275](https://github.com/SecondMouseAU/OCCTSwift/issues/275).

`extractEdgePolylines` (inside every `shapeToBodyAndMetadata` call) looped `Shape.edgePolyline(at:)`, and each of those bridge calls rebuilt the shape's full edge map — measured 0.11s @ 800 edges, 1.29s @ 3.1k, 20.3s @ 12k, extrapolating to ~84 hours at the ~1.3M edges of a 442k-triangle STL import (one face per facet). This quadratic is what hung OCCTMCP's `render_preview` / `pick_surface_point` / `overlay_render` on mesh-scale scans ([OCCTMCP#75](https://github.com/SecondMouseAU/OCCTMCP/issues/75)).

Now a single bulk pass via `Shape.allEdgePolylinesIndexed` (OCCTSwift v1.10.0). The **indexed** variant, not the dense `allEdgePolylines`: `edgeIndex` feeds `ViewportBody.edgeIndices` pick identity, and the dense variant's positions drift off the `edge(at:)` index space at the first skipped (degenerate/failed) edge. Output — polylines, indices, ordering, skip behaviour — is unchanged.

No API change; PATCH per the cohort SemVer policy.

**Dep bump:** `OCCTSwift from: "1.7.1"` → `from: "1.10.0"`. Required for `allEdgePolylinesIndexed`.

## v1.3.0 — 2026-07-16

Adopts the OCCTSwiftViewport direct-mesh render path, closing [#31](https://github.com/SecondMouseAU/OCCTSwiftTools/issues/31).

`CADFileLoader.shapeToBodyAndMetadata` walked every vertex to interleave OCCT's separate position/normal arrays into `ViewportBody.vertexData`, then ran `NormalSmoothing` over the result — an extra full pass and CPU copy, re-deriving normals that OCCT's `Poly_Triangulation` already computes correctly.

New parameter (default preserves historical behaviour exactly):

- `shapeToBodyAndMetadata(..., directMesh: Bool = false)` — when true, forwards `mesh.vertexData` / `mesh.normalData` straight into `ViewportBody.directMesh(...)` (Viewport v1.1.23), skipping the interleave loop, `NormalSmoothing`, and the extra resident copy. A load-time / memory win for large or many-body scenes; rendered result is the same, since OCCT's per-vertex normals from a fine B-Rep mesh are already analytic-quality.

**Caveat:** a direct body carries the mesh vertices (bbox / fit / CPU raycast) but not the B-Rep corner vertex-pick data or per-segment edge-pick indices — face display, face GPU-pick, CPU raycast and edge *display* all work; B-Rep vertex-picking and edge-index picking on the body itself do not. `metadata` still carries the full pick vertices / face indices for app-side use.

Bumped to **MINOR** per the cohort SemVer policy: new opt-in functionality, no behaviour change for existing callers.

**Dep bump:** `OCCTSwiftViewport from: "1.1.20"` → `from: "1.1.23"`. Required for `ViewportBody.directMesh(...)`.

## v1.2.0 — 2026-06-21

Wireframe edge polyline extraction is now **tunable**, closing [#24](https://github.com/gsdali/OCCTSwiftTools/issues/24).

`CADFileLoader.shapeToBodyAndMetadata` previously extracted edge polylines at a hardcoded `0.005` linear deflection (independent of the triangle-mesh `deflection`), so a B-rep edge following a long fine curve — e.g. a helical thread — became thousands of points: a slow-to-render, illegibly dense wireframe with no knob to coarsen it.

New parameters (defaults preserve historical behaviour exactly):

- `shapeToBodyAndMetadata(..., edgeDeflection: Double = 0.005, maxPointsPerEdge: Int = 1000, ...)` — coarsen edge sampling for dense curved geometry, and/or hard-cap points per edge.
- `WireConverter.wireToBody(..., maxPointsPerEdge: Int = 10000, edgeDeflection: Double = 0.005)` — same knobs on the wire path (ordered-edge cap + Shape-fallback deflection).
- Public defaults exposed as `CADFileLoader.defaultEdgeDeflection` / `.defaultMaxPointsPerEdge` and `WireConverter.defaultEdgeDeflection` / `.defaultMaxPointsPerEdge`.

Consumers (e.g. OCCTSwiftPartsAgent) can now coarsen edges at the source and drop the post-hoc `ViewportBody.edges` decimation hack — which also restores edge-picking (the workaround had to clear `edgeIndices`).

Bumped to **MINOR** per the cohort SemVer policy: new opt-in functionality, no behaviour change for existing callers.

## v1.1.2 — 2026-06-19

Pure dep re-pin: OCCT 8.0.0p1 cohort (`OCCTSwift` ≥ 1.7.1). No public API changes.

## v1.1.1 — 2026-05-26

Pure dep bump: raise `OCCTSwiftViewport` floor 1.0.2 → 1.0.4 ([#22](https://github.com/gsdali/OCCTSwiftTools/issues/22)). No public API changes.

## v1.1.0 — 2026-05-09

`PointConverter.pointsToBody` now wires its `pointRadius` and `perPointColors` parameters through to the new `ViewportBody.pointRadius` / `vertexColors` fields, and stamps `primitiveKind = .point` so OCCTSwiftViewport's point-cloud rendering pipeline (added in [Viewport v1.0.2](https://github.com/gsdali/OCCTSwiftViewport/releases/tag/v1.0.2), issue [#28](https://github.com/gsdali/OCCTSwiftViewport/issues/28)) draws the body as visible point sprites.

The Swift signature of `pointsToBody` is unchanged — the params used to be accepted-but-discarded for forward-compat. Consumers passing them now get the behaviour they always intended; consumers ignoring them keep the soft-amber fallback color and the 0.05-world-unit default radius.

Bumped to **MINOR** per the cohort SemVer policy: the params went from no-op to functional, which is "new functionality consumers can opt into."

**Dep bump:** `OCCTSwiftViewport from: "1.0.1"` → `from: "1.0.2"`. Required for the new ViewportBody fields.

Closes the renderer-side gap noted in [#18](https://github.com/gsdali/OCCTSwiftTools/issues/18). Downstream consumers (OCCTMCP's `add_scene_primitive(pointCloud)`) can now drop the 256-point sphere-compound workaround.

## v1.0.2 — 2026-05-09

Pure dep bump:

- `OCCTSwiftViewport` 0.55.0 → 1.0.1 (graduates onto the SemVer-stable Viewport line).
- `OCCTSwift` 1.0.1 → 1.0.3 (picks up the v1.0.2 / v1.0.3 history APIs from [OCCTSwift#165](https://github.com/gsdali/OCCTSwift/issues/165)).

No public API changes in this package. `swift build` clean, `swift test` green (20 tests, 6 suites).

## v1.0.1 — 2026-05-09

`PointConverter.pointsToBody(_:id:color:pointRadius:perPointColors:)` — sibling to `CurveConverter` / `SurfaceConverter` / `WireConverter`. Produces a `ViewportBody` whose `vertices` carry the cloud points and whose `vertexData` / `indices` / `edges` are empty; the renderer is expected to interpret the body as a point list.

OCCTMCP's `add_scene_primitive(pointCloud)` is the immediate consumer. Today (OCCTMCP v0.9) it caps at ~256 points and synthesises a sphere compound (~50k tris); switching to `PointConverter` lifts the cap because the body avoids triangulation entirely.

`pointRadius` and `perPointColors` are accepted as parameters for forward compatibility but the current `ViewportBody` has no fields to carry them. Renderer-side support for drawing those vertices as on-screen point primitives is tracked separately on the OCCTSwiftViewport side; until that lands, the body shape is correct but the points won't be visible.

Validation: `perPointColors.count` must equal `points.count` when non-nil — returns `nil` on mismatch. Empty input is valid (returns an empty body for clearing prior point sets).

Closes [#18](https://github.com/gsdali/OCCTSwiftTools/issues/18). Pure additive — no API surface removed or changed.

## v1.0.0 — 2026-05-08

OCCTSwift v1.0.0 / OCCT 8.0.0 GA cohort. Pure dep bumps to graduate alongside the cohort:

- `OCCTSwift` 0.170.1 → 1.0.1
- `OCCTSwiftIO` 0.1.0 → 1.0.0
- `OCCTSwiftViewport` stays at 0.55.0 (no v1.0 yet)

No public API changes. SemVer-stable from this tag.

Closes [#16](https://github.com/gsdali/OCCTSwiftTools/issues/16).

## v0.6.0 — 2026-05-06

Closes [#12](https://github.com/gsdali/OCCTSwiftTools/issues/12). Splits file-I/O concerns into [OCCTSwiftIO](https://github.com/gsdali/OCCTSwiftIO) — a sibling package that depends on `OCCTSwift` only (no `OCCTSwiftViewport`). Headless consumers (Scripts, PadCAM CLI, batch pipelines, server-side workflows) can now load STEP / IGES / STL / OBJ / BREP files without dragging in the Metal renderer transitively.

**Source compatibility preserved.** `OCCTSwiftTools` adds `@_exported import OCCTSwiftIO` so every type that moved still resolves through `OCCTSwiftTools`'s surface — existing call sites (`OCCTSwiftTools.CADFileFormat`, `OCCTSwiftTools.ExportManager`, etc.) keep working unchanged.

**What moved to [OCCTSwiftIO v0.1.0](https://github.com/gsdali/OCCTSwiftIO/releases/tag/v0.1.0):**

- `enum CADFileFormat` — file-format enum.
- `enum ExportManager` + `enum ExportFormat` — OBJ / PLY / STEP / BREP / glTF / GLB writers.
- `struct ScriptManifest` — Codable harness manifest.
- `final class ImportProgressClosure` — closure-backed `OCCTSwift.ImportProgress` adapter.
- `struct CADBodyMetadata` — pure-data picking metadata. Stays Viewport-free; bridge consumes it.
- New: `enum ShapeLoader` — headless loader API. Returns `ShapeLoadResult { shapesWithColors, dimensions, geomTolerances, datums, manifest }`. No `ViewportBody`.

**What stays in `OCCTSwiftTools`:**

- `CADFileLoader.shapeToBodyAndMetadata(...)` — the bridge. Unchanged signature.
- `CADFileLoader.load(...)` — now a façade over `OCCTSwiftIO.ShapeLoader.load(...)` plus per-shape bridge. Returns `CADLoadResult` with `bodies: [ViewportBody]` as before.
- `CADFileLoader.loadFromManifest(...)` — same façade pattern.
- `CADLoadResult` (has `bodies: [ViewportBody]` — couldn't move).
- Mesh parameter presets (`highQualityMeshParams`, `tessellationMeshParams`).
- All Shape sub-type bridges: `CurveConverter`, `SurfaceConverter`, `WireConverter`, `BodyUtilities`.
- STL/IGES robust-loader fallback path: if the primary load + bridge fails (mesh nil), Tools re-loads via `Shape.loadSTLRobust` / `Shape.loadIGESRobust` and re-bridges. The fallback is bridge-aware so it lives here, not in IO.

**Consumer migration (optional):**

- Bridge users (AIS, CADKit, custom Metal viewers) — no change. `import OCCTSwiftTools` continues to work, and the `@_exported` re-export means even direct `OCCTSwiftTools.ExportManager` etc. references still resolve.
- Headless users (Scripts, PadCAM CLI, batch tools) — switch `import OCCTSwiftTools` to `import OCCTSwiftIO` and call `ShapeLoader.load(...)` directly to drop the transitive Viewport dep. `CADLoadResult` has no equivalent in IO; `ShapeLoadResult` is the headless analogue (`shapesWithColors`, no bodies).

**Dependencies bumped:**
- New: `OCCTSwiftIO` ≥ `0.1.0`.
- `OCCTSwift` ≥ `0.170.1` — unchanged.
- `OCCTSwiftViewport` ≥ `0.55.0` — unchanged.

**Tests:** down to **15 in 5 suites** (was 29 in 8) — `ExportManagerTests`, `ImportProgressTests`, `ScriptManifestTests` moved to OCCTSwiftIO. `CADFileLoaderTests`, `BodyUtilitiesTests`, `CurveConverterTests`, `SurfaceConverterTests`, `ShapeMeasurementsTests` stay.

## v0.5.1 — 2026-05-06

Closes [#13](https://github.com/gsdali/OCCTSwiftTools/issues/13). `ShapeMeasurements` and `Shape.measure(linearTolerance:)` were hoisted into the OCCTSwift kernel in [OCCTSwift v0.170.1](https://github.com/gsdali/OCCTSwift/releases/tag/v0.170.1) (PR [#163](https://github.com/gsdali/OCCTSwift/pull/163)). This release removes the duplicate copy that lived here.

**No public API change.** `ShapeMeasurements` and `shape.measure()` still resolve at every existing call site — they now come from `OCCTSwift` instead of `OCCTSwiftTools`. `CADFileLoader.shapeToBodyAndMetadata(includeMeasurements: true)` still populates `CADBodyMetadata.measurements` exactly as before; the field's type is now the kernel-side `ShapeMeasurements`, which is identical in shape and behaviour to the previous Tools-side type.

**What changed in the repo:**
- Deleted `Sources/OCCTSwiftTools/ShapeMeasurements.swift`.
- Trimmed `Tests/OCCTSwiftToolsTests/ShapeMeasurementsTests.swift` to the single Tools-specific case (`t_metadataIncludesMeasurementsWhenRequested`, which exercises `CADFileLoader.shapeToBodyAndMetadata`). The other 5 cases live in the OCCTSwift kernel test suite as of #163.

**Dependencies bumped:**
- `OCCTSwift` ≥ **0.170.1** *(was 0.168.0)* — required for the kernel-side `ShapeMeasurements` type. The xcframework binary is unchanged from v0.170.0, so SPM consumers don't re-download.
- `OCCTSwiftViewport` ≥ `0.55.0` — unchanged.

## v0.5.0 — 2026-05-03

**Behaviour change (pre-1.0).** Closes [#10](https://github.com/gsdali/OCCTSwiftTools/issues/10).

Converges `ViewportBody.vertices` / `vertexIndices` / `CADBodyMetadata.vertices` on the **source-shape convention** so AIS' `Selection.vertices` accessor (and any other consumer) can round-trip a picked `primitiveIndex` back to a `TopoDS_Vertex` via `shape.vertex(at: primitiveIndex)`. v0.4.1's polyline-endpoint convention rendered the same number of points for typical solids but in a different order, breaking that round-trip.

**What changed at runtime:**
- `body.vertices` is now `shape.vertices()` Float-converted (was: deduplicated polyline endpoints).
- `body.vertexIndices` is now the explicit identity array `[0, 1, …, n-1]` (was: empty, treated as identity by the renderer). Belt-and-braces against future renderer changes that drop the empty-as-identity interpretation.
- `CADBodyMetadata.vertices` aligns with `body.vertices` — single source of truth.

**No public API signature changes.** The `ViewportBody.init` and `CADBodyMetadata.init` shapes are unchanged; what's different is what populates them.

**AIS coordination:** AIS v0.6.1 currently overrides `body.vertices` and `body.vertexIndices` itself in `InteractiveContext.display(_:)` to fix the round-trip. Once consumers upgrade to OCCTSwiftTools v0.5.0, AIS can drop that override — both sides will be writing identical data, so the transition is non-breaking.

**Internal cleanup:** dropped the private `deduplicateVertices(from:)` helper (dead code post-convergence).

**Dependencies:** unchanged (`OCCTSwift` ≥ `0.168.0`, `OCCTSwiftViewport` ≥ `0.55.0`).

## v0.4.1 — 2026-05-03

Wires AIS edge + vertex GPU picking through. OCCTSwiftViewport v0.55.0 added the renderer-side edge/vertex pick pipelines ([viewport#24](https://github.com/gsdali/OCCTSwiftViewport/issues/24)), but their `body.edgeIndices` / `body.vertices` gates meant our bodies showed up as face-pickable only. Closes [#8](https://github.com/gsdali/OCCTSwiftTools/issues/8).

**Behaviour change in `CADFileLoader.shapeToBodyAndMetadata`:**

- **`ViewportBody.edgeIndices`** is now populated by flattening `metadata.edgePolylines` into per-segment indices. A polyline of N points contributes (N − 1) segments, each tagged with the source edge's index. Picked segment → `TopoDS_Edge`.
- **`ViewportBody.vertices`** is now populated with the deduplicated edge endpoints (same data as `metadata.vertices`).
- **`ViewportBody.vertexIndices`** stays empty — the renderer treats empty as identity (the pick result's `primitiveIndex` is the vertex index directly), so emitting a `[0, 1, 2, …]` array would be wasted bytes.

The data extraction (`extractEdgePolylines`, `deduplicateVertices`) was already running on every body, so this is a near-free wiring change. No public API surface change; existing call sites get the new pick fields populated with no opt-in required.

**Dependencies bumped:**
- `OCCTSwiftViewport` ≥ **0.55.0** *(was 0.51.0)* — required for the new `edgeIndices` / `vertices` / `vertexIndices` parameters on `ViewportBody.init`.
- `OCCTSwift` ≥ `0.168.0` — unchanged.

## v0.4.0 — 2026-05-03

STEP/IGES import progress + cancellation, finally. Upstream OCCTSwift v0.168.0 wrapped `Message_ProgressIndicator` (closing [OCCTSwift#98](https://github.com/gsdali/OCCTSwift/issues/98)) — this release plumbs that through the bridge.

**New:**

- **`CADFileLoader.load(from:format:progress:)`** — optional `progress: ImportProgress?` parameter (default `nil` — backwards compatible). Honored by `.step` and `.iges` formats only; STL/OBJ/BREP loaders are single-call upstream and don't surface progress.
- **`ImportProgressClosure`** — closure-backed `ImportProgress` adapter so callers don't need to write a one-shot subclass:

  ```swift
  let result = try await CADFileLoader.load(
      from: url, format: .step,
      progress: ImportProgressClosure(
          cancelCheck: { Task.isCancelled },
          progress: { fraction, step in
              Task { @MainActor in progressBar.setValue(fraction) }
          }
      )
  )
  ```

  `progress` callbacks fire on the importer's thread (a background thread when launched via `CADFileLoader.load`); UI updates must hop to the main actor explicitly.

**Cancellation:** Returning `true` from `progress.shouldCancel()` causes the import to throw `OCCTSwift.ImportError.cancelled` at the next OCCT progress boundary. Caller catches that to distinguish cancel from a real failure.

**IGES fallback note:** When `Shape.loadIGES` succeeds but `shapeToBodyAndMetadata` returns nil, the loader retries with `Shape.loadIGESRobust` (sewing/healing pass). Both passes use the same `progress` observer, so progress will sweep `0..1` twice in that scenario.

**Dependencies bumped:**
- `OCCTSwift` ≥ `0.168.0` *(was 0.167.0)* — required for `ImportProgress` protocol.
- `OCCTSwiftViewport` ≥ `0.51.0` — unchanged.

## v0.3.0 — 2026-05-03

Two more measurement primitives for OCCTSwiftAIS' dimension widget. The originally-planned v0.3.0 headline (STEP/IGES import progress callbacks) is **deferred to v0.4.0** — upstream OCCTSwift v0.167.0 doesn't wrap `Message_ProgressIndicator`, so we have nothing to bridge. Tracked in [OCCTSwift#98](https://github.com/gsdali/OCCTSwift/issues/98).

**New on `ShapeMeasurements`:**

- **`faceCentroids: [SIMD3<Double>]`** — surface center-of-mass for each face, parallel to `faceAreas`. Wraps `Face.surfaceInertia` (`BRepGProp_Sinert`).
- **`facePerimeters: [Double?]`** — outer-wire length for each face, parallel to `faceAreas`. `nil` when a face has no outer wire or wire length is unavailable. **Caveat**: this is the *outer* boundary length — for a face with internal holes, the inner-wire perimeters are excluded. Usually what dimension widgets want, but worth knowing.
- **`totalFacePerimeter: Double`** — convenience aggregate (skips nil entries).

**Behaviour:** `ShapeMeasurements.init` gains two new parameters with defaults `[]` (preserves source compatibility for any direct constructor calls). `Shape.measure(linearTolerance:)` populates all four arrays in one pass over `shape.faces()`.

**Dependencies:** unchanged (`OCCTSwift` ≥ `0.167.0`, `OCCTSwiftViewport` ≥ `0.51.0`).

## v0.2.0 — 2026-05-03

Convenience features pulled forward to unblock the OCCTSwiftAIS dimension widget. All three additions wrap upstream OCCTSwift APIs that already shipped in `0.167.0`; no version bump on the kernel floor.

**New:**

- **`ShapeMeasurements` + `Shape.measure(linearTolerance:)`** — per-face area (`Face.area`) and per-edge length (`Edge.length`) reports, indexed parallel to `shape.faces()` / `shape.edge(at: 0..<edgeCount)` so AIS can resolve a picked face/edge index directly to a scalar measurement. Convenience aggregates: `totalFaceArea`, `totalEdgeLength`.
- **`CADBodyMetadata.measurements: ShapeMeasurements?`** — populated when `shapeToBodyAndMetadata(...)` is called with `includeMeasurements: true`. Off by default — measurement iteration is O(faces+edges) and not free for large assemblies.
- **`CADFileFormat.iges`** (`.iges` / `.igs` extensions) — wraps `Shape.loadIGES(from:)` with `loadIGESRobust` fallback. IGES files commonly ship with gaps OCCT's basic importer can't close; the robust path applies sewing/healing.
- **`ExportFormat.gltf` and `.glb`** — wraps `Exporter.writeGLTF(shape:to:binary:deflection:)`. `.gltf` writes JSON + a sibling `.bin` buffer file; `.glb` writes a single binary container.

**Behaviour:**
- `CADBodyMetadata.init` gains a `measurements:` parameter with default `nil`. Existing call sites continue to work unchanged.
- `shapeToBodyAndMetadata(...)` gains `includeMeasurements: Bool = false`. Default behaviour is identical to v0.1.0.

**Deferred to v0.3.0:**
- Face centroid / mass properties / perimeter — upstream OCCTSwift hasn't wrapped `BRepGProp_Face` yet.
- STEP / IGES file-import progress callbacks.

**Dependencies:** unchanged (`OCCTSwift` ≥ `0.167.0`, `OCCTSwiftViewport` ≥ `0.51.0`).

## v0.1.0 — 2026-05-03

Initial release. Lifts the `OCCTSwiftTools` sub-product out of OCCTSwiftViewport into a standalone package so the Metal renderer (OCCTSwiftViewport) stays cleanly OCCT-free and the future OCCTSwiftAIS layer can depend on a stable bridge.

**Public API** (see [SPEC.md](../SPEC.md) "Public API (v0.1.0 — actual migrated surface)" for full signatures):

- `enum CADFileLoader` — `load(from:format:)`, `loadFromManifest(at:)`, `shapeToBodyAndMetadata(...)`, plus `highQualityMeshParams` / `tessellationMeshParams` presets.
- `enum CADFileFormat` — `.step`, `.stl`, `.obj`, `.brep`.
- `struct CADBodyMetadata`, `struct CADLoadResult`.
- `enum CurveConverter` — `curve2DToBody`, `curve3DToBody`.
- `enum SurfaceConverter` — `surfaceToGridBodies`.
- `enum WireConverter` — `wireToBody`.
- `enum BodyUtilities` — `makeMarkerSphere`, `offsetBody` (value + inout).
- `enum ExportManager` + `enum ExportFormat` — `.obj`, `.ply`, `.step`, `.brep`.
- `struct ScriptManifest` (Codable manifest format).

**Load-bearing contract:** `ViewportBody.faceIndices` (mirrored on `CADBodyMetadata.faceIndices`) is per-triangle source-face index data parallel to the triangle list. OCCTSwiftAIS will use it to map GPU pick results back to `TopoDS_Face` instances. Preserve bit-for-bit across future changes.

**Dependencies:**
- `OCCTSwift` ≥ `0.167.0`
- `OCCTSwiftViewport` ≥ `0.51.0` — the v0.51.0 floor is hard, not advisory: earlier viewport releases ship a target also named `OCCTSwiftTools`, which SPM rejects as a target-name collision across the package graph. Tracked in [OCCTSwiftViewport#22](https://github.com/gsdali/OCCTSwiftViewport/issues/22).

**Test invocation:** `OCCT_SERIAL=1 swift test --parallel --num-workers 1`. The env var + serial workers are required, not optional, due to a known NCollection container-overflow race in OCCT on arm64 macOS.

**Platform floor:** iOS 18 / macOS 15 / visionOS 1 / tvOS 18, the higher of OCCTSwift's and OCCTSwiftViewport's floors. (What that release declared. The visionOS / tvOS half was never true, and was dropped before 1.0.0; see the Unreleased entry above.)
