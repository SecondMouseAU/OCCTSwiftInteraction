---
title: Getting Started
nav_order: 4
---

# Getting started with OCCTSwiftAIS

A walkthrough that builds up a SwiftUI CAD viewer from a blank `MetalViewportView` to one with face
selection, a translate gizmo, and a linear dimension. Everything in this guide uses the real
`OCCTSwiftAIS` public API.

If you just want one snippet, the [Home page hero example](../index.md) is enough. This guide is for
"I want to understand each moving piece".

## 1. Add the package

```swift
// Package.swift
.package(url: "https://github.com/SecondMouseAU/OCCTSwiftAIS.git", from: "1.0.3"),
```

Then add `.product(name: "OCCTSwiftAIS", package: "OCCTSwiftAIS")` to your target. AIS pulls
`OCCTSwiftTools`, `OCCTSwiftViewport`, and `OCCTSwift` transitively — no need to declare them
separately.

## 2. The two top-level objects

Every interactive scene has exactly two:

- **`ViewportController`** — owns camera, lighting, and the GPU pick pipeline. From `OCCTSwiftViewport`.
- **`InteractiveContext`** — owns the *scene state*: which `Shape`s are displayed, what's selected,
  what's hovered, which dimensions exist. Built on top of one `ViewportController`.

```swift
import SwiftUI
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftAIS

@MainActor
struct CADView: View {
    @StateObject private var ais = InteractiveContext(viewport: ViewportController())

    var body: some View {
        MetalViewportView(controller: ais.viewport, bodies: $ais.bodies)
    }
}
```

`$ais.bodies` is the `Binding<[ViewportBody]>` `MetalViewportView` expects. `ais.viewport` is the
controller you created.

## 3. Display a shape

`InteractiveContext.display(_:style:)` tessellates an OCCTSwift `Shape` and adds it to the scene. It
returns an `InteractiveObject` — a UUID-keyed scene handle you can pass back to AIS later (to remove
the body, attach a manipulator, or anchor a dimension).

```swift
.onAppear {
    if let box = Shape.box(width: 10, height: 5, depth: 3) {
        ais.display(box)
    }
}
```

`display(_:style:)` also takes an optional `PresentationStyle`:

```swift
let style = PresentationStyle(
    color: SIMD3<Float>(0.7, 0.6, 0.4),
    transparency: 0.0,
    displayMode: .shadedWithEdges,
    visible: true
)
ais.display(box, style: style)
```

Built-in presets: `.default`, `.ghosted`, `.highlighted`, `.hovered`.

## 4. Selection

Selection has two moving parts:

- **`selectionMode: Set<SelectionMode>`** — what *kinds* of pick produce a selection. Any combination
  of `.body`, `.face`, `.edge`, `.vertex`.
- **`selection: Selection`** — what's currently selected. Observable via SwiftUI's `onChange` (it's
  `@Published`).

```swift
.onAppear {
    if let part = Shape.box(width: 10, height: 5, depth: 3) {
        ais.display(part)
    }
    ais.selectionMode = [.face, .edge, .vertex]
}
.onChange(of: ais.selection) { _, sel in
    print("\(sel.count) sub-shapes selected")
    print("  faces: \(sel.faces.count)")
    print("  edges: \(sel.edges.count)")
    print("  vertices: \(sel.vertices.count)")
    for face in sel.faces {
        print("  face area: \(face.area())")
    }
}
```

The derived accessors:

| Accessor | Returns | Source |
| --- | --- | --- |
| `selection.faces` | `[Face]` | each entry's `SubShapeRef.shape` → `Face(_:)` |
| `selection.edges` | `[Edge]` | each entry's `SubShapeRef.shape` → `Edge(_:)` |
| `selection.vertices` | `[SIMD3<Double>]` | each entry's `SubShapeRef.shape.vertices().first` |
| `selection.bodies` | `Set<InteractiveObject>` | distinct objects across all entries |

A click **replaces** the selection with the picked sub-shape. Empty-space clicks leave the selection
alone. To accumulate, call `ais.select(_:)` / `ais.deselect(_:)` directly — those are additive (`Set`
semantics, idempotent). `ais.clearSelection()` empties it.

Changing `selectionMode` also clears the current selection.

### Body-level vs face-level highlighting

- `.body` selections push the body's id to `viewport.selectedBodyIDs` — the renderer's built-in body
  highlight kicks in.
