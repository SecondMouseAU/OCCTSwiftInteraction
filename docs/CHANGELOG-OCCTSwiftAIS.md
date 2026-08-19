---
title: Changelog
nav_order: 5
---

# Changelog

Most recent first. Breaking changes and deprecations documented here.

## Unreleased

Migrate to OCCTSwift 3.0.0. Closes [#44](https://github.com/SecondMouseAU/OCCTSwiftAIS/issues/44).

There is no direct OCCTSwift pin in this repo: the kernel arrives through `OCCTSwiftTools`, and
OCCTSwift 3.0.0 lands inside the existing `1.6.1..<2.0.0` Tools range. The source breaks are real
regardless.

**Behaviour change (not source-breaking):** `Shape.bounds`, `Face.bounds` and friends became
Optional in [OCCTSwift 3.0.0](https://github.com/SecondMouseAU/OCCTSwift/blob/v3.0.0/docs/SEMVER.md#v300),
returning nil for a shape with no bounding box instead of fabricating `(0,0,0)-(0,0,0)`. That
distinction is now carried through this repo rather than collapsed back to the origin:

- `DimensionAnchor.resolve(_:)` and its four per-kind resolvers return `SIMD3<Float>?`. A dimension
  with any unresolvable anchor reports `anchorPoints == []`, a `nan` `distance` / `degrees`, and a
  `"?"` label. The `nan` path was already documented and is now actually reachable.
- `InteractiveContext.add(_:)` registers such a dimension but does not push a measurement to the
  overlay, so it draws nothing instead of being drawn at the world origin.
  `refreshDimensionMeasurement(_:)` adds the annotation once the anchors resolve and removes it if
  they stop. `RadialDimension` is deliberately untouched: it reports `[.zero, .zero]` rather than
  `[]` for a non-circular edge, a contract that predates this change, is asserted by two tests, and
  does not go through the bounds accessors.
- `selectRectangle` / `selectPolygon` do not treat an object whose `Shape.bounds` is nil as a
  `.body` candidate, the same way a sub-shape kind with no identity table is skipped. Previously
  such an object presented as a zero-size box at the origin and would match any region drawn there.

**Also absorbed here:** two OCCTSwift 2.0.0 breaks this repo never took, because it sat out the
v2.0.0 fanout on the grounds that it had no direct pin (it still received 2.0.0 transitively through
Tools 1.6.3). `ShapeMeasurements.faceCentroids` became `[SIMD3<Double>?]`, which broke the test
target's compile at five sites, now routed through a new `facesWithCentroids(of:)` test helper that
drops faces with no centroid rather than comparing them as if they sat at the origin.

**Known failure, not fixed here:** `t_sharedFaceBetweenShells_everyPickResolvesToCorrectSubShape`
fails (5 expectations). OCCTSwift 2.0.0 moved `Shape.faces()` to the deduplicated enumeration and
added `orientedFaces()` for the occurrence-wise one, which erases the raw-vs-deduplicated split that
test and the shared-face identity guarantee in
[#31](https://github.com/SecondMouseAU/OCCTSwiftAIS/issues/31) are built on. Deciding what
`FaceIdentityTable` should enumerate post-2.0.0 is an OCCTSwiftTools question, not a v3.0.0
migration fix.

## v1.3.1 — 2026-07-20

Housekeeping: migrate off deprecated `TopologyGraph` → `BRepGraph`. Closes [#37](https://github.com/SecondMouseAU/OCCTSwiftAIS/issues/37). No behaviour change — pure rename, underlying type unchanged.

OCCTSwift renamed `TopologyGraph` → `BRepGraph` (too close to `TopoDS`, caused naming confusion — SecondMouseAU/OCCTSwift#333, shipped v1.15.0) and left a deprecated typealias in place. Mechanical rename across every reference in this repo: `Sources/OCCTSwiftAIS/{Remap,InteractiveContext,InteractiveObject}.swift`, `Tests/OCCTSwiftAISTests/{InteractiveContextMutationTests,RemapTests,SubShapeTests,TestSupport}.swift`, and every doc that names the type in a current code snippet (`SPEC.md`, `README.md`, `docs/guides/getting-started.md`, `docs/guides/cookbook/selecting-subshapes.md`, `docs/reference/{Selection,InteractiveContext}.md`) — this changelog's own history is left as-written.

**Tests:** 193 across 17 suites, all green, zero deprecation warnings (was ~30+ across the build).

## v1.3.0 — 2026-07-20

Rectangle and lasso area selection. Closes [#33](https://github.com/SecondMouseAU/OCCTSwiftAIS/issues/33).

**Added:**

- `InteractiveContext.selectRectangle(from:to:mode:scheme:viewportSize:)` / `selectPolygon(_:mode:scheme:viewportSize:)` — honour `selectionMode` and installed `filters` exactly as a point pick does. `AreaSelectionMode`: `.enclosed` (every candidate vertex inside the region) / `.intersecting` (at least one). `SelectionScheme`: `.replace` / `.add` / `.remove` / `.xor`, mirroring OCCT's `AIS_SelectionScheme`.
- `AreaSelectionController` + `.attachAreaSelection(_:)`, mirroring `ManipulatorWidget`/`attachManipulator(_:)`'s exact architecture: a `.highPriorityGesture(DragGesture)` wrapper, a live rubber-band (rectangle) / lasso outline drawn as a plain SwiftUI overlay, and an explicit `AreaSelectionTool` (`.navigate` / `.rectangle` / `.lasso`) — `.navigate` (the default) forwards drags straight through to `ViewportController.handleOrbit`/`endOrbit`, so attaching the modifier changes nothing until the app explicitly switches tools.

**Implementation note — a departure from the issue's suggested "first cut":** the issue proposed GPU-based `.intersecting` (reading the pick texture over the drag region) as the easy first pass. Investigation found the opposite: OCCTSwiftViewport's `performPick(at:)` reads exactly one pixel, has no batch/region variant, and its pick texture is GPU-private — a pixel-scan approach isn't available without a new OCCTSwiftViewport API (filed as [OCCTSwiftViewport#90](https://github.com/SecondMouseAU/OCCTSwiftViewport/issues/90)). Shipped instead: CPU-side, vertex-projection based enclosure/intersection testing via the existing public `ProjectionUtility.worldToScreen(point:vpMatrix:viewportSize:)`. Two documented limitations follow from this: **no occlusion handling** (a hidden sub-shape can still be picked up if its vertices project into the region), and a **vertex-only approximation** (a region entirely inside a large face's interior, touching none of its vertices, won't register as intersecting; curved edges are approximated by their endpoints).

**Also in this release** (prep work for the above, closing out a known limitation from v1.1.0): `OCCTSwiftTools` floor raised `1.5.0` → `1.6.0`, adopting `EdgeIdentityTable` / `VertexIdentityTable` (OCCTSwiftTools#43/#44) via the new `shapeToBodyMetadataAndIdentities(...)` entry point. Edge and vertex `SubShapeRef.uid`s are now minted from real tessellation-time identity tables — the same footing faces have had since v1.1.0 — rather than the ad-hoc `graph.findNode(for:)` workaround on the ordinal-resolved shape. `InteractiveContext.remap` picks up the same upgrade: edge/vertex successors now get a correct render-path ordinal from their own identity table instead of falling back to the graph's raw node index.

**Docs:** new cookbook page (`docs/guides/cookbook/area-selection.md`) and reference page (`docs/reference/AreaSelection.md`); SPEC.md gained an "Area selection (#33)" implementation-guidance section documenting the GPU-vs-CPU deviation above.

**Tests:** 193 across 17 suites, all green. 15 new (`AreaSelectionTests`) covering rectangle/lasso basics, `.enclosed` vs `.intersecting` distinguishability, `selectionMode` honouring, filter gating, all four `SelectionScheme` values, gesture-coordinator navigate/rectangle modes, and a many-faced-model responsiveness sanity check.

## v1.2.0 — 2026-07-20

Topology-aware selection filters. Closes [#32](https://github.com/SecondMouseAU/OCCTSwiftAIS/issues/32).

**Added:**

- `SelectionFilter` protocol (`AnyObject, Sendable` — a class, not a struct, so `removeFilter(_:)` can identify an installed instance by reference, same reason as `Dimension`) and built-ins: `SurfaceTypeFilter(_ kinds: Set<Face.SurfaceType>)`, `CurveTypeFilter(_ kinds: Set<Edge.CurveType>)`, `ShapeTypeFilter(_ modes: Set<SelectionMode>)`. Reuses OCCTSwift's own `Face.SurfaceType` / `Edge.CurveType` classification directly rather than introducing a parallel enum, since OCCTSwift already ships exactly the needed classification.
- Composition: `AllOfFilter`, `AnyOfFilter`, `NotFilter`, and a `PredicateFilter` closure escape hatch.
- `InteractiveContext.addFilter(_:)` / `removeFilter(_:)` / `removeAllFilters()` / `filters: [any SelectionFilter]` (`@Published`). Installed filters gate `handlePick` and `handleHover` — never programmatic `select(_:)`, which (like `selectionMode`) is an intentional override by app code. A candidate a filter rejects is treated exactly like an empty-space pick: the current selection is left unchanged, not cleared.
- **Combination semantics — a deliberate departure from OCCT:** `AIS_InteractiveContext::AddFilter` combines multiple installed filters with OR; here, `filters` combine with **AND** (a candidate must pass every installed filter) — OR reads as a surprising default for narrowing what's selectable, since a second filter could then only ever widen what's pickable. Use `AnyOfFilter` explicitly for OR.
- Filters compose with the widget pick-layer routing without any special-casing needed: widget picks route through `viewport.widgetPickResult`, never through `handlePick`, so an installed filter has no effect on `ManipulatorWidget` regardless of how restrictive it is.

**Docs:** new cookbook page (`docs/guides/cookbook/filtering-selection.md`) and reference page (`docs/reference/SelectionFilters.md`); getting-started walkthrough gained a new "Selection filters" section (renumbering sections 5-8 to 6-9). Also fixed a stale `docs/guides/getting-started.md` accessor table left over from v1.1.0 (`Selection.faces`/`.edges`/`.vertices` resolve from `SubShapeRef.shape`, not an index lookup — the table hadn't been updated in that release).

**Tests:** 16 new (`SelectionFilterTests`) covering surface/curve/shape-type filtering, all four composition types, pick/hover gating, AND-not-OR combination semantics, `removeFilter`/`removeAllFilters`, and widget pick-layer isolation. **178 across 16 suites**, all green.

## v1.1.0 — 2026-07-20

Durable sub-shape identity, replacing the index-remap path with `TopologyGraph` absorbed history. Closes [#31](https://github.com/SecondMouseAU/OCCTSwiftAIS/issues/31).

**Breaking:**

- `SubShape.face`/`.edge`/`.vertex` now carry a `ref: SubShapeRef` instead of a bare `Int` index — `SubShapeRef` bundles the resolved `Shape`, an optional `TopologyGraph.GraphUID` (durable — minted when a graph was in hand at pick time), and the tessellation-time `ordinal` (render-path only). `SubShapeRef` equality/hashing follows `uid` when both sides have one, falling back to `ordinal` only when neither does.
- `RemapStrategy` (`.dropMissing` / `.keepUnchanged`) is removed. `InteractiveContext.remap(_:using:rebindingTo:)` no longer takes a `strategy:` — it resolves every sub-shape through its `uid` via `TopologyGraph.node(forUID:)` (which rejects a uid minted by a different graph instance rather than resolving to a coincidentally-matching node) and `findDerivedOrSelf(of:)`. A sub-shape with no `uid` is dropped; there is no more "keep the old index and hope" fallback, because there's no ambiguity left for one to paper over.
- `Selection.faces` / `.edges` / `.vertices` resolve directly from each entry's `SubShapeRef.shape` — the `Shape.subShape(type:index:)` round-trip on a stored ordinal is gone.

**Added:**

- `InteractiveContext.update(_:to:absorbing:operationName:)` — update a displayed object after a modelling operation (any OCCTSwift `*WithFullHistory` method). Absorbs the operation's history into the object's living `TopologyGraph` (built once at `display(_:style:)`, retained across every subsequent `update` call — the whole point being that `GraphUID`s minted before a mutation stay resolvable after it), rebuilds the mesh, and remaps `selection`/`hover` forward automatically.
- `InteractiveContext.isDeleted(_:in:)` — distinguishes "the operation consumed this sub-shape" (`TopologyGraph.historyIsDeleted(_:)`) from "it wasn't selected," which a silent `remap` drop can't do on its own.
- Face picks consume `OCCTSwiftTools.FaceIdentityTable` (v1.5.0, OCCTSwiftTools#42) instead of re-deriving a `TopoDS_Face` from `Shape.subShapes(ofType:)[ordinal]` — the two enumerations diverge once a face is shared between shells, which is exactly the coincidence this closes.

**Known limitation:** `FaceIdentityTable` is faces-only upstream. Edge/vertex `SubShapeRef.uid`s are minted directly at pick time (`TopologyGraph.findNode(for:)` on the ordinal-resolved edge/vertex `Shape`) rather than from a tessellation-time identity table, so they carry the same residual ordinal-coincidence risk `FaceIdentityTable` was built to eliminate for faces. Filed as [OCCTSwiftTools#43](https://github.com/SecondMouseAU/OCCTSwiftTools/issues/43).

**Dependencies:** `OCCTSwiftTools` floor raised `1.1.2` → `1.5.0` (re-pins the cohort onto current `OCCTSwift` — `1.12.9+`, still the OCCT 8.0.0p1 GA cohort — and ships `shapeToBodyMetadataAndIdentity(...graph:)` + `FaceIdentityTable`).

**Tests:** 12 new (`t_remap_faceUntouchedByOperation_resolvesToItself`, `t_remap_faceSplitByChannelCut_expandsToBothStrips`, `t_remap_faceEntirelyRemoved_isDroppedAndReportedDeleted`, `t_remap_uidForeignToGraph_isDropped`, `t_update_retainsSameGraphAcrossTwoSuccessiveMutations`, `t_sharedFaceBetweenShells_everyPickResolvesToCorrectSubShape` (multi-shell shared-face regression, mirroring OCCTSwiftTools' own `FaceIdentityTableTests` fixture end-to-end through `InteractiveContext`), and others). **162 across 15 suites**, all green.

## v0.7.2 — 2026-05-07

Housekeeping floor bump + comment fix. No behaviour change.

- **`Package.swift`**: `OCCTSwiftTools` floor raised from `0.5.0` to `0.6.0`. Tools v0.6.0 splits file-I/O concerns into the new [OCCTSwiftIO](https://github.com/gsdali/OCCTSwiftIO) sibling and `@_exported import`s it, so AIS's existing `OCCTSwiftTools.X` references still resolve unchanged. Closes [#17](https://github.com/gsdali/OCCTSwiftAIS/issues/17).
- **`Dimension.swift:233`**: stray comment naming `OCCTSwiftTools.ShapeMeasurements.faceCentroids` updated to point at the kernel-hoisted `ShapeMeasurements.faceCentroids` in OCCTSwift (`OCCTSwift` v0.170.1 / Tools v0.5.1). Comment-only — the bbox-centroid heuristic in `resolveFace` is unchanged. Closes [#16](https://github.com/gsdali/OCCTSwiftAIS/issues/16).
- Install snippets in `README.md` and `docs/getting-started.md` refreshed to `from: "0.7.2"`.

**Tests:** 158 across 14 suites, all green. No new tests.

## v0.7.1 — 2026-05-03

Adds three tests that exploit the cutter-simulation provenance of the STEP fixtures (CAM outputs from a 6 mm milling cutter).

- `t_stockHasNoCircularEdges` — a CAM stock blank is a pure rectangular block; every edge has `isCircle == false`. Three parametrised cases over the committed stock files.
- `t_wipFile_hasCircularEdgesFromCutterPath` — the WIP files (skip-on-missing) must have at least one circular edge from the cutter's footprint. Three parametrised cases.
- `t_wipFile_radialDimensionOnCutterFootprint_resolves` — round-trip a `RadialDimension` on the first circular edge of each WIP: `radius` is finite + positive, label has the `R` prefix, `viewport.measurements` carries a `.radius` variant. Three parametrised cases.

**Tests:** 158 across 14 suites. WIP suite now ~40 s on the three multi-MB files when present; stock suite still sub-second.

**Dependencies:** unchanged.

## v0.7.0 — 2026-05-03

Real-shape STEP integration tests. The end-to-end pipeline (`CADFileLoader.load` → `InteractiveContext.display` → synthetic `PickResult` → `Selection`) now runs against actual machined-part geometry, not just OCCT primitives.

**New:**

- `Tests/OCCTSwiftAISTests/Fixtures/` — three small (~16 KB each) committed STEP files representing rectangular CAM stock plates (`101-CAM_test_1_6mm_stock`, `_2_`, `_3_`). Wired through `Package.swift`'s test target via `resources: [.copy("Fixtures")]` and accessed via `Bundle.module.url(forResource:withExtension:subdirectory:)`.
- `Tests/OCCTSwiftAISTests/STEPIntegrationTests.swift` — two suites:
  - `STEP integration — committed stock fixtures` (`.serialized`, `@MainActor`): 7 tests × 3 fixtures = 21 parametrised cases. Asserts load succeeds, single-shape result, six-face / twelve-edge / eight-vertex topology of a rectangular block, non-degenerate bounds, mesh tessellation produces triangles + populated edge / vertex pick buffers, face / vertex pick `PickResult` round-trips through to `Selection`, linear dimension across opposite parallel faces matches a bbox extent, `remap` with `keepUnchanged` preserves the index when the topology is identical.
  - `STEP integration — local WIP fixtures (skip-on-missing)` (`.serialized`): same shape on the much larger (~5–8 MB each) machined-part WIP files in `test_files/`. Walks up from `Bundle.module.bundleURL` looking for the package root + `test_files/<name>.step`; silently passes when the file is absent so CI without the WIP files stays green. Asserts WIP topology is more complex than stock (more than 6 faces, 12 edges, 8 vertices) and the same display + pick round-trip works on real-world geometry.
- `.gitignore` excludes `test_files/` so the committed fixtures stay small.

**Suite ordering:** `.serialized` is required on both — the OCCT NCollection arm64 race triggers SIGSEGV under Swift Testing's intra-process parallelism even with `--num-workers 1` (which controls processes, not in-process tasks).

**Tests:** **155 across 14 suites**, all green. WIP suite runs in ~15s on the three multi-MB files; stock suite is sub-second.

**Dependencies:** unchanged from v0.6.3.

## v0.6.3 — 2026-05-03

Documentation polish. No code or test changes.

- `README.md` rewritten as a compact landing — features-at-a-glance, install, 30-second example, link to the new walkthrough. Architecture / platforms / license sections kept; install snippet bumped to `from: "0.6.3"`.
- New `docs/getting-started.md` — walkthrough exercising the full public API in narrative order: `InteractiveContext` setup, `display`, selection modes / `Selection` derived accessors, presentation styles, translate + rotate manipulators, `.attachManipulator(_:)` SwiftUI integration, dimensions (linear / angular / radial), standard scene objects, `remap`, and a "synthesise a `PickResult` for tests" recipe. Each snippet is checked against the v0.6.2 source tree (every public symbol it references exists today).

Drop-in upgrade — no behaviour change.

## v0.6.2 — 2026-05-03

Drops the `populateEdgeVertexPickArrays` workaround — [OCCTSwiftTools v0.5.0](https://github.com/gsdali/OCCTSwiftTools/releases/tag/v0.5.0) now populates `body.vertices` / `vertexIndices` / `edgeIndices` on the source-shape convention, so AIS no longer has to override Tools' output. Closes [OCCTSwiftTools#10](https://github.com/gsdali/OCCTSwiftTools/issues/10).

`InteractiveContext.display(_:)` is back to a thin wrapper around `CADFileLoader.shapeToBodyAndMetadata`. ~30 lines removed; the round-trip from a vertex pick's `primitiveIndex` to `Selection.vertices` (via `shape.vertex(at: idx)`) keeps working because the data is now identical between Tools' output and what AIS used to write.

**Dependencies:** floor raised to `OCCTSwiftTools` ≥ 0.5.0 (transitively `OCCTSwiftViewport` ≥ 0.55.1, `OCCTSwift` ≥ 0.168.0).

**Tests:** 146 across 12 suites, all green. No new tests; the existing `EdgeVertexSelection` round-trips now exercise Tools' implementation rather than AIS's override.

## v0.6.1 — 2026-05-03

Adopts the renderer-backed per-triangle highlight overlay shipped in [OCCTSwiftViewport v0.55.1](https://github.com/gsdali/OCCTSwiftViewport/releases/tag/v0.55.1) (closes [#25](https://github.com/gsdali/OCCTSwiftViewport/issues/25)). The v0.1 cheap-route normal-offset overlay is gone — `InteractiveContext.updateSelectionVisuals` now writes per-triangle `TriangleStyle` entries directly into the source body's `triangleStyles` array.

**Behaviour changes (no public API change):**

- Face-level selection no longer spawns `ais.overlay.sel.<UUID>` overlay bodies. The renderer composites the highlight in a dedicated pass after the shaded geometry pass with `depthCompareFunction = .lessEqual` — no more silhouette flicker, no more body-count blow-up on multi-face selection.
- `ctx.bodies` count after a face selection is now N (just source bodies), not 2N (source + overlay) as in v0.1 → v0.6. Consumers asserting body counts will see this drop.
- `setHighlightStyle` rewrites the `triangleStyles` array on the affected bodies directly.
- `display()` no longer needs the "keep overlays trailing" pass, since there are no overlay bodies to order.

**Removed:**

- `InteractiveContext.makeFaceOverlay(...)` and `computeOverlayEpsilon(...)` static helpers.
- `overlayBodyIDs: Set<String>` private state on `InteractiveContext`.

**Tools v0.4.1 coordination:**

[OCCTSwiftTools v0.4.1](https://github.com/gsdali/OCCTSwiftTools/releases/tag/v0.4.1) (which dropped between v0.6.0 and this release) populates `body.vertices` from polyline endpoints and leaves `vertexIndices` empty. AIS overrides both with `shape.vertices()` source-vertex positions so a vertex pick's `primitiveIndex` round-trips to a `TopoDS_Vertex` via `Selection.vertices` (`shape.vertex(at: idx)`). Filed as [OCCTSwiftTools#10](https://github.com/gsdali/OCCTSwiftTools/issues/10) — once converged, the AIS-side override drops.

**Tests:**

`HighlightOverlay` suite renamed to `FaceHighlight` and rewritten to assert against `body.triangleStyles` instead of overlay-body presence:

- `t_faceSelection_writesNonZeroAlphaForMatchingTriangles` — every highlighted triangle's `faceIndices[idx]` matches the selected face.
- `t_faceSelection_doesNotProduceSeparateOverlayBody` — `ctx.bodies.count == 1` after selection; no `ais.overlay.*` ids exist.
- `t_highlightColor_isSelectionColorWithFullAlpha` — color in `triangleStyles` matches `highlightStyle.selectionColor` with alpha 1.
- `t_setHighlightStyle_updatesLiveStyles` — color rewrites in place after a style change.
- `t_clearSelection_clearsTriangleStyles` — clears the array.
- `t_multiFaceSelection_unionsTrianglesOnSameBody` — multiple selected faces produce highlighted triangles for each.
- `t_facesAcrossTwoBodies_writeStylesOnEach` — independent bodies each get their own styles.
- `t_displayAfterSelection_doesNotResurrectOverlayBodies` — adding new shapes after a selection doesn't spawn overlay bodies.
- Body-level highlight tests unchanged (`viewport.selectedBodyIDs` path).

Total: **146 across 12 suites** (test count unchanged; HighlightOverlay tests rewritten in place rather than added).

**Dependencies:** transitively `OCCTSwiftViewport` ≥ 0.55.1 via `OCCTSwiftTools` ≥ 0.4.0; SPM resolves to current latest.

## v0.6.0 — 2026-05-03

History-based selection remap per SPEC.md §"Selection survival across mutation". After a target shape is modified — boolean ops, fillets, etc. — `InteractiveContext.remap(_:using:rebindingTo:)` translates an old `Selection`'s sub-shape indices to the new shape's indices via OCCTSwift's `TopologyGraph` history records.

The renderer-backed highlight overlay path SPEC also flags as v0.6+ work has been filed as [OCCTSwiftViewport#25](https://github.com/gsdali/OCCTSwiftViewport/issues/25); AIS will pick it up in a v0.6.x once the renderer ships per-triangle style buffers. The current cheap-route normal-offset overlay continues to ship in the meantime.

**New public surface:**

- `enum RemapStrategy: Sendable` — `.dropMissing` (default; safest — drops sub-shapes the history doesn't recognise as derived from the original) / `.keepUnchanged` (preserves the original index when no derivative is recorded — only safe for attribute-only or in-place edits where indices don't shift).
- `InteractiveContext.remap(_ selection:using:rebindingTo:strategy:) -> Selection` — translates each sub-shape:
  - **1 → 1** (face / edge / vertex modified in place): the result has the new index.
  - **1 → N** (e.g. an edge split): expands to N sub-shapes, one per derived node.
  - **1 → 0** (deleted): handled per `strategy`.
  - `.body(_)` always rebinds to `newObject`.
- Cross-kind history entries (e.g. a face → edges record) are filtered — a `Selection.face` slot can only hold a face index.

**Caveat documented in code:** `TopologyGraph.findDerived` returns an empty list both for "node not mentioned in any history record" *and* for "node explicitly recorded as deleted (`replacements: []`)". The two are indistinguishable through the current OCCTSwift surface, so `.keepUnchanged` may incorrectly preserve explicitly-deleted nodes. Use `.dropMissing` when you don't know whether the operation deleted anything.

**Tests:** 10 new in `Remap` (body always rebinds; dropMissing default behaviour; keepUnchanged in-range and out-of-range; recorded 1→1, 1→N expansion, 1→0 deletion; cross-kind history filtered; mixed-kind selection remaps each entry independently; empty input). Total: **146 across 12 suites**.

**Dependencies:** unchanged from v0.5.0 — `TopologyGraph` has been on the kernel surface since OCCTSwift v0.141.

## v0.5.0 — 2026-05-03

Angular and radial dimensions per SPEC.md §"Sequencing" v0.5. With this release the dimension surface is feature-complete (linear / angular / radial) and the public API listed in SPEC.md §"Dimensions" is now fully implemented. Rendering still rides on `MetalViewportView`'s built-in `MeasurementOverlay` — no renderer-side changes.

**New public types:**

- `final class AngularDimension: Dimension` — `init(arms:apex:customLabel:id:)`. Anchors order is `[armA, apex, armB]` matching the standard "vertex in the middle" convention. `degrees` reports the angle at the apex via `ProjectionUtility.angle`; `label` formats with the degree glyph. Emits `ViewportMeasurement.angle`.
- `final class RadialDimension: Dimension` — `init(circularEdge:showDiameter:customLabel:id:)`. Resolves `(center, edgePoint, radius)` from `Edge.curve3D.circleProperties` when the underlying curve is circular; falls back to collapsed anchors + `"?"` label when it isn't. `showDiameter` toggles between `R<radius>` and `⌀<diameter>`. Emits `ViewportMeasurement.radius`.

**New internal:** `DimensionAnchor.resolveCircle(_:)` — returns `(center, pointOnCircle, radius)` for an `.edge` sub-shape whose curve is circular; nil otherwise.

**Tests:** 14 new in `AngularDimension / RadialDimension`. Total: **136 across 11 suites**. Coverage: anchor ordering for the angular case; degree-glyph in label; cylinder-edge round-trip for radial (radius matches construction within 1e-3); `R` vs `⌀` prefix; non-circular edge / non-edge sub-shape produces collapsed anchors and `"?"` label; mixed dimensions (linear + angular + radial) coexist in the registry.

**Dependencies:** unchanged from v0.4.0.

**SPEC milestone:** With v0.5.0 the dimension trio is in. Per SPEC sequencing, **v0.6.0+** is "polish + power features" — renderer-backed highlight overlay (replacing the v0.1 cheap-route normal-offset trick) and history-based selection remap (`InteractiveContext.remap(selection:after:)`), both of which need OCCTSwift / OCCTSwiftViewport coordination.

## v0.4.0 — 2026-05-03

Linear dimensions per SPEC.md §"Dimensions". `LinearDimension(from:to:plane:?)` resolves topology-aware anchors (vertex position / edge midpoint / face bbox center / body bbox center) and reports a labeled distance. Rendering reuses OCCTSwiftViewport's existing `MeasurementOverlay` (SwiftUI Canvas) — **no renderer-side changes needed**.

**New public surface:**

- `protocol Dimension: AnyObject, Sendable` — `id`, `label`, `anchorPoints`, `viewportMeasurement`. `AngularDimension` and `RadialDimension` will conform in v0.5.
- `final class LinearDimension: Dimension` — `init(from:to:plane:customLabel:id:)`. Optional `WorkPlane` projects both anchors orthogonally onto the plane before measuring (Cauchy-Schwarz: distance can only shrink). `customLabel` overrides the formatted distance.
- `LinearDimension.distance: Float` — straight-line (or in-plane) distance.
- `InteractiveContext.add<D: Dimension>(_:) -> D` (idempotent for the same instance), `remove(_ dimension: any Dimension)`, `var dimensions: [any Dimension]`, `refreshDimensionMeasurement(_:)` for re-fetch after anchors move.
- `removeAll()` now also clears dimensions and `viewport.measurements`.

**New internal:** `enum DimensionAnchor` — sub-shape → world point resolver (used by all `Dimension` types) + `project(_:onto:)` orthogonal-plane projection + `formatDistance(_:)` label formatter.

**Implementation notes:**

- Face anchors use `Face.bounds` bbox-center (constant time per face). Curved-face users wanting the area-weighted centroid can pass a custom anchor strategy in a future release; for axis-aligned faces the bbox center *is* the centroid.
- Edge anchors use the segment midpoint between `Edge.endpoints`. Curved edges currently linearise; arc-length midpoint is a future refinement.
- Body anchors use `Shape.bounds` center.

**Tests:** 15 new in `LinearDimension`. Total: **122 across 10 suites**.

**Dependencies:** unchanged from v0.3.0.

## v0.3.0 — 2026-05-03

Edge and vertex selection-from-topology — the second half of the v0.3 SPEC milestone (rotate manipulator already shipped in v0.2.2). Closes the headline "selection-from-topology" feature: face / edge / vertex picks from the GPU all round-trip to OCCTSwift handles.

**Behaviour:**

- `InteractiveContext.handlePick` dispatches on `PickResult.kind` from [OCCTSwiftViewport v0.55.0](https://github.com/gsdali/OCCTSwiftViewport/releases/tag/v0.55.0):
  - `.face` → `SubShape.face(obj, faceIndex:)` via `CADBodyMetadata.faceIndices` (unchanged behaviour).
  - `.edge` → `SubShape.edge(obj, edgeIndex:)` via `body.edgeIndices[primIdx]`.
  - `.vertex` → `SubShape.vertex(obj, vertexIndex:)` via `body.vertexIndices[primIdx]`.
- Picks of a kind not in `selectionMode` are ignored.
- `display(_:)` now populates `body.edgeIndices` (flattened from `metadata.edgePolylines`) and `body.vertices` / `body.vertexIndices` (positional, from `shape.vertices()`) so the renderer's edge / vertex pick passes have data to work with. **Workaround for** [OCCTSwiftTools#8](https://github.com/gsdali/OCCTSwiftTools/issues/8) — once Tools populates these directly during `shapeToBodyAndMetadata`, the AIS-side helper becomes a no-op (it early-outs when the arrays are already set).

**New public surface:**

- `Selection.vertices: [SIMD3<Double>]` — world-space positions of any `.vertex(...)` entries. Returns positions rather than a rich type because OCCTSwift exposes vertices as `SIMD3<Double>` values (no `Vertex` class).

**Dependencies:** floor raised to `OCCTSwiftTools` ≥ 0.4.0 (transitively `OCCTSwiftViewport` ≥ 0.55.0, `OCCTSwift` ≥ 0.168.0).

**Tests:** 12 new in `EdgeVertexSelection` covering display populating edge / vertex pick arrays; positional vertex indexing; `handlePick` dispatching face / edge / vertex correctly; mode-mismatched picks ignored; out-of-range primitive ignored; `Selection.vertices` filtering only `.vertex` cases and resolving to source positions; multi-mode replacement on subsequent picks of different kinds. Total: **107 across 9 suites**.

**SPEC milestone status:** `v0.3.0` per SPEC.md §"Sequencing" called for "Manipulator widget (rotate) + edge / vertex selection". Rotate shipped in v0.2.2; this release ships edge/vertex. v0.4.0 onward picks up linear / angular / radial dimensions.

## v0.2.4 — 2026-05-03

Standard scene objects per SPEC.md §"Standard objects". Each emits one or more `ViewportBody`s via `makeBodies()` that the caller appends to their `InteractiveContext.bodies`. They aren't selectable — they're visual aids only.

**New public types:**

- `Trihedron(at:axisLength:id:)` — three colored axis arrows (`ManipulatorWidget.Axis.color` palette) plus a small center sphere. Useful as a world-axes affordance.
- `WorkPlane(origin:normal:size:color:id:)` — semi-transparent quad in the plane perpendicular to `normal`. Two triangles, six indices.
- `Axis(from:to:color:radius:id:)` — thin cylinder between two world points; the `color` parameter is `SIMD3<Float>` to match SPEC, internally packed to `SIMD4<Float>(color, 1)`.
- `PointCloudPresentation(points:colors:pointRadius:defaultColor:id:)` — N small spheres tessellated into a **single** `ViewportBody` for efficiency. Per-point colors not yet supported (renderer doesn't expose per-vertex color attributes); first entry of `colors` becomes the cloud's uniform color, else `defaultColor`.

Each type has an `ownsBody(id:)` predicate so callers can remove all of an instance's bodies later via `context.bodies.removeAll { obj.ownsBody(id: $0.id) }`.

**New internal:** `StandardObjectGeometry` — pure-Swift mesh helpers (`makeQuad`, `makeCylinder`, `makeSphere`, `makeSpheresInOneBody`). Multiple-spheres-as-one-mesh keeps the body count low for moderate clouds.

**Tests:** 15 new in `StandardObjects` covering body counts, ID conventions, color application, geometry scaling with `axisLength` / `size`, normal correctness on the work-plane quad, zero-length axis edge case, color-from-first-entry on point cloud, empty-points no-op. Total: **95 across 8 suites**.

**Dependencies:** unchanged from v0.2.3.

## v0.2.3 — 2026-05-03

`.attachManipulator(_:)` SwiftUI view modifier — wraps a viewport view (e.g. `MetalViewportView`) with a `.highPriorityGesture(DragGesture)` that hit-tests the widget on touch-down and dispatches:

- **Widget hit:** `widget.beginDrag` / `updateDrag` / `endDrag` drives the translate or rotate transform.
- **Off-handle:** drags forward to `viewport.handleOrbit(translation:)` so the camera responds normally. `endOrbit(velocity: .zero)` on release.

Closes the loop on the manipulator UX — apps can now write `MetalViewportView(controller: ais.viewport, bodies: $ais.bodies).attachManipulator(myWidget)` instead of hand-rolling gesture wiring.

**New public surface:**

- `View.attachManipulator(_ widget: ManipulatorWidget) -> some View` — the modifier.
- `ManipulatorWidget.context: InteractiveContext?` (read-only) — exposes the installed context so the modifier can route camera-fallback drags through `widget.context?.viewport`.

**New internal:** `ManipulatorGestureCoordinator` factors the dispatch logic out of SwiftUI's gesture machinery so it's unit-testable. Pure-Swift; tracks `.idle` / `.widget(axis)` / `.camera` mode; exposes `onChanged(location:translation:in:)` and `onEnded()` entry points.

**Tests:** 11 new in `ManipulatorGestureCoordinator` suite covering `ndcFromPoint` math (center → 0; top-left → (-1, +1); bottom-right → (+1, -1); zero size → zero), mode transitions on hit / miss, drag forwarding to widget, orbit forwarding to controller, commit on widget-mode end, and graceful no-op when widget has no installed context. Total: **80 across 7 suites**.

**Dependencies:** unchanged from v0.2.2.

## v0.2.2 — 2026-05-03

`ManipulatorWidget.Mode.rotate` is wired up. Three torus-handle rings appear at install (X / Y / Z, in `Axis.color`); a click on a ring begins a rotation drag; the drag delta is the angle between the initial and current pick-ray-vs-ring-plane intersections, with `snapRotateDeg` rounding. The running transform is `T(pivot) * R(axis, θ) * T(-pivot)`, so the target rotates **around its centroid** (the box-bbox center) and the pivot itself stays fixed. The target body's `ViewportBody.transform` updates live, like translate mode.

Implemented entirely on `ManipulatorWidget` — no new public types or signatures. Translate-mode behavior is unchanged.

**New internal pieces:**

- `ManipulatorGeometry.makeRotationRing(id:pivot:axis:radius:tubeRadius:color:sides:tubeSides:)` — pure-Swift torus tessellation. `renderLayer = .overlay`, `pickLayer = .widget` like the arrow.
- Rotate drag math: pick-ray intersects the ring plane (perpendicular to `axis` through `pivot`); angle measured in a per-axis stable in-plane basis via `atan2`; angle delta wrapped to `(-π, π]` so a drag crossing the ±π seam doesn't jump 2π.
- New configurables: `rotateRingRadius`, `rotateTubeRadius`, `rotateHitTolerance`, `rotateAxisDotMin`. All have sensible defaults derived from `size` / `shaftRadius`.

**Limitations (matching the cheap-route geometry approach):**

- Rings are skipped from hit-testing when their plane is near-parallel to the view direction (`|dot(viewDir, axis)| < rotateAxisDotMin`). In a perfectly axis-on view, two of three rings degenerate to a line in screen space and become unpickable; rotate the camera slightly to recover. A renderer-side screen-space ellipse hit-test (or a CPU "drag along the projected ring tangent") would lift this; deferred to a later release.
- Rings stay anchored at the pivot rather than co-rotating with the target. This keeps the visual reference of "what axis am I rotating around" stable during a long drag. (Some CAD apps rotate the rings; leave that as opt-in if asked.)

**Tests:** 13 new in a `ManipulatorWidget rotate` suite. Total: 69 across 6 suites.

`v0.3.0` is reserved for the bundled rotate + edge/vertex selection milestone per SPEC.md §"Sequencing", waiting on [OCCTSwiftViewport#24](https://github.com/gsdali/OCCTSwiftViewport/issues/24).

**Dependencies:** unchanged from v0.2.1.

## v0.2.1 — 2026-05-03

`ManipulatorWidget` adopts the renderer-side primitives that landed in [OCCTSwiftViewport v0.52.0](https://github.com/gsdali/OCCTSwiftViewport/releases/tag/v0.52.0) (resolves OCCTSwiftViewport#23). No public API changes.

**Behaviour:**

- Arrow bodies set `renderLayer = .overlay` and `pickLayer = .widget`. The renderer draws them after the selection-outline pass with `depthCompareFunction = .always`, so manipulator handles stay visible (and grabbable) even when occluded by the target. Widget picks now flow through `viewport.widgetPickResult` instead of polluting `viewport.pickResult` — the previous id-prefix filter on `InteractiveContext.handlePick` is now redundant but harmless.
- Arrow geometry is built **once** at install (centered on origin in vertex space). Per-frame motion is applied via `ViewportBody.transform`; no more vertex-data churn during drag.
- The target body's transform updates **live** during drag — `body.transform = preInstallTransform * widget.transform`. Users see the body translate in real time, not just on `onCommit`. The pre-install transform is captured at `install(in:)` and restored on `uninstall()`, so the widget's running translation does not survive teardown.
- `install(in:)` against a target whose body already has a non-identity transform composes correctly: drags apply on top, uninstall restores the original.

**Dependencies:** floor raised to `OCCTSwiftTools` ≥ 0.3.0 (transitively `OCCTSwiftViewport` ≥ 0.52.0, `OCCTSwift` ≥ 0.168.0).

**Tests:** 5 new (`t_arrowsAreOverlayLayer`, `t_arrowsAreWidgetPickLayer`, `t_dragUpdatesTargetBodyTransformLive`, `t_uninstall_restoresTargetBodyTransform`, `t_install_capturesPreExistingTargetTransform`). Total: 56 across 5 suites.

## v0.2.0 — 2026-05-03

Translate manipulator widget — the data + math layer of SPEC.md §"Manipulator widget". `ManipulatorWidget` ships an axis-arrow gizmo for translating an `InteractiveObject`: install adds three colored arrow bodies to the scene, hit-test maps an NDC click to the picked axis (or `nil`), drag math projects the pick ray onto the axis line via closest-point-between-two-lines, with optional snap-to-step. Callbacks (`onChange` / `onCommit`) report the running and committed `simd_float4x4`.

**New public API:**

- `final class ManipulatorWidget: ObservableObject` (`@MainActor`) — `init(target:mode:)`, `install(in:)`, `uninstall()`, `hitTest(ndc:camera:aspect:)`, `beginDrag(axis:ndc:camera:aspect:)`, `updateDrag(ndc:camera:aspect:)`, `endDrag(commit:)`, `reset()`. Configurables: `size`, `shaftRadius`, `hitNDCTolerance`, `snapTranslate`, `snapRotateDeg`. Observable: `transform`, `isInstalled`, `activeAxis`. Callbacks: `onChange`, `onCommit`.
- `enum ManipulatorWidget.Mode` — `.translate` (live), `.rotate` / `.scale` (placeholders for v0.3+).
- `enum ManipulatorWidget.Axis` — `.x` / `.y` / `.z` with `direction` and `color` accessors.

**Wiring pattern (NDC + camera state in, transform out — gestures owned by the caller):**

```swift
let widget = ManipulatorWidget(target: obj)
widget.snapTranslate = 0.25
widget.install(in: ais)

// In your gesture handler:
let ndc = ndcFromTouchPoint(...)
if !widget.isDragging,
   let axis = widget.hitTest(ndc: ndc, camera: ais.viewport.cameraState, aspect: ais.viewport.lastAspectRatio) {
    widget.beginDrag(axis: axis, ndc: ndc, camera: ais.viewport.cameraState, aspect: ais.viewport.lastAspectRatio)
}
widget.updateDrag(ndc: ndc, camera: ais.viewport.cameraState, aspect: ais.viewport.lastAspectRatio)
// On gesture end:
widget.endDrag(commit: true)
```

**Behaviour:**

- Widget bodies are tagged `ais.widget.<UUID>.<x|y|z>`. They appear in `bodies` like any other geometry but are excluded from the user selection stream automatically — `InteractiveContext.handlePick` only registers picks for bodies that came through `display(_:)`.
- During drag, the running transform is applied to the gizmo arrows so the user sees their input. The target body is **not** moved — the renderer doesn't yet expose a per-body transform; consumers should apply the committed transform to the underlying `Shape` themselves on `onCommit`. See [OCCTSwiftViewport#23](https://github.com/gsdali/OCCTSwiftViewport/issues/23) for the renderer-side work that will eventually unlock live target updates plus on-top arrow rendering and a native widget-pick layer.
- `mode = .rotate` / `.scale` are accepted by `init` for forward compatibility but currently render translate handles only. Real rotate handles ship in v0.3 alongside edge / vertex selection.

**Internal additions on `InteractiveContext`** (used by manipulators and future internal subsystems):

- `bodyID(for:)`, `sourceBody(for:)`, `appendInternalBody(_:)`, `removeInternalBodies(where:)`. Internal access only — these are not part of the public API surface.

**Tests:** 14 new in `ManipulatorWidget` suite. Total: 51 across 5 suites. Hit-test, drag projection, snap-to-step, gizmo follows transform, callbacks fire, widget bodies don't pollute user picks.

**Dependencies:** unchanged (`OCCTSwiftTools` ≥ 0.1.0).

## v0.1.0 — 2026-05-03

Initial release. Selection-from-topology lands as the headline feature: GPU pick → `(bodyIndex, triangleIndex)` from OCCTSwiftViewport is mapped, via OCCTSwiftTools-supplied `CADBodyMetadata.faceIndices`, to a `TopoDS_Face` handle inside the displayed `Shape`. The cheap-route highlight overlay from SPEC.md §"Hover / highlight rendering" is implemented — selected faces render as a separate sub-mesh `ViewportBody`, vertices pushed along their normal by `0.0005 × bbox-diagonal` to win the depth fight, in `HighlightStyle.selectionColor`.

**Public API** (see [SPEC.md](../SPEC.md) §"Public API target shape" for the v0.x → v1.0 trajectory):

- `final class InteractiveContext: ObservableObject` (`@MainActor`) — `init(viewport:)`, `display(_:style:)`, `remove(_:)`, `removeAll()`, `select(_:)`, `deselect(_:)`, `clearSelection()`, `setStyle(_:for:)`, `setHighlightStyle(_:)`. Observable: `bodies` (bind to `MetalViewportView`), `selection`, `hover`, `selectionMode`.
- `struct InteractiveObject: Hashable, Sendable` — UUID-identity scene handle wrapping a `Shape`.
- `enum SubShape: Hashable, Sendable` — `.body`, `.face(_, faceIndex:)`, `.edge(_, edgeIndex:)`, `.vertex(_, vertexIndex:)`.
- `struct Selection: Hashable, Sendable` — set of `SubShape`s with derived `bodies`, `faces`, `edges`.
- `enum SelectionMode: Hashable, Sendable` — `.body`, `.face`, `.edge`, `.vertex`.
- `struct PresentationStyle: Sendable, Equatable` — `color`, `transparency`, `displayMode`, `visible`, plus `.default` / `.ghosted` / `.highlighted` / `.hovered` presets.
- `struct HighlightStyle: Sendable, Equatable` — `selectionColor`, `hoverColor`, `outlineWidth`, plus `.default`.
- `enum DisplayMode: Hashable, Sendable` — `.shaded`, `.wireframe`, `.shadedWithEdges`.

**Behaviour:**
- A pick event from the viewport **replaces** the current selection with the picked sub-shape; `select(_:)` / `deselect(_:)` are additive (`Set` semantics, idempotent).
- Changing `selectionMode` clears the current selection.
- Body-level selection routes to `viewport.selectedBodyIDs` so the renderer's built-in body highlight applies; face-level selection produces overlay bodies tagged `ais.overlay.sel.<UUID>` and kept at the trailing end of `bodies` so subsequently displayed bodies don't render in front of them.
- Empty-space picks (`pickResult == nil`) leave the selection unchanged.

**Scope (matching SPEC.md §"Sequencing"):** body + face selection only. Edge / vertex selection deferred to v0.3 (requires `edgeIndices` / `vertexIndices` buffers in OCCTSwiftViewport's `ViewportBody`). Manipulator widget deferred to v0.2. Dimensions deferred to v0.4+.

**Known limitations:**
- Face-level *hover* is not surfaced — OCCTSwiftViewport currently publishes only `hoveredBodyID`. Body-level hover works.
- Highlight overlay uses normal-offset to fight the depth test; minor flicker at silhouette edges is possible (acknowledged in SPEC §"Hover / highlight rendering"). The renderer-backed overlay path is scheduled for v0.6.
- Selection survival across `Shape` mutation is not implemented — sub-shape indices are valid only while the underlying `Shape` is unchanged. History-based remap is scheduled for v0.4+.

**Dependencies:** `OCCTSwiftTools` ≥ 0.1.0 (transitively pulls `OCCTSwift` 0.167.0 and `OCCTSwiftViewport` 0.51.0).

**Tests:** 37 across 4 suites (`SubShape`, `Selection`, `InteractiveContext`, `HighlightOverlay`). Run with `OCCT_SERIAL=1 swift test --parallel --num-workers 1`.
