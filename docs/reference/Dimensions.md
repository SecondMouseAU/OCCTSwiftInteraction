---
title: Dimensions
parent: API Reference
---

# Dimensions

A `Dimension` is a labeled measurement anchored on `SubShape`s. Concrete types: `LinearDimension`,
`AngularDimension`, `RadialDimension`. Each emits a `ViewportMeasurement` consumed by
OCCTSwiftViewport's `MeasurementOverlay`. Add / remove them via `InteractiveContext.add(_:)` /
`remove(_:)`.

## Topics

- [Dimension](#dimension) · [LinearDimension](#lineardimension) · [AngularDimension](#angulardimension) · [RadialDimension](#radialdimension)

---

## Dimension

The protocol all dimension types conform to.

```swift
public protocol Dimension: AnyObject, Sendable {
    var id: String { get }
    var label: String { get }
    var anchorPoints: [SIMD3<Float>] { get }
    var viewportMeasurement: ViewportMeasurement { get }
}
```

- `id`: stable id tracked across add / remove cycles.
- `label`: human-readable text (e.g. `"5.32"`); customise via the initialiser's `customLabel`.
- `anchorPoints`: world-space anchors in the order the concrete type expects, or `[]` when any
  anchor fails to resolve.
- `viewportMeasurement`: the renderer-overlay form.

An anchor fails to resolve when the underlying geometry cannot supply a point: `Shape.bounds` and
`Face.bounds` are Optional (OCCTSwift 3.0.0), `Face(ref.shape)` / `Edge(ref.shape)` return nil for a
sub-shape of another kind, and `ref.shape.vertices()` can be empty. An unresolvable `LinearDimension`
or `AngularDimension` reports `anchorPoints == []`, a `nan` measurement, and a `"?"` label, and
`InteractiveContext.add(_:)` registers it without pushing a measurement to the overlay, so it draws
nothing rather than being drawn at the world origin. `refreshDimensionMeasurement(_:)` adds the
annotation once the anchors resolve and removes it if they stop.

`RadialDimension` keeps its own older contract: `[.zero, .zero]` rather than `[]` for a sub-shape
that is not a circular edge, so it is still drawn.

---

## LinearDimension

Distance between two anchors. An optional `WorkPlane` projects both anchors orthogonally before
measuring, giving the in-plane length.

```swift
public final class LinearDimension: Dimension, @unchecked Sendable {
    public let id: String
    public let from: SubShape
    public let to: SubShape
    public let plane: WorkPlane?
    public var customLabel: String?

    public init(from: SubShape, to: SubShape,
                plane: WorkPlane? = nil, customLabel: String? = nil, id: String? = nil)

    public var anchorPoints: [SIMD3<Float>] { get }   // [from, to] after optional projection; [] if unresolvable
    public var distance: Float { get }                // nan if an anchor fails to resolve
    public var label: String { get }                  // customLabel, else formatted distance
}
```

- **Parameters:** `from` / `to` — the two anchor sub-shapes; `plane` — optional projection plane;
  `customLabel` — overrides the formatted distance; `id` — defaults to a generated id.
- **Example:**

```swift
let v0 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 0)!, ordinal: 0)
let v6 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 6)!, ordinal: 6)
let lin = LinearDimension(from: .vertex(part, ref: v0), to: .vertex(part, ref: v6))
ais.add(lin)
print(lin.distance, lin.label)
```

---

## AngularDimension

Angle at the apex. Anchor order is `[armA, apex, armB]` (vertex in the middle).

```swift
public final class AngularDimension: Dimension, @unchecked Sendable {
    public let id: String
    public let armA: SubShape
    public let apex: SubShape
    public let armB: SubShape
    public var customLabel: String?

    public init(arms: (SubShape, SubShape), apex: SubShape,
                customLabel: String? = nil, id: String? = nil)

    public var anchorPoints: [SIMD3<Float>] { get }   // [armA, apex, armB]; [] if unresolvable
    public var degrees: Float { get }                 // angle at apex; nan if an arm coincides
    public var label: String { get }                  // customLabel, else "%.1f°"
}
```

- **Parameters:** `arms` — the two arm anchors as a tuple; `apex` — the vertex anchor.
- **Example:**

```swift
let v0 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 0)!, ordinal: 0)
let v1 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 1)!, ordinal: 1)
let v3 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 3)!, ordinal: 3)
let ang = AngularDimension(arms: (.vertex(part, ref: v1), .vertex(part, ref: v3)), apex: .vertex(part, ref: v0))
ais.add(ang)
print(ang.degrees)   // e.g. 90.0
```

---

## RadialDimension

Radius (or diameter) of a circular edge.

```swift
public final class RadialDimension: Dimension, @unchecked Sendable {
    public let id: String
    public let circularEdge: SubShape
    public var showDiameter: Bool
    public var customLabel: String?

    public init(circularEdge: SubShape, showDiameter: Bool = false,
                customLabel: String? = nil, id: String? = nil)

    public var anchorPoints: [SIMD3<Float>] { get }   // [center, pointOnEdge]
    public var radius: Float { get }                  // nan if the edge isn't circular
    public var diameter: Float { get }                // radius * 2
    public var label: String { get }                  // "R<r>" or "⌀<d>" (showDiameter)
}
```

- **Parameters:** `circularEdge` — an `.edge(...)` sub-shape with a circular 3D curve; `showDiameter`
  — label and value as diameter rather than radius.
- **Example:**

```swift
for i in 0..<cyl.shape.edgeCount where cyl.shape.edge(at: i)?.isCircle == true {
    let edgeShape = cyl.shape.subShape(type: .edge, index: i)!
    let rad = RadialDimension(circularEdge: .edge(cyl, ref: SubShapeRef(shape: edgeShape, ordinal: i)),
                              showDiameter: false)
    ais.add(rad)
    print(rad.radius, rad.label)   // 4.0  "R4.00"
    break
}
```
