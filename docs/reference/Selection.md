---
title: Selection
parent: API Reference
---

# Selection

The selection model: `InteractiveObject` (an erased scene handle), `SubShape` (a body or one of its
TopoDS sub-shapes), `SubShapeRef` (the durable handle a `.face`/`.edge`/`.vertex` carries),
`SelectionMode` (what kinds of pick count), and `Selection` (a snapshot of picked sub-shapes).

## Topics

- [SelectionMode](#selectionmode) · [InteractiveObject](#interactiveobject) · [SubShapeRef](#subshaperef) · [SubShape](#subshape) · [Selection](#selection)

---

## SelectionMode

Categories of sub-shape that can be selected. Used as a `Set<SelectionMode>` on
`InteractiveContext.selectionMode`.

```swift
public enum SelectionMode: Hashable, Sendable {
    case body
    case face
    case edge
    case vertex
}
```

- **Example:**

```swift
ais.selectionMode = [.face, .edge]   // face and edge picks both produce a selection
```

---

## InteractiveObject

An erased reference to something currently displayed in an `InteractiveContext`. Equality and hashing
are by `id` only — two `InteractiveObject`s with the same id refer to the same logical scene entry
even if their `Shape` was rebuilt.

```swift
public struct InteractiveObject: Hashable, Sendable {
    public let id: UUID
    public let shape: Shape

    public init(id: UUID = UUID(), shape: Shape)
}
```

- **Parameters:** `id` — stable identity (defaults to a fresh UUID); `shape` — the source OCCTSwift `Shape`.
- **Example:** you usually get one back from `InteractiveContext.display(_:)` rather than constructing it:

```swift
let part: InteractiveObject = ais.display(Shape.box(width: 4, height: 4, depth: 4)!)
print(part.shape.faceCount)
```

---

## SubShapeRef

A durable handle to a picked sub-shape, carried by every `.face` / `.edge` / `.vertex` case of
`SubShape`.

```swift
public struct SubShapeRef: Hashable, Sendable {
    public let shape: Shape
    public let uid: BRepGraph.GraphUID?
    public let ordinal: Int

    public init(shape: Shape, uid: BRepGraph.GraphUID? = nil, ordinal: Int)
}
```

- **`shape`:** the resolved sub-shape itself, captured once at pick time. Use this for geometry
  queries — `Selection.faces` / `.edges` / `.vertices` resolve from it directly, no re-derivation via
  `Shape.subShape(type:index:)` on `ordinal`.
- **`uid`:** a `BRepGraph.GraphUID`, minted when a graph was in hand at pick time. This is what
  `InteractiveContext.remap(_:using:rebindingTo:)` resolves through — it survives a mutation that
  `ordinal` alone does not. `nil` when no graph was available; such a sub-shape has nothing durable to
  remap by and is dropped.
- **`ordinal`:** the tessellation-time render-path index. Ephemeral — valid only against the
  `ViewportBody` it was minted from (highlight overlays index per-triangle buffers by it). Never
  compare sub-shapes by `ordinal` alone; equality follows `uid` when both sides have one, falling back
  to `ordinal` only when neither does.

---

## SubShape

A specific TopoDS sub-shape inside a displayed `InteractiveObject`, or the whole body.

```swift
public enum SubShape: Hashable, Sendable {
    case body(InteractiveObject)
    case face(InteractiveObject, ref: SubShapeRef)
    case edge(InteractiveObject, ref: SubShapeRef)
    case vertex(InteractiveObject, ref: SubShapeRef)

    public var object: InteractiveObject { get }
    public var ref: SubShapeRef? { get }   // nil for .body
}
```

- **`object`:** the `InteractiveObject` this sub-shape belongs to, regardless of case.
- **`ref`:** the durable handle, or `nil` for `.body`.
- **Example:** in practice you get these from a pick (`handlePick` mints the ref for you) rather than
  constructing them by hand:

```swift
ais.selectionMode = [.face]
// ... a pick happens via the viewport ...
if case .face(let obj, let ref)? = ais.selection.subshapes.first {
    print(obj.id, ref.uid != nil)
}
```

---

## Selection

An immutable snapshot of selected sub-shapes, with derived accessors that resolve each entry back to
OCCTSwift handles.

```swift
public struct Selection: Hashable, Sendable {
    public let subshapes: Set<SubShape>
    public init(_ subshapes: Set<SubShape> = [])

    public var isEmpty: Bool { get }
    public var count: Int { get }

    public var bodies: Set<InteractiveObject> { get }
    public var faces: [Face] { get }
    public var edges: [Edge] { get }
    public var vertices: [SIMD3<Double>] { get }
}
```

- **`bodies`:** the distinct interactive objects represented in this selection.
- **`faces` / `edges`:** concrete OCCTSwift `Face` / `Edge` handles for any `.face(...)` / `.edge(...)`
  entries, resolved from each entry's `SubShapeRef.shape`; order unspecified. A ref whose `shape` isn't
  actually a face/edge (e.g. constructed by hand with the wrong shape) is omitted.
- **`vertices`:** world-space `SIMD3<Double>` positions for any `.vertex(...)` entries (OCCTSwift
  exposes vertices positionally, not as a `Vertex` class).
- **Example:**

```swift
let sel = ais.selection
print("\(sel.count) selected,  \(sel.bodies.count) bodies")
for face in sel.faces { print("area:", face.area()) }
for p in sel.vertices { print("vertex:", p) }
```
