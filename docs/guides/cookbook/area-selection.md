---
title: Area selection
parent: Cookbook
nav_order: 3
---

# Area selection

Select a whole region of geometry in one gesture instead of clicking one sub-shape at a time.
`InteractiveContext.selectRectangle(from:to:)` / `selectPolygon(_:)` do the underlying work; the
SwiftUI `.attachAreaSelection(_:)` modifier wires up the drag gesture, a live rubber-band/lasso
overlay, and camera-orbit passthrough.

## Programmatic area selection

```swift
import OCCTSwift
import OCCTSwiftAIS

let ais = InteractiveContext(viewport: ViewportController())
ais.selectionMode = [.face]
let part = ais.display(Shape.box(width: 10, height: 5, depth: 3)!)

ais.selectRectangle(
    from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300),
    mode: .enclosed, scheme: .replace,
    viewportSize: CGSize(width: 800, height: 600)
)
```

`from`/`to` and `viewportSize` are in the gesture-receiving view's own coordinates (top-left origin,
Y-down) — exactly what a SwiftUI `DragGesture`'s `location` and a `GeometryReader`'s `size` give you.

Lasso (freeform polygon) selection works the same way:

```swift
ais.selectPolygon(dragPoints, mode: .intersecting, viewportSize: viewportSize)
```

## `.enclosed` vs `.intersecting`

- **`.enclosed`** — every one of a candidate's representative points must fall inside the region.
- **`.intersecting`** — at least one does.

**Implementation note.** OCCTSwiftViewport's GPU pick only resolves one screen pixel at a time and has
no batch/region readback (see [OCCTSwiftViewport#90](https://github.com/SecondMouseAU/OCCTSwiftViewport/issues/90),
filed for this), so area selection is CPU-side: each candidate's own vertices are projected to screen
space via `ProjectionUtility.worldToScreen(point:vpMatrix:viewportSize:)` and tested against the
region. Two consequences:

- **No occlusion handling** — a sub-shape hidden behind another can still be selected if its vertices
  project into the region.
- **Vertex-only approximation** — a region entirely inside a large face's interior, touching none of
  its vertices, won't register as intersecting. Curved edges are approximated by their endpoints.

## `SelectionScheme`

How the matched set combines with the current `ais.selection`, mirroring OCCT's `AIS_SelectionScheme`:

```swift
ais.selectRectangle(from: a, to: b, scheme: .replace, viewportSize: size)  // discard old, keep only new
ais.selectRectangle(from: a, to: b, scheme: .add,     viewportSize: size)  // union
ais.selectRectangle(from: a, to: b, scheme: .remove,  viewportSize: size)  // subtract
ais.selectRectangle(from: a, to: b, scheme: .xor,     viewportSize: size)  // toggle overlap
```

## Filters and `selectionMode` still apply

```swift
ais.selectionMode = [.face]
ais.addFilter(SurfaceTypeFilter([.cylinder]))
ais.selectRectangle(from: a, to: b, viewportSize: size)
// only cylindrical faces within the rectangle are selected — same gating as a point pick.
```

## Wiring up the drag gesture

```swift
import SwiftUI
import OCCTSwiftViewport
import OCCTSwiftAIS

struct CADView: View {
    @StateObject private var ais = InteractiveContext(viewport: ViewportController())
    @StateObject private var areaSelection: AreaSelectionController

    init() {
        let context = InteractiveContext(viewport: ViewportController())
        _ais = StateObject(wrappedValue: context)
        _areaSelection = StateObject(wrappedValue: AreaSelectionController(context: context))
    }

    var body: some View {
        MetalViewportView(controller: ais.viewport, bodies: $ais.bodies)
            .attachAreaSelection(areaSelection)
            .toolbar {
                Button("Navigate")  { areaSelection.tool = .navigate }
                Button("Rectangle") { areaSelection.tool = .rectangle }
                Button("Lasso")     { areaSelection.tool = .lasso }
            }
    }
}
```

`AreaSelectionTool.navigate` is the default — with it active, `.attachAreaSelection(_:)` changes
nothing about the view's existing camera-orbit behaviour. Switching to `.rectangle` or `.lasso` is an
explicit, app-driven choice (a "select tool" toggle, same idea as any CAD app's navigate-vs-select
tool switch) rather than a modifier key, since there's no geometry hit-test to arbitrate a drag's
intent the way `ManipulatorWidget` uses for gizmo handles.

While dragging, a semi-transparent rubber-band rectangle or lasso outline tracks the gesture; it's
drawn as a plain SwiftUI overlay stacked on top of the viewport (OCCTSwiftViewport's `MetalViewportView`
has no content-injection point of its own for this), so no renderer changes were needed.
