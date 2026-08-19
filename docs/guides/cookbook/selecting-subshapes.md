---
title: Selecting sub-shapes
parent: Cookbook
nav_order: 1
---

# Selecting sub-shapes

`InteractiveContext` turns GPU picks into typed `SubShape` selections. You choose which kinds of
pick count via `selectionMode`, observe the result via the `@Published` `selection`, and read back
concrete OCCTSwift `Face` / `Edge` handles from the `Selection`.

## Choosing what's pickable

`selectionMode` is a `Set<SelectionMode>` — any combination of `.body`, `.face`, `.edge`, `.vertex`.
Changing it clears the current selection.

```swift
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftAIS

let ais = InteractiveContext(viewport: ViewportController())
if let part = Shape.box(width: 10, height: 5, depth: 3) {
    ais.display(part)
}
ais.selectionMode = [.face, .edge, .vertex]   // face + edge + vertex picks all count
```

## Reading the selection

A pick from the viewport **replaces** the selection with the picked sub-shape; empty-space picks
leave it untouched. The derived accessors resolve each entry back to OCCTSwift handles:

```swift
// In SwiftUI: .onChange(of: ais.selection) { _, sel in ... }
let sel = ais.selection
print("\(sel.count) sub-shapes,  \(sel.bodies.count) distinct bodies")

for face in sel.faces {            // [Face]
    print("face area:", face.area())
}
for edge in sel.edges {            // [Edge]
    print("edge length:", edge.length())
}
for p in sel.vertices {            // [SIMD3<Double>]
    print("vertex at:", p)
}
```

`Selection.faces` / `.edges` resolve directly from each entry's `SubShapeRef.shape` (the concrete
sub-shape captured at pick time) and wrap it in `Face` / `Edge` — no re-derivation via
`shape.subShape(type:index:)` by index, which doesn't reliably agree with the render-path ordinal once
a sub-shape is shared between shells. `Selection.vertices` returns world-space `SIMD3<Double>`
coordinates (OCCTSwift exposes vertices positionally, not as a `Vertex` class).

## `SubShape` and `SubShapeRef`

`.face` / `.edge` / `.vertex` carry a `SubShapeRef`, not a bare index:

```swift
public struct SubShapeRef: Hashable, Sendable {
    public let shape: Shape                       // the picked sub-shape itself
    public let uid: BRepGraph.GraphUID?        // durable handle, when a graph was in hand
    public let ordinal: Int                        // tessellation-time render-path index
}
```

- **`shape`** is what geometry queries should use (`Face(ref.shape)`, `sel.faces`, …).
- **`uid`** is what survives a mutation — see "Remapping a selection" below.
- **`ordinal`** is render-path-only (highlight overlays index per-triangle buffers by it); never
  compare sub-shapes by ordinal alone.

## Programmatic, additive selection

`select(_:)` / `deselect(_:)` mutate the selection as a `Set` — adding the same `SubShape` twice is
idempotent. `clearSelection()` empties it.

```swift
let obj = ais.display(Shape.box(width: 4, height: 4, depth: 4)!)
let faceShape0 = obj.shape.subShape(type: .face, index: 0)!
let faceShape2 = obj.shape.subShape(type: .face, index: 2)!
ais.select(.face(obj, ref: SubShapeRef(shape: faceShape0, ordinal: 0)))
ais.select(.face(obj, ref: SubShapeRef(shape: faceShape2, ordinal: 2)))   // now two faces selected
ais.deselect(.face(obj, ref: SubShapeRef(shape: faceShape0, ordinal: 0))) // back to one
ais.clearSelection()
```

In practice most selections come from a pick (`handlePick` mints the `SubShapeRef`, uid included,
for you) rather than being hand-built like this.

## Remapping a selection across a `Shape` mutation

A render-path ordinal only means "face 5" while the exact tessellation it came from is unchanged. To
carry a selection across a modelling operation that rebuilds the shape (a boolean, a fillet), use
`InteractiveContext.update(_:to:absorbing:operationName:)` — it absorbs the operation's history into
the object's own living `BRepGraph` (built once at `display(_:style:)` and retained across every
subsequent `update` call) and remaps `selection` / `hover` forward automatically:

```swift
let obj = ais.display(baseShape)
ais.selectionMode = [.face]
// ... a pick populates ais.selection with a SubShapeRef carrying a uid ...

let (result, history) = baseShape.subtractedWithFullHistory(tool)!
if let updated = ais.update(obj, to: result, absorbing: history, operationName: "cut") {
    // ais.selection now references `updated` — split faces expand to all their
    // successors; a sub-shape the cut deleted is dropped, not silently pointed
    // at a coincidentally-adjacent neighbour.
}
```

`remap(_:using:rebindingTo:)` is the lower-level primitive `update` calls internally — resolve via
each sub-shape's `uid` (`graph.node(forUID:)`, which rejects a uid minted by a different graph
instance) and `graph.findDerivedOrSelf(of:)`. A sub-shape with no `uid` (no graph was in hand at pick
time) is dropped: there's nothing durable to resolve it by. `.body(_)` always rebinds to the new
object. `isDeleted(_:in:)` distinguishes "the operation consumed this sub-shape" from "it wasn't
selected" — `remap` alone can't, since both just look like "absent from the result."
