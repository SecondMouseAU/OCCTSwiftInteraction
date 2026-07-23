# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Swift Package extracted from PadCAM's CAD viewport plumbing. It owns: a Metal 3D viewport, file import (STEP/STL/BREP via `OCCTSwiftTools.CADFileLoader`), face picking, and a generic overlay-layers API for caller-supplied bodies (stock boxes, toolpaths, flat patterns, etc.). Designed to be shared by PadCAM and a forthcoming UnfoldEngine test app.

Tiny by design: 5 files in `Sources/OCCTSwiftCADKit/`. If a piece of code starts to know about CAM, sheet metal, or any specific application domain, it doesn't belong here.

## Build & test

```bash
swift build
swift test
```

Tests use Swift Testing (`@Suite` / `@Test`). Filter to a suite or single test with:

```bash
swift test --filter SmokeTests
swift test --filter SmokeTests.pickedFaceInfoEquality
```

Targets: macOS 15+ / iOS 18+ (set by `OCCTSwiftViewport`'s Metal requirements, not by anything here). Both targets are pinned to `.swiftLanguageMode(.v6)` in `Package.swift` — that's why `CADViewportService` is `@MainActor`-isolated and the public value types are `Sendable`. Don't relax this when adding new targets.

## Dependency wiring (important)

`Package.swift` consumes four sibling repos as **URL-based SPM dependencies**:

- `OCCTSwift` (geometry kernel; ships a binary `OCCT.xcframework` via its own release artefact — fetched transparently)
- `OCCTSwiftViewport` (Metal renderer)
- `OCCTSwiftTools` (`CADFileLoader`, `CADBodyMetadata`, `BodyUtilities`, `CADFileFormat`, `FaceIdentityTable`/`EdgeIdentityTable`/`VertexIdentityTable`)
- `OCCTSwiftAIS` (`InteractiveContext`, `ManipulatorWidget`, `Dimension`, sub-shape selection — exposed via `service.interactiveContext`; `SelectionMode` also backs `CADViewportService.selectionModes`)

`OCCTSwiftTools` used to live as a target inside `OCCTSwiftViewport`. It was split into its own repo (https://github.com/SecondMouseAU/OCCTSwiftTools) as of `OCCTSwiftViewport 0.51.0` and must now be sourced from its own package — don't try to pull the `OCCTSwiftTools` product from the Viewport package, it's no longer there.

URL-based deps are the preferred form. If you hit a version-resolution problem you need to debug locally, you can temporarily point `Package.swift` at sibling working trees (`.package(path: "../OCCTSwiftTools")` etc.) — but commits should always land with URL-based deps.

## API design rules

- **No domain leaks.** This library knows about loading shapes, displaying them, and picking faces. It does not know about toolpaths, stock, sheet metal, bend allowance, machining origins, or anything specific to one app. App-specific geometry rides as overlay layers (`setOverlay(id:bodies:)`).
- **`PickedFaceInfo` must stay self-contained.** It originally referenced PadCAM's `DetectedSurface.SurfaceBounds`; that was replaced with a local `FaceBounds`. Don't reintroduce dependencies on caller types.
- **The viewport API mirrors the underscored `OCCTSwiftViewport` aliases.** `_ViewportController`, `_ViewportBody`, `_PickResult`, `_ViewportConfiguration`, `_PickingConfiguration`, `_MetalViewportView` — these are the public typealiases the upstream package exposes. Use them in public surfaces (so callers don't need to import the un-aliased namespace).

## Architecture in one paragraph

`CADViewportService` is `@MainActor @Observable`. It owns a `_ViewportController` and an `InteractiveContext` (shared viewport — `interactiveContext.viewport === controller`). Bodies live in `interactiveContext.bodies` (single source of truth, the array that `_MetalViewportView` actually renders); the service mirrors them into its own `bodies` for `@Observable` consumers via a Combine `$bodies` sink. The service composes four kinds of body into that single array: (1) **model bodies** from the most recent `loadFile`/`loadShape`/`loadFromData`, (2) **overlay layers** added by callers via `setOverlay`, sorted alphabetically by id, (3) the **selection highlight** built when picking succeeds — a translucent triangle patch for a face pick, a bright polyline for an edge pick, a point sprite for a vertex pick, (4) **AIS-owned bodies** appended by `interactiveContext.display(_:)` / `appendInternalBody(_:)` (manipulator handles, dimensions). On rebuild, the service tracks the set of CADKit-owned ids and only replaces those — AIS-owned bodies are left untouched. The controller's `onPick` callback dispatches a `_PickResult` on its `kind` (face/edge/vertex, gated by `selectionModes`) to a per-kind resolver, which maps the render-path ordinal to durable identity (a `Shape` + optional `BRepGraph.GraphUID`) via the picked body's `FaceIdentityTable`/`EdgeIdentityTable`/`VertexIdentityTable` — one graph + table set per loaded body, retained for the body's lifetime — and emits a `PickedEntity`; `InteractiveContext` separately observes `viewport.$pickResult` for AIS-side selection (a distinct, independent selection system CADKit does not share state with).

## Things to be careful about

- **`PadCAMEngineOCCT` import has been removed.** The original PadCAM service exposed an `OCCTGeometrySource` from the engine package; consumers that need one should construct it themselves from `loadedShape`. Don't add `PadCAMEngine`/`PadCAMEngineOCCT` back as a dependency — that's the kind of domain leak this package exists to avoid.
- **`generateLegacyMesh()` was dropped.** It returned a CAM-specific `GeometryModel` for the SceneKit-based `ScenePreviewView`. If a consumer needs raw triangle data, expose a generic mesh accessor — don't reintroduce CAM types.
- **Stock display and toolpath display were dropped.** They live behind the `setOverlay(id:bodies:)` API now. Anything that's adding domain-specific methods (`setStock`, `setToolpath`, `setFlatPattern`) should be doing it in the consuming app, not here.
- **Don't write to `service.bodies` directly.** It's `private(set)` for a reason — it's a Combine-mirrored read-only view of `interactiveContext.bodies`. Mutations go through `setOverlay`/`clearOverlay` (CADKit-owned) or through `interactiveContext.display(_:)`/`appendInternalBody(_:)` (AIS-owned). The `rebuildBodies()` merge protocol depends on each writer staying in its lane.

## Files

- `Sources/OCCTSwiftCADKit/CADViewportService.swift` — the service
- `Sources/OCCTSwiftCADKit/CADViewportView.swift` — SwiftUI wrapper
- `Sources/OCCTSwiftCADKit/PickedFaceInfo.swift` — `PickedFaceInfo` and `FaceBounds` (the local face-bounds type that replaced PadCAM's `DetectedSurface.SurfaceBounds` — keep it here)
- `Sources/OCCTSwiftCADKit/PickedEntity.swift` — `PickedEntity` (the face/edge/vertex pick union), `PickedEdgeInfo`, `PickedVertexInfo`
- `Sources/OCCTSwiftCADKit/CADViewportError.swift` — error type
- `Tests/OCCTSwiftCADKitTests/SmokeTests.swift` — value-type smoke tests (no viewport I/O)
