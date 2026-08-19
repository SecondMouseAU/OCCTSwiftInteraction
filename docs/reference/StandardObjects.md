---
title: Standard Objects
parent: API Reference
---

# Standard Objects

Non-selectable visual aids. Each builds `ViewportBody` instances via `makeBodies()`, which the caller
appends to `InteractiveContext.bodies`. They imply no `display(_:)` registration, so picks on them
produce no `Selection` updates. Every type exposes an `ownsBody(id:)` predicate for cleanup.

## Topics

- [Trihedron](#trihedron) · [WorkPlane](#workplane) · [Axis](#axis) · [PointCloudPresentation](#pointcloudpresentation)

---

## Trihedron

Three colored axis arrows (X red, Y green, Z blue) plus a small center sphere.

```swift
public final class Trihedron: @unchecked Sendable {
    public let id: String
    public let origin: SIMD3<Float>
    public let axisLength: Float
    public var sphereRadius: Float       // default axisLength * 0.05
    public var arrowRadius: Float        // default axisLength * 0.025

    public init(at origin: SIMD3<Float>, axisLength: Float = 1.0, id: String? = nil)
    public func makeBodies() -> [ViewportBody]
    public func ownsBody(id bodyID: String) -> Bool
}
```

- **Parameters:** `origin` — world placement; `axisLength` — arrow length; `id` — defaults to a
  generated id.
- **Example:**

```swift
let tri = Trihedron(at: .zero, axisLength: 5)
ais.bodies.append(contentsOf: tri.makeBodies())
ais.bodies.removeAll { tri.ownsBody(id: $0.id) }   // cleanup
```

---

## WorkPlane

A flat semi-transparent rectangle in the plane perpendicular to `normal`. Also usable as the
projection plane for `LinearDimension`'s in-plane mode.

```swift
public final class WorkPlane: @unchecked Sendable {
    public let id: String
    public let origin: SIMD3<Float>
    public let normal: SIMD3<Float>      // stored normalized
    public let size: Float
    public var color: SIMD4<Float>

    public init(origin: SIMD3<Float>, normal: SIMD3<Float>,
                size: Float = 100,
                color: SIMD4<Float> = SIMD4<Float>(0.5, 0.6, 0.85, 0.25),
                id: String? = nil)
    public func makeBodies() -> [ViewportBody]
    public func ownsBody(id bodyID: String) -> Bool
}
```

- **Parameters:** `origin` / `normal` — plane placement; `size` — side length of the square; `color`
  — RGBA (default translucent blue).
- **Example:**

```swift
let plane = WorkPlane(origin: .zero, normal: SIMD3<Float>(0, 0, 1), size: 50)
ais.bodies.append(contentsOf: plane.makeBodies())
```

---

## Axis

A thin cylinder between two world points — a reference line (rotation axis, datum, etc.).

```swift
public final class Axis: @unchecked Sendable {
    public let id: String
    public let from: SIMD3<Float>
    public let to: SIMD3<Float>
    public let color: SIMD4<Float>       // stored opaque from the SIMD3 color
    public var radius: Float

    public init(from: SIMD3<Float>, to: SIMD3<Float>,
                color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                radius: Float = 0.02, id: String? = nil)
    public func makeBodies() -> [ViewportBody]
    public func ownsBody(id bodyID: String) -> Bool
}
```

- **Parameters:** `from` / `to` — endpoints; `color` — RGB; `radius` — cylinder radius.
- **Example:**

```swift
let axis = Axis(from: .zero, to: SIMD3<Float>(10, 0, 0),
                color: SIMD3<Float>(1, 1, 0), radius: 0.05)
ais.bodies.append(contentsOf: axis.makeBodies())
```

---

## PointCloudPresentation

A set of points rendered as small spheres in one body. All points share a single color — the first
entry of `colors` if provided, else `defaultColor`.

```swift
public final class PointCloudPresentation: @unchecked Sendable {
    public let id: String
    public let points: [SIMD3<Float>]
    public let colors: [SIMD3<Float>]?
    public var pointRadius: Float
    public var defaultColor: SIMD4<Float>

    public init(points: [SIMD3<Float>],
                colors: [SIMD3<Float>]? = nil,
                pointRadius: Float = 0.05,
                defaultColor: SIMD4<Float> = SIMD4<Float>(1, 0.85, 0.2, 1),
                id: String? = nil)
    public func makeBodies() -> [ViewportBody]      // [] for an empty points list
    public func ownsBody(id bodyID: String) -> Bool
}
```

- **Parameters:** `points` — world positions; `colors` — optional (only the first entry is used today);
  `pointRadius` — sphere radius; `defaultColor` — RGBA fallback.
- **Example:**

```swift
let cloud = PointCloudPresentation(
    points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1)],
    pointRadius: 0.08
)
ais.bodies.append(contentsOf: cloud.makeBodies())
```
