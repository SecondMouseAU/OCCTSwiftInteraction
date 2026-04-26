# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Swift Package extracted from PadCAM's CAD viewport plumbing. It owns: a Metal 3D viewport, file import (STEP/STL/BREP via `OCCTSwiftTools.CADFileLoader`), face picking, and a generic overlay-layers API for caller-supplied bodies (stock boxes, toolpaths, flat patterns, etc.). Designed to be shared by PadCAM and a forthcoming UnfoldEngine test app.

Tiny by design: 4 files in `Sources/OCCTSwiftCADKit/`. If a piece of code starts to know about CAM, sheet metal, or any specific application domain, it doesn't belong here.

## Build & test

```bash
swift build
swift test
```

Targets: macOS 15+ / iOS 18+ (set by `OCCTSwiftViewport`'s Metal requirements, not by anything here).

## Dependency wiring (important)

`Package.swift` consumes `OCCTSwift` and `OCCTSwiftViewport` via **sibling path packages** (`../OCCTSwift`, `../OCCTSwiftViewport`). Reasons:

1. `OCCTSwift` ships a binary `OCCT.xcframework` that SPM can't fetch from a private GitHub release without auth gymnastics — every consumer in this constellation (PadCAM, UnfoldEngine, this package) uses path-package mode.
2. `OCCTSwiftTools` (which provides `CADFileLoader`, `CADBodyMetadata`, `BodyUtilities`, `CADFileFormat`) is a target inside the `OCCTSwiftViewport` package. It is **not yet exported as a product on any published tag** — only the `main` branch of `OCCTSwiftViewport` exposes it as `.library(name: "OCCTSwiftTools", ...)`. Until OCCTSwiftViewport cuts a release that publishes that product, path-package consumption is the only option.

Switching to URL-based dependencies is the obvious cleanup once those upstream constraints lift. Don't do it preemptively — verify the published tag actually exports `OCCTSwiftTools` before changing `Package.swift`.

## API design rules

- **No domain leaks.** This library knows about loading shapes, displaying them, and picking faces. It does not know about toolpaths, stock, sheet metal, bend allowance, machining origins, or anything specific to one app. App-specific geometry rides as overlay layers (`setOverlay(id:bodies:)`).
- **`PickedFaceInfo` must stay self-contained.** It originally referenced PadCAM's `DetectedSurface.SurfaceBounds`; that was replaced with a local `FaceBounds`. Don't reintroduce dependencies on caller types.
- **The viewport API mirrors the underscored `OCCTSwiftViewport` aliases.** `_ViewportController`, `_ViewportBody`, `_PickResult`, `_ViewportConfiguration`, `_PickingConfiguration`, `_MetalViewportView` — these are the public typealiases the upstream package exposes. Use them in public surfaces (so callers don't need to import the un-aliased namespace).

## Architecture in one paragraph

`CADViewportService` is `@MainActor @Observable`. It composites three sources of `_ViewportBody`s into the controller's render list every time anything changes: (1) **model bodies** from the most recent `loadFile`/`loadShape`/`loadFromData`, (2) **overlay layers** added by callers via `setOverlay`, sorted alphabetically by id, (3) the **selection highlight** built from triangle-level metadata when picking succeeds. The controller's `onPick` callback resolves a `_PickResult` back to a face index using `CADBodyMetadata.faceIndices` (one entry per triangle), looks the OCCTSwift `Face` up, computes orientation/area/Z metadata, and emits a `PickedFaceInfo`.

## Things to be careful about

- **`PadCAMEngineOCCT` import has been removed.** The original PadCAM service exposed an `OCCTGeometrySource` from the engine package; consumers that need one should construct it themselves from `loadedShape`. Don't add `PadCAMEngine`/`PadCAMEngineOCCT` back as a dependency — that's the kind of domain leak this package exists to avoid.
- **`generateLegacyMesh()` was dropped.** It returned a CAM-specific `GeometryModel` for the SceneKit-based `ScenePreviewView`. If a consumer needs raw triangle data, expose a generic mesh accessor — don't reintroduce CAM types.
- **Stock display and toolpath display were dropped.** They live behind the `setOverlay(id:bodies:)` API now. Anything that's adding domain-specific methods (`setStock`, `setToolpath`, `setFlatPattern`) should be doing it in the consuming app, not here.

## Files

- `Sources/OCCTSwiftCADKit/CADViewportService.swift` — the service (one file, ~280 lines)
- `Sources/OCCTSwiftCADKit/CADViewportView.swift` — SwiftUI wrapper
- `Sources/OCCTSwiftCADKit/PickedFaceInfo.swift` — picking result types
- `Sources/OCCTSwiftCADKit/CADViewportError.swift` — error type
- `Tests/OCCTSwiftCADKitTests/SmokeTests.swift` — value-type smoke tests (no viewport I/O)