- `.face` selections write per-triangle style entries to the source body's `triangleStyles`,
  composited by the renderer's highlight pass. Color comes from `HighlightStyle.selectionColor`.

Tweak the highlight color:

```swift
ais.setHighlightStyle(HighlightStyle(
    selectionColor: SIMD3<Float>(1.0, 0.65, 0.0),  // orange
    hoverColor:     SIMD3<Float>(0.3, 0.8, 1.0),   // cyan (body-level only today)
    outlineWidth:   2.0
))
```

## 5. Selection filters

`selectionMode` restricts what *kind* of sub-shape counts; `SelectionFilter` restricts *which*
candidates of an allowed kind are pickable — mirroring OCCT's `StdSelect_FaceFilter` /
`StdSelect_EdgeFilter` family. Installed filters gate `handlePick` and hover, never programmatic
`select(_:)`.

```swift
ais.selectionMode = [.face]
ais.addFilter(SurfaceTypeFilter([.cylinder]))   // only cylindrical faces are pickable now
```

Built-in filters: `SurfaceTypeFilter` (by `Face.SurfaceType`), `CurveTypeFilter` (by `Edge.CurveType`),
`ShapeTypeFilter` (by `SelectionMode`), plus composition (`AllOfFilter`, `AnyOfFilter`, `NotFilter`) and
a closure escape hatch (`PredicateFilter`):

```swift
// Cylindrical faces under a given radius. `Face.bounds` is Optional, so a face
// with no bounding box fails the filter rather than reading as radius zero.
ais.addFilter(AllOfFilter([
    SurfaceTypeFilter([.cylinder]),
    PredicateFilter { sub in
        guard case .face(_, let ref) = sub, let face = Face(ref.shape),
            let bounds = face.bounds
        else { return false }
        return bounds.max.x - bounds.min.x < 20
    },
]))
```

Multiple installed filters (`ais.filters`) combine with **AND** — every filter must accept a candidate.
This is a deliberate departure from OCCT, whose context-level `AddFilter` combines with OR; see
`InteractiveContext.passesInstalledFilters` for the rationale. Reach for `AnyOfFilter` when you want OR.

```swift
ais.removeFilter(someFilter)   // by reference identity
ais.removeAllFilters()         // back to unrestricted picking
```

## 6. Area selection

Select a whole region in one gesture instead of clicking one sub-shape at a time — honours
`selectionMode` and `filters` exactly like a point pick.

```swift
ais.selectRectangle(
    from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300),
    mode: .enclosed, scheme: .replace,
    viewportSize: CGSize(width: 800, height: 600)
)
```

