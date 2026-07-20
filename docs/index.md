---
title: Home
nav_order: 1
---

# OCCTSwiftTools

**OCCTSwiftTools** is the bridge layer of the OCCTSwift ecosystem. It turns
OCCTSwift kernel objects — `Shape`, `Curve2D` / `Curve3D`, `Surface`, `Wire` —
and raw point clouds into the `ViewportBody` values that the OCCTSwiftViewport
Metal renderer draws, and it wraps OCCTSwiftIO's headless `ShapeLoader` so a CAD
file on disk arrives as renderable, pickable bodies.

It sits in the middle of the layered stack:

```
OCCTSwiftAIS          (selection / manipulators / dimensions)
       ↑
OCCTSwiftTools        ← this package: the Shape ↔ ViewportBody bridge
       ↑      ↑
OCCTSwift   OCCTSwiftViewport
(B-Rep)     (Metal renderer)
```

OCCTSwiftTools is the only repo that depends on **both** sibling kernels, which
keeps OCCTSwift and OCCTSwiftViewport decoupled from each other. The public API
is a handful of namespacing enums of `static func`s plus one result struct — no
instances to manage, just `Input → ViewportBody`.

```swift
import OCCTSwift
import OCCTSwiftTools

// Turn an OCCTSwift Shape into a renderable, pickable ViewportBody.
let box = Shape.box(width: 10, height: 5, depth: 3)!
let (body, metadata) = CADFileLoader.shapeToBodyAndMetadata(
    box, id: "box", color: SIMD4<Float>(0.6, 0.6, 0.65, 1.0)
)
// `body` carries the triangulated mesh + wireframe edges + pick data;
// `metadata` carries face indices, edge polylines, and source vertices.
```

## Cookbook

Task-oriented recipes, each runnable against the real API:

- [Shape to ViewportBody](guides/cookbook/shape-to-body) — mesh + picking metadata for a solid
- [Point clouds](guides/cookbook/point-clouds) — render tens of thousands of points via `PointConverter`
- [Curves, surfaces, and wires](guides/cookbook/curves-surfaces-wires) — edge-only and isoparametric-grid bodies
- [Loading a CAD file](guides/cookbook/loading-cad-files) — `CADFileLoader.load` over STEP / IGES / STL / OBJ / BREP

## Reference

Per-type API reference for every public symbol:

- [API Reference](reference/) — `PointConverter`, `CurveConverter`, `SurfaceConverter`, `WireConverter`, `BodyUtilities`, `CADFileLoader`, `FaceIdentityTable`, `EdgeIdentityTable`, `VertexIdentityTable`

## Project

Add OCCTSwiftTools to your `Package.swift`:

```swift
.package(url: "https://github.com/SecondMouseAU/OCCTSwiftTools.git", from: "1.6.0"),
```

Then declare it as a dependency of your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "OCCTSwiftTools", package: "OCCTSwiftTools")
    ]
)
```

- Source: [github.com/SecondMouseAU/OCCTSwiftTools](https://github.com/SecondMouseAU/OCCTSwiftTools)
- License: LGPL 2.1 (matching OCCT)
- Platforms: macOS 15+, iOS 18+, visionOS 1+, tvOS 18+ (arm64)
