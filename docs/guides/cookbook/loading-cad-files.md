---
title: Loading a CAD file
parent: Cookbook
nav_order: 4
---

# Loading a CAD file

`CADFileLoader` wraps OCCTSwiftIO's headless `ShapeLoader` and bridges every
loaded shape to a `ViewportBody` plus `CADBodyMetadata`. The result is a
`CADLoadResult` carrying the renderable bodies, per-body selection metadata, the
raw `Shape`s, and any PMI (dimensions, geometric tolerances, datums) the file
format surfaces.

```swift
import Foundation
import OCCTSwiftTools

let url = URL(fileURLWithPath: "/path/to/bracket.step")

let result = try await CADFileLoader.load(from: url, format: .step)

for body in result.bodies {
    // hand each body to the viewport
}
let shapes = result.shapes          // raw OCCTSwift shapes
let pmi    = result.dimensions      // [Document.Dimension], if the format carries PMI
```

`load` is `async throws` because STEP and IGES imports can be long-running.

## Progress and cancellation

Pass an `ImportProgress` observer to track or cancel an import. Progress is
honoured by the `.step` and `.iges` loaders only — STL / OBJ / BREP are
single-call upstream and don't report progress. If your observer's
`shouldCancel()` returns `true`, the import throws
`OCCTSwift.ImportError.cancelled`.

```swift
let result = try await CADFileLoader.load(
    from: url,
    format: .iges,
    progress: myProgressObserver
)
```

## Robust fallback for STL and IGES

STL and IGES files frequently arrive with gaps that OCCT's basic importer can't
close, so the primary bridge can fail. `CADFileLoader` detects this and
transparently re-loads via the sewing/healing variants
(`Shape.loadSTLRobust` / `Shape.loadIGESRobust`). STEP, OBJ, and BREP have no
fallback — their primary loader is the only path. You don't call anything extra;
the fallback is automatic.

## Loading from a script manifest

If your bodies were produced by a script run (a `manifest.json` plus BREP
files), use `loadFromManifest`. It is synchronous and reads the BREP files
referenced by the manifest, applying each body's recorded colour:

```swift
let manifestURL = URL(fileURLWithPath: "/path/to/output/manifest.json")
let result = try CADFileLoader.loadFromManifest(at: manifestURL)
```

For headless, shape-only work with no Viewport dependency, skip this package and
use `OCCTSwiftIO.ShapeLoader.load` / `ShapeLoadResult` directly — `CADFileLoader`
exists specifically to add the `ViewportBody` bridge on top.
