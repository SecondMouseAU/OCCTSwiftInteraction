---
title: API Reference
nav_order: 3
has_children: true
---

# API Reference

The complete public surface of OCCTSwiftTools. Every converter is a `public
enum` used as a namespace of `static func`s — there are no instances to
construct. Most converters take an OCCTSwift kernel type (or a raw point list)
and return one or more `ViewportBody` values; `CADFileLoader` additionally wraps
OCCTSwiftIO's `ShapeLoader` and returns a `CADLoadResult`.

Add the package and import it:

```swift
import OCCTSwiftTools
```

Per-type pages:

- [PointConverter](PointConverter) — raw point clouds → point-sprite `ViewportBody`
- [CurveConverter](CurveConverter) — `Curve2D` / `Curve3D` → edge-only `ViewportBody`
- [SurfaceConverter](SurfaceConverter) — `Surface` → U/V isoparametric grid bodies
- [WireConverter](WireConverter) — `Wire` → edge-only `ViewportBody`
- [BodyUtilities](BodyUtilities) — marker spheres and offset helpers for `ViewportBody`
- [CADFileLoader](CADFileLoader) — load CAD files / manifests, and the `Shape` → body bridge
- [FaceIdentityTable](FaceIdentityTable) / [EdgeIdentityTable](EdgeIdentityTable) / [VertexIdentityTable](VertexIdentityTable): resolve a render-path face / edge / vertex ordinal back to its `Shape` and durable `GraphUID`
