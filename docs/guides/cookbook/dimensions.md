---
title: Dimensions
parent: Cookbook
nav_order: 5
---

# Dimensions

A `Dimension` is a labeled measurement anchored on `SubShape`s. AIS owns the topology-aware anchor
resolution (sub-shape → world point) and pushes a `ViewportMeasurement` into `viewport.measurements`,
where OCCTSwiftViewport's `MeasurementOverlay` draws leader lines and a billboarded label.

Add a dimension with `InteractiveContext.add(_:)`; remove it with `remove(_:)`.

## Linear dimension

`LinearDimension(from:to:plane:customLabel:id:)` measures the straight-line distance between two
anchors. The optional `plane: WorkPlane?` projects both anchors onto the plane first, giving an
in-plane length.

```swift
import OCCTSwift
import OCCTSwiftAIS

let ais = InteractiveContext(viewport: ViewportController())
let part = ais.display(Shape.box(width: 10, height: 5, depth: 3)!)

let v0 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 0)!, ordinal: 0)
let v6 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 6)!, ordinal: 6)
let lin = LinearDimension(from: .vertex(part, ref: v0), to: .vertex(part, ref: v6))
ais.add(lin)
print(lin.distance)   // raw Float
print(lin.label)      // formatted, e.g. "11.6"
```

In-plane variant:

```swift
let plane = WorkPlane(origin: .zero, normal: SIMD3<Float>(0, 0, 1))
let inPlane = LinearDimension(from: .vertex(part, ref: v0), to: .vertex(part, ref: v6),
                             plane: plane,
                             customLabel: "datum span")
ais.add(inPlane)
```

## Angular dimension

`AngularDimension(arms:apex:customLabel:id:)` measures the angle at the apex; `arms` is a tuple of the
two arm anchors. Anchor order is `[armA, apex, armB]`.

```swift
let v1 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 1)!, ordinal: 1)
let v3 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 3)!, ordinal: 3)
let ang = AngularDimension(arms: (.vertex(part, ref: v1), .vertex(part, ref: v3)), apex: .vertex(part, ref: v0))
ais.add(ang)
print(ang.degrees)   // angle at the apex in degrees
print(ang.label)     // e.g. "90.0°"
```

## Radial dimension

`RadialDimension(circularEdge:showDiameter:customLabel:id:)` measures the radius (or diameter, when
`showDiameter` is true) of a circular edge. The `circularEdge` must be a `.edge(...)` sub-shape whose
underlying curve is circular.

```swift
let cyl = ais.display(Shape.cylinder(radius: 4, height: 8)!)
for i in 0..<cyl.shape.edgeCount {
    if let edge = cyl.shape.edge(at: i), edge.isCircle {
        let edgeShape = cyl.shape.subShape(type: .edge, index: i)!
        let rad = RadialDimension(circularEdge: .edge(cyl, ref: SubShapeRef(shape: edgeShape, ordinal: i)),
                                  showDiameter: false)
        ais.add(rad)
        print(rad.radius)   // 4.0
        print(rad.label)    // "R4.00"  (⌀ + diameter when showDiameter: true)
        break
    }
}
```

## Refreshing and removing

If the underlying anchors moved (you mutated a `Shape`), re-evaluate the measurement in place:

```swift
ais.refreshDimensionMeasurement(lin)   // re-fetches anchorPoints, replaces in viewport.measurements
```

`ais.remove(lin)` drops a single dimension. `ais.dimensions` lists every dimension currently in the
context. `ais.removeAll()` clears every body, selection, and dimension at once.

### Anchor resolution

Anchors resolve directly from each sub-shape's `SubShapeRef.shape`, with no ordinal round-trip
through the source `Shape`:

| `SubShape` | World anchor |
| --- | --- |
| `.body(_)` | bbox center of `Shape.bounds` |
| `.face(_, ref)` | bbox center of `Face(ref.shape).bounds` |
| `.edge(_, ref)` | midpoint of `Edge(ref.shape).endpoints` |
| `.vertex(_, ref)` | `ref.shape.vertices().first` |

A `RadialDimension` additionally resolves the circle's center and radius from the edge's 3D curve.

Every row above can fail: `Shape.bounds` and `Face.bounds` are Optional, `Face(ref.shape)` /
`Edge(ref.shape)` return nil for a sub-shape of another kind, and `vertices()` can be empty. When
any anchor of a `LinearDimension` or `AngularDimension` fails, `anchorPoints` is `[]`, `distance`
(or `degrees`) is `nan`, `label` is `"?"`, and `ais.add(_:)` registers the dimension without drawing
it: a dimension that cannot be placed is not drawn at the world origin instead.
`ais.refreshDimensionMeasurement(_:)` re-checks, adding the annotation once the anchors resolve and
dropping it if they stop.

`RadialDimension` is the exception: it reports `[.zero, .zero]` rather than `[]` for a sub-shape
that is not a circular edge, and so is still drawn.
