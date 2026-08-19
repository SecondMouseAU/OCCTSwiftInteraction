# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**The merge of three former repositories**: `OCCTSwiftTools`, `OCCTSwiftAIS` and `OCCTSwiftCADKit`
(ecosystem#42). Each is still its own SwiftPM target:

```
Sources/OCCTSwiftTools     Tests/OCCTSwiftToolsTests
Sources/OCCTSwiftAIS       Tests/OCCTSwiftAISTests
Sources/OCCTSwiftCADKit    Tests/OCCTSwiftCADKitTests
```

Module names are unchanged, so consumers keep their existing `import` lines and changed only the
package reference in their manifests. See [docs/MIGRATION.md](docs/MIGRATION.md).

Version line starts at `0.x`, reaching `1.0.0` once the picking consolidation (ecosystem#43) has
landed and settled. The three old version lines do not continue here.

## Layering, and the one rule that matters

```
OCCTSwiftCADKit    assembled SwiftUI CAD viewport service: import, picking, clipping, camera
      ↑
OCCTSwiftAIS       interactive services: selection state, modes, schemes, filters, area
                   selection, manipulator widgets, dimensions. Modeled on OCCT's own AIS_*
      ↑
OCCTSwiftTools     kernel-to-renderer bridge: Shape into ViewportBody with picking metadata,
                   plus Face/Edge/VertexIdentityTables. NO UI framework
      ↑        ↑
OCCTSwift    OCCTSwiftViewport
(B-Rep)      (Metal renderer, deliberately OCCT-free)
```

Direction is enforced by target dependencies, so the compiler checks it exactly as strictly as it
did when these were three packages. Never point a dependency back down.

**`OCCTSwiftTools` must not gain a UI framework import.** Headless consumers (OCCTSwiftScripts,
OCCTMCP) depend on that product alone, and SwiftPM compiles only the targets reachable from the
products a consumer names. Adding SwiftUI to `OCCTSwiftTools` would cost every headless build. This
is the property that made merging these three safe; it is worth not breaking.

Equally: do not add OCCT-aware code to `OCCTSwiftViewport`, and do not add Metal or rendering code
to `OCCTSwift`. Both belong here.

**`ViewportBody.faceIndices` (per-triangle source-face index) is load-bearing.** The `OCCTSwiftAIS`
target reads it to map GPU pick results back to `TopoDS_Face` instances, and
`CADBodyMetadata.faceIndices` mirrors it. The contract is `indices.count / 3 == faceIndices.count`,
one face index per triangle. Changing either side needs the other changed with it, which is now a
same-repo change rather than a cross-repo one.

## Build and test

```bash
swift build
OCCT_SERIAL=1 swift test --parallel --num-workers 1   # MUST run serially
swift test --filter OCCTSwiftAISTests                 # one target
```

`OCCT_SERIAL=1` with serial workers is **required**, not optional: there is a known NCollection
container-overflow race in OCCT on arm64 macOS that segfaults parallel test runs. Inherited from
OCCTSwift; do not "fix" it by re-enabling parallelism.

`swift build` does **not** compile test targets. Use `swift build --build-tests` or `swift test`
before concluding anything compiles. This is not pedantry: during the OCCTSwift v3.0.0 fanout,
OCCTSwiftIO built clean with zero errors while carrying three real breaks in its test target.

Dependencies resolve against local siblings when present (`../OCCTSwift` and friends), else the
published URLs. No binary lives in this repo.

**Expected baseline: 360 tests across 32 suites, all passing.**

## Face identity is `IsSame`, and that decision is settled

Phase 0 of ecosystem#43, decided in
[OCCTSwiftInteraction#1](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/1). Do not
re-open it; encode it.

Face identity keys on OCCT's `TopoDS_Shape::IsSame`: same `TShape`, same `Location`, orientation may
differ. Consequences, all settled:

- `faces()`, deduplicated through `TopTools_IndexedMapOfShape`, is the correct enumeration for
  `FaceIdentityTable`. `orientedFaces()` is the occurrence enumeration and is not an identity.
- A face shared between two shells is **one** identity, not two. That it bounds two solids is a fact
  about the model, not two selectable things.
- A caller needing to know *which* use of a shared face was picked reads orientation off the
  returned shape, which is OCCT's own answer, not a second enumeration.

The mesher still walks face **occurrences**, so a shared face is tessellated once per owning shell
and both triangulations carry the one deduplicated ordinal. `InteractiveContextMutationTests`
holds that down: it asserts both shells' copies reach the mesh and that picks into either resolve to
the same durable uid. If you change the tessellation or identity path, that test is the tripwire.

## One pick resolver, and where its neighbours belong

Phase 2 of ecosystem#43, done in
[OCCTSwiftInteraction#2](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/2).

`OCCTSwiftTools.SubShapePickResolver` is the only place a render-path ordinal becomes a
`SubShapeRef`. Both this repo's own targets call it; do not write a fourth copy. `SubShapeRef`,
`SubShape` and `InteractiveObject` live in `OCCTSwiftTools` for the same reason, with
source-compatible typealiases left in `OCCTSwiftAIS`.

Three behaviours look like the resolver's job and are not, so they stayed where they were:

- **Clip-plane awareness** is `OCCTSwiftCADKit`'s, a caller-side pre-filter. Clip planes are the
  viewport service's state; the bridge target has no business knowing about them.
- **Geometry enrichment** (curve type, area, z-level, description) is presentation and lives above.
- **The whole-body fallback** is a selection-mode decision and lives in `OCCTSwiftAIS`.

Pulling any of them down would drag presentation and viewport state into the bridge layer, which is
the thing this consolidation exists to prevent.

## One identity-table builder, and identity comes back from the load

[OCCTSwiftInteraction#7](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/7), the layer
below phase 2.

`OCCTSwiftTools.ShapeIdentity` is the only place a `Shape` becomes `FaceIdentityTable` /
`EdgeIdentityTable` / `VertexIdentityTable`. There were three copies before: this package's private
helpers, `CADViewportService`'s statics, and OCCTSwiftUX's. Do not write a fourth.

- **`ShapeIdentity(shape:graph:)`** uses a graph you already hold. `graph: nil` still means
  "tables without durable uids", which is the mode `shapeToBodyMetadataAndIdentities(graph:)` has
  always offered.
- **`ShapeIdentity(shape:)`** mints its own graph. This is the convenience CADKit and UX each
  hand-rolled.

**After a file load, ask the loader, do not rebuild.** `CADFileLoader.load(from:format:
includeIdentity: true)` fills `CADLoadResult.identity`, keyed by `ViewportBody.id`.

**`CADLoadResult.shapes` must never be paired positionally with `.bodies`.** The STL/IGES robust
reload appends a shape even when that input produced no body, so every later pairing shifts and a
body gets another body's geometry. Consumers used to detect the resulting count mismatch and drop
identity wholesale; the loader now keys identity by body id inside the branch that creates each
body, so there is nothing to pair and nothing to guard. `CADFileLoaderIdentityTests` holds this
down by geometry, not by index, and it was mutation-checked.

**Identity is off by default and should stay that way.** `BRepGraph.init` serialises the whole
shape to a BREP string: measured at 5.0ms against a 14-face solid whose mesh takes 9.6ms. Headless
consumers of `load` (OCCTDesignLoop's reprojection, batch render and parts extraction) never pick.

**A table's index space is the ordinal space, and that is load-bearing**
([#9](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/9)). Ordinals index the *full*
enumeration, because that is what the mesher walks, so the face and edge tables are built with
`map`, never `compactMap`: a dropped element moves every later ordinal down one and the table then
names the sub-shape after the one the pick hit, silently. That is why `FaceIdentityTable.shapes` and
`EdgeIdentityTable.shapes` are `[Shape?]`. `VertexIdentityTable.shapes` is `[Shape]` because
`subShapes(ofType: .vertex)` needs no failable conversion; keep that asymmetry, in both directions.

The bridge's edge-polyline-only branch (`mesh(...)` returned nil) used to substitute an empty
`FaceIdentityTable` and now builds the ordinary one. It is reachable from tests only through the
internal `edgePolylineOnlyBridge` seam, because a wire, an edge and a lone vertex all mesh to an
empty `Mesh` rather than to nil. `ShapeIdentity.init` has an internal seam of the same kind, taking
the two sub-shape conversions as parameters, because no public API can make one of them fail.

## One selection, held by `InteractiveContext`

Phase 3 of ecosystem#43, done in
[OCCTSwiftInteraction#3](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/3).

`OCCTSwiftAIS.InteractiveContext.selection` is the only selection store in this package.
`OCCTSwiftCADKit.CADViewportService` used to keep a second one alongside the context it already
owned; it now drives that one and projects it:

- `CADViewportService.selection` is `interactiveContext.selection` enriched into `PickedEntity`
  values. Mirrored into stored state so SwiftUI observation fires, exactly as `bodies` mirrors
  `interactiveContext.bodies`. Ordered by (body id, kind, ordinal), since the store is a `Set`.
- `CADViewportService.selectionModes` **is** `interactiveContext.selectionMode`, not a copy.
  Initialised to `[.face]` at `init`, overriding the context's `[.body]` default.
- `select`, `clearSelection` and the selection pruning inside `remove`/`removeAll` all go
  through the context.

`InteractiveContext.select(_:scheme:)` gained the four-scheme parameter from CADKit's version.
`select(_:)` is untouched and still means `.add`; the scheme parameter is deliberately not
defaulted, because a default would silently retune every existing call site to `.replace`.

What did **not** merge, and why:

- **`PickedFaceInfo`/`PickedEdgeInfo`/`PickedVertexInfo` survive** as presentation types, now
  storing a `SubShapeRef` and forwarding `shape`/`uid`/`ordinal` to it. Two of their fields
  (`scalarValue` for a per-triangle field, `description`) cannot be recovered from a ref after
  the fact.
- **The highlight systems stay separate.** AIS paints `triangleStyles`; CADKit builds aggregate
  highlight bodies. CADKit already uses `triangleStyles` for scalar fields, so they would
  overwrite each other. That is also why CADKit's bodies are not registered as context entries.
- **The clip-plane pre-filter stays in CADKit.** It tests the picked primitive's position, which
  an AIS `SelectionFilter` (which sees a resolved `SubShape`) cannot express.
- **`Axis` in both targets was never a collision**: AIS's is nested inside `ManipulatorWidget`.
- **`SelectionSummary` was never a duplicate of OCCTSwiftUX's.** Different fields, different
  inputs, no shared consumer, and OCCTSwiftUX does not depend on this package at all. Resolved
  by naming: CADKit's is now `SelectionMeasurements`, with a deprecated alias.

`ComesFromDecomposition` is settled and is **not** going on `SubShapeRef`: `SubShape` is a sum
type, so `ref == nil` already is "whole body", and the resolver can never mint a whole-body ref.

## Where things are

Each module kept its own documentation through the merge rather than having it collapsed:

| | Tools | AIS | CADKit |
|---|---|---|---|
| Spec | [docs/spec/OCCTSwiftTools.md](docs/spec/OCCTSwiftTools.md) | [docs/spec/OCCTSwiftAIS.md](docs/spec/OCCTSwiftAIS.md) | none |
| Getting started | none | [guide](docs/guides/getting-started-OCCTSwiftAIS.md) | [guide](docs/guides/getting-started-OCCTSwiftCADKit.md) |
| Module notes | this file | [docs/module-notes/OCCTSwiftAIS.md](docs/module-notes/OCCTSwiftAIS.md) | [docs/module-notes/OCCTSwiftCADKit.md](docs/module-notes/OCCTSwiftCADKit.md) |
| okf component | [okf/components/OCCTSwiftTools.md](okf/components/OCCTSwiftTools.md) | [okf/components/OCCTSwiftAIS.md](okf/components/OCCTSwiftAIS.md) | [okf/components/OCCTSwiftCADKit.md](okf/components/OCCTSwiftCADKit.md) |
| Changelog | [docs/CHANGELOG-OCCTSwiftTools.md](docs/CHANGELOG-OCCTSwiftTools.md) | [docs/CHANGELOG-OCCTSwiftAIS.md](docs/CHANGELOG-OCCTSwiftAIS.md) | [docs/CHANGELOG-OCCTSwiftCADKit.md](docs/CHANGELOG-OCCTSwiftCADKit.md) |

`docs/module-notes/*.md` are the pre-merge `CLAUDE.md` files kept verbatim. They still speak as
though their module is its own repository; read them for module-specific traps, not for repo layout.

Per-type reference for all three targets is in [docs/reference/](docs/reference/).

## Conventions

- **License**: LGPL 2.1 with `OCCT_LGPL_EXCEPTION`, matching OCCT itself.
- **Swift**: tools-version 6.1, language mode `.v6`.
- **Tests**: Swift Testing (`@Suite` / `@Test` / `#expect`). Swift Testing does **not**
  short-circuit, so never write `#expect(x != nil); #expect(x!.isValid)`. Use `if let x { ... }`.
- **Test names must not shadow API method names** used in the test body; the runner gets confused.
  Prefix `t_` or use descriptive English.
- **No em-dashes** anywhere in code comments, commit messages, PR text or docs. Use commas, colons
  or parentheses. Banned words in prose: "honest", "honestly", "you're right".
- **CODE_OF_CONDUCT.md**: a short pointer to Contributor Covenant 2.1 only. Never inline the full
  Covenant text.
- **Release pattern**: commit, push, tag, and create a GitHub release with notes.

## Still to finish after the merge

- `okf/index.md` describes the OCCTSwiftTools half in more detail than the other two.
- The CADKit target's `visionOS`/`tvOS` build is unverified. `Package.swift` keeps the union of what
  the three declared, and CADKit declared only iOS and macOS. Confirm or narrow before 1.0.0.

## Ecosystem context worth reading before non-trivial changes

- `~/Projects/OCCTSwift/CLAUDE.md`, kernel project conventions that this repo follows
- `~/Projects/OCCTSwift/docs/visualization-research.md`, why the layer cake exists
- `~/Projects/ecosystem/okf/`, the shared policy set