`.enclosed` requires every candidate's screen-projected vertices inside the region; `.intersecting`
requires at least one. There's no GPU pixel-scan behind this (OCCTSwiftViewport has no batch/region
pick API — see [OCCTSwiftViewport#90](https://github.com/SecondMouseAU/OCCTSwiftViewport/issues/90)),
so it's vertex-projection based: no occlusion handling, and a region entirely inside a large face's
interior won't register as intersecting.

Wire up the drag gesture and a live rubber-band/lasso overlay with `.attachAreaSelection(_:)`:

```swift
@StateObject private var areaSelection = AreaSelectionController(context: ais)

var body: some View {
    MetalViewportView(controller: ais.viewport, bodies: $ais.bodies)
        .attachAreaSelection(areaSelection)
}
```

`areaSelection.tool` defaults to `.navigate` — the drag passes straight through to camera orbit, so
attaching the modifier changes nothing until the app explicitly flips it to `.rectangle` or `.lasso`
(an explicit "select tool" toggle, since there's no hit-test to arbitrate a drag's intent the way the
manipulator widget has for gizmo handles).

## 7. Manipulator widgets

A `ManipulatorWidget` is a translate or rotate gizmo bound to one `InteractiveObject`. You install it
into an `InteractiveContext`; uninstall removes it cleanly and restores any pre-install transform on
the target.

```swift
@StateObject private var ais  = InteractiveContext(viewport: ViewportController())
@State        private var widget: ManipulatorWidget? = nil

// On appear, or wherever you decide a manipulator should appear:
let part = ais.display(Shape.box(width: 10, height: 5, depth: 3)!)
let w = ManipulatorWidget(target: part, mode: .translate)
w.size = 6                                      // arrow length in world units
w.snapTranslate = 0.25                          // snap to 0.25-unit increments
w.onChange = { transform in /* live during drag */ }
w.onCommit = { transform in /* on gesture release */ }
w.install(in: ais)
widget = w
```

The widget reports a `simd_float4x4` `transform`; during drag the *target body* gets
`body.transform = preInstallTransform * widget.transform` so the user sees the part move in real time.
On `onCommit` you typically transform the underlying `Shape` and re-display it.

For rotate, swap `mode: .rotate`, set `snapRotateDeg` instead of `snapTranslate`, and the gizmo
renders three torus rings (X / Y / Z) at the target's centroid.

### SwiftUI integration

`.attachManipulator(_:)` wraps `MetalViewportView` with a `.highPriorityGesture(DragGesture)` that
hit-tests the widget on touch-down:

```swift
var body: some View {
    Group {
        if let widget {
            MetalViewportView(controller: ais.viewport, bodies: $ais.bodies)
                .attachManipulator(widget)
        } else {
            MetalViewportView(controller: ais.viewport, bodies: $ais.bodies)
        }
    }
}
```

Drags on a handle drive the widget; drags off any handle forward to `viewport.handleOrbit(translation:)`
so the camera responds normally. The widget must already be `install(in:)`-ed — the modifier reads
`widget.context` to find the viewport.

If you want full manual control (e.g. a custom gesture stack), use the widget API directly:

```swift
let ndc: SIMD2<Float> = ...   // map your gesture point to [-1, 1] NDC, +Y up
let cam = ais.viewport.cameraState
let aspect = ais.viewport.lastAspectRatio

if !widget.isDragging,
   let axis = widget.hitTest(ndc: ndc, camera: cam, aspect: aspect) {
    widget.beginDrag(axis: axis, ndc: ndc, camera: cam, aspect: aspect)
}
widget.updateDrag(ndc: ndc, camera: cam, aspect: aspect)
// On gesture end:
widget.endDrag(commit: true)
```

## 8. Dimensions

A `Dimension` is a labeled measurement anchored on sub-shapes. Three concrete types:

- `LinearDimension(from:to:plane:?)` — distance between two anchors. Optional `WorkPlane` projects
  both anchors orthogonally before measuring.
- `AngularDimension(arms:apex:)` — angle at the apex.
- `RadialDimension(circularEdge:showDiameter:?)` — radius (or diameter) of a circular edge.

```swift
let part = ais.display(Shape.cylinder(radius: 4, height: 8)!)

// Linear distance between two corners.
let v0 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 0)!, ordinal: 0)
let v7 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 7)!, ordinal: 7)
let lin = LinearDimension(from: .vertex(part, ref: v0), to: .vertex(part, ref: v7))
ais.add(lin)
print(lin.label)        // formatted distance, e.g. "9.85"
print(lin.distance)     // raw Float

// Find the first circular edge on the cylinder and dimension it.
for i in 0..<part.shape.edgeCount {
    if let edge = part.shape.edge(at: i), edge.isCircle {
        let edgeShape = part.shape.subShape(type: .edge, index: i)!
        let rad = RadialDimension(
            circularEdge: .edge(part, ref: SubShapeRef(shape: edgeShape, ordinal: i)),
            showDiameter: false
        )
        ais.add(rad)
        print(rad.label) // "R4.00"
        break
    }
}
```

Each dimension emits a `ViewportMeasurement` (distance / angle / radius) into `viewport.measurements`.
The renderer's existing `MeasurementOverlay` SwiftUI Canvas draws leader lines + a billboarded label;
AIS owns only the topology-aware anchor resolution.

To re-evaluate after the underlying anchors moved (e.g. you mutated the `Shape`):

```swift
ais.refreshDimensionMeasurement(lin)
```

`ais.remove(lin)` drops the dimension; `ais.removeAll()` clears every body, selection, and dimension
in one go.

### Anchor resolution by sub-shape kind

Anchors resolve directly from each sub-shape's `SubShapeRef.shape`, never from a re-derived index
lookup on the source `Shape`:

| `SubShape` | Anchor world point |
| --- | --- |
| `.body(_)` | bbox center of `Shape.bounds` |
| `.face(_, ref)` | bbox center of `Face(ref.shape).bounds` |
| `.edge(_, ref)` | midpoint of `Edge(ref.shape).endpoints` |
| `.vertex(_, ref)` | `ref.shape.vertices().first` |

These are constant-time lookups. Curved-face area-weighted centroids and arc-length edge midpoints are
future refinements.

An anchor that cannot resolve (`Shape.bounds` and `Face.bounds` are Optional, so a shape with no
bounding box has no bbox center) makes the whole dimension unresolvable: `anchorPoints` is `[]`,
`distance` is `nan`, `label` is `"?"`, and `ais.add(_:)` registers the dimension without drawing it.
Nothing is placed at the world origin as a stand-in. Call
`ais.refreshDimensionMeasurement(_:)` once the anchors can resolve to make it appear.
(`RadialDimension` is the exception: it reports `[.zero, .zero]` for a non-circular edge.)

## 9. Standard scene objects

Visual aids that ride on the `.userGeometry` pick layer but aren't selectable:

```swift
let trihedronBodies = Trihedron(at: .zero, axisLength: 5).makeBodies()
let workplaneBodies = WorkPlane(origin: .zero, normal: SIMD3<Float>(0, 0, 1), size: 50).makeBodies()
let axisBodies      = Axis(from: .zero, to: SIMD3<Float>(10, 0, 0)).makeBodies()
let cloudBodies     = PointCloudPresentation(
    points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1), SIMD3<Float>(2, 0, -1)]
).makeBodies()

ais.bodies.append(contentsOf: trihedronBodies)
ais.bodies.append(contentsOf: workplaneBodies)
ais.bodies.append(contentsOf: axisBodies)
ais.bodies.append(contentsOf: cloudBodies)
```

Each instance has an `ownsBody(id:)` predicate — handy for cleanup:

```swift
let tri = Trihedron(at: .zero, axisLength: 5)
ais.bodies.append(contentsOf: tri.makeBodies())
// later:
ais.bodies.removeAll { tri.ownsBody(id: $0.id) }
```

## 10. Selection survival across `Shape` mutation

A `SubShape`'s `SubShapeRef.ordinal` only means "this render-path index" while the exact tessellation
it came from is unchanged. What actually survives a mutation is `SubShapeRef.uid` — a
`BRepGraph.GraphUID`, minted from a graph in hand at pick time.

`InteractiveContext` builds a `BRepGraph` for each displayed object at `display(_:style:)` and
retains that *same instance* across every subsequent mutation. Call
`update(_:to:absorbing:operationName:)` after running a modelling operation (any of OCCTSwift's
`*WithFullHistory` methods) against the object's shape — it absorbs the operation's history into that
living graph and remaps `selection` / `hover` forward automatically:

```swift
let base = Shape.box(width: 10, height: 10, depth: 10)!
var part = ais.display(base)
ais.selectionMode = [.face]
// ... a pick selects a face; ais.selection now holds a SubShapeRef with a uid ...

// Run the operation, then hand the result + its history to update(_:to:absorbing:operationName:):
let tool = Shape.box(origin: SIMD3(-1, 4, 8), width: 12, height: 2, depth: 4)!
let (result, history) = base.subtractedWithFullHistory(tool)!
if let updated = ais.update(part, to: result, absorbing: history, operationName: "cut") {
    part = updated
    // ais.selection now references `updated`:
    //  - a face the cut left untouched keeps its selection, re-resolved to a fresh uid
    //  - a face the cut split into two expands into two .face entries
    //  - a face the cut deleted entirely is dropped — see isDeleted(_:in:) below
}
```

`update` composes two lower-level pieces you can use directly if you're managing the `BRepGraph`
yourself: `remap(_:using:rebindingTo:)` (translate a `Selection` through an absorbed-history graph) and
`isDeleted(_:in:)` (tell "the operation consumed this sub-shape" apart from "it wasn't selected" — both
otherwise look like "absent from the remapped selection"):

```swift
if ais.isDeleted(somePickedFace, in: graph) {
    print("that face is gone — the cut removed it entirely")
}
```

Resolution goes entirely through each sub-shape's `uid`, never a stored index — so a sub-shape can
never end up silently pointing at a coincidentally-adjacent neighbour the way an index-based remap
could. A sub-shape with no `uid` at all (no graph was in hand when it was picked) is dropped: there's
nothing durable to resolve it by.

## Where to next

- The [Cookbook](cookbook/) — focused recipes per task.
- The [API Reference](../reference/) — every public symbol with real signatures.
- [SPEC.md](https://github.com/SecondMouseAU/OCCTSwiftAIS/blob/main/SPEC.md) — the original design brief.
- [CHANGELOG.md](../CHANGELOG.md) — what shipped per release.
