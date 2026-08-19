---
title: Standard objects
parent: Cookbook
nav_order: 6
---

# Standard scene objects

Standard objects are non-selectable visual aids: world axes, work planes, reference lines, and point
clouds. Each builds its `ViewportBody` instances via `makeBodies()`, which you append to
`InteractiveContext.bodies`. They ride the user-geometry pick layer but imply no `display(_:)`
registration, so picks on them produce no `Selection` updates.

Every type exposes an `ownsBody(id:)` predicate for cleanup.

## Trihedron

Three colored axis arrows (X red, Y green, Z blue) plus a small center sphere — the canonical world
axes affordance.

```swift
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftAIS

let ais = InteractiveContext(viewport: ViewportController())

let tri = Trihedron(at: .zero, axisLength: 5)
ais.bodies.append(contentsOf: tri.makeBodies())

// later — remove it:
ais.bodies.removeAll { tri.ownsBody(id: $0.id) }
```

`sphereRadius` and `arrowRadius` default to `axisLength * 0.05` / `0.025` and are mutable.

## Work plane

A flat semi-transparent rectangle in the plane perpendicular to `normal`. Doubles as the projection
plane for `LinearDimension`'s in-plane mode.

```swift
let plane = WorkPlane(
    origin: .zero,
    normal: SIMD3<Float>(0, 0, 1),
    size: 50,
    color: SIMD4<Float>(0.5, 0.6, 0.85, 0.25)
)
ais.bodies.append(contentsOf: plane.makeBodies())
```

## Axis

A thin cylinder between two world points — useful for marking rotation axes or datum lines.

```swift
let axis = Axis(
    from: .zero,
    to: SIMD3<Float>(10, 0, 0),
    color: SIMD3<Float>(1, 1, 0),   // yellow
    radius: 0.05
)
ais.bodies.append(contentsOf: axis.makeBodies())
```

## Point cloud

A set of points rendered as small spheres in a single body. All points share one color (the first
entry of `colors` if provided, otherwise `defaultColor`).

```swift
let cloud = PointCloudPresentation(
    points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1), SIMD3<Float>(2, 0, -1)],
    pointRadius: 0.08,
    defaultColor: SIMD4<Float>(1, 0.85, 0.2, 1)
)
ais.bodies.append(contentsOf: cloud.makeBodies())
```

`makeBodies()` returns an empty array for an empty `points` list.
