---
title: InteractiveContext
parent: API Reference
---

# InteractiveContext

The per-scene interactive state object — one `InteractiveContext` to one `ViewportController`. It owns
the array of `ViewportBody`s rendered by `MetalViewportView`, the current selection / hover, the
presentation styles, and the dimension registry. `@MainActor`, `ObservableObject`.

```swift
@MainActor
public final class InteractiveContext: ObservableObject {
    public init(viewport: ViewportController)
}
```

Bind it via `MetalViewportView(controller: ctx.viewport, bodies: $ctx.bodies)` when `ctx` is a
`@StateObject`.

## Topics

- [Published properties](#published-properties) · [display(_:style:)](#display_style) · [update(_:to:absorbing:operationName:)](#update_toabsorbingoperationname) · [remove(_:)](#remove_) · [removeAll()](#removeall) · [Selection mutation](#selection-mutation) · [Selection filters](#selection-filters) · [Area selection](#area-selection) · [setStyle(_:for:)](#setstyle_for) · [setHighlightStyle(_:)](#sethighlightstyle_) · [add(_:)](#add_) · [remove(_:)-dimension](#remove_-dimension) · [dimensions](#dimensions) · [refreshDimensionMeasurement(_:)](#refreshdimensionmeasurement_) · [remap(_:using:rebindingTo:)](#remap_usingrebindingto) · [isDeleted(_:in:)](#isdeleted_in)

---

## Published properties

```swift
public let viewport: ViewportController
@Published public var bodies: [ViewportBody]
@Published public var selectionMode: Set<SelectionMode>          // default [.body]
@Published public private(set) var selection: Selection
@Published public private(set) var hover: SubShape?
public var highlightStyle: HighlightStyle                        // default .default
```

- `bodies` — the bodies fed to `MetalViewportView`; bind via `$bodies`.
- `selectionMode` — what kinds of pick produce a selection. **Changing it clears the current
  selection.**
- `selection` — the current selection (read-only; mutate via `select` / `deselect` / `clearSelection`
  or a pick). Observable.
- `hover` — the currently hovered sub-shape (body granularity today), or `nil`.
- **Example:**

```swift
ais.selectionMode = [.face]
// SwiftUI:
// .onChange(of: ais.selection) { _, sel in ... }
```

---

## display(_:style:)

Display a shape with topology-aware selection enabled. Tessellates the `Shape`, appends a
`ViewportBody`, and registers a selectable `InteractiveObject`.

```swift
@discardableResult
public func display(_ shape: Shape, style: PresentationStyle = .default) -> InteractiveObject
```

- **Parameters:** `shape` — the OCCTSwift `Shape`; `style` — initial presentation style.
- **Returns:** the `InteractiveObject` scene handle.
- **Example:**

```swift
let part = ais.display(Shape.box(width: 10, height: 5, depth: 3)!,
                       style: .highlighted)
```

`display` also builds a `BRepGraph` from `shape` and retains it for the object's lifetime — see
`update(_:to:absorbing:operationName:)`, below, for what that's for.

---

## update(_:to:absorbing:operationName:)

Update a displayed object after a modelling operation that rebuilds its shape — a boolean, a fillet, a
chamfer, anything produced via one of OCCTSwift's `*WithFullHistory` methods run against `object.shape`.
Absorbs the operation's history into the object's living `BRepGraph` (built once in `display`,
retained across every subsequent `update` call — the input and result share one graph instance, so
every `SubShapeRef.uid` already held stays resolvable), rebuilds the displayed mesh, and remaps any
current `selection` / `hover` sub-shapes referencing `object` forward via `remap(_:using:rebindingTo:)`.

```swift
@discardableResult
public func update(
    _ object: InteractiveObject,
    to newShape: Shape,
    absorbing history: ShapeHistoryRef,
    operationName: String
) -> InteractiveObject?
```

- **Parameters:** `object` — the currently-displayed object being mutated; `newShape` — the operation's
  result; `history` — the handle returned alongside it by any `*WithFullHistory` method; `operationName`
  — a label recorded on every emitted history record.
- **Returns:** the updated `InteractiveObject` (same `id`, new `shape`), or `nil` if `object` isn't
  displayed, has no living graph (construction failed at `display` time), or the absorb fails — in any
  of those cases, `remove` and `display` fresh, accepting that the selection doesn't survive.
- **Example:**

```swift
let (result, history) = part.shape.subtractedWithFullHistory(tool)!
if let updated = ais.update(part, to: result, absorbing: history, operationName: "cut") {
    part = updated
}
```

---

## remove(_:)

Remove a displayed object, its body, and any selection / hover entries that referenced it.

```swift
public func remove(_ object: InteractiveObject)
```

- **Example:**

```swift
ais.remove(part)
```

---

## removeAll()

Clear every body, selection, hover, dimension, and viewport measurement in one go.

```swift
public func removeAll()
```

- **Example:**

```swift
ais.removeAll()
```

---

## Selection mutation

Add, remove, or clear sub-shapes. `select` / `deselect` use `Set` semantics (idempotent).

```swift
public func select(_ subshape: SubShape)
public func deselect(_ subshape: SubShape)
public func clearSelection()
```

- **Example:**

```swift
let face0 = part.shape.subShape(type: .face, index: 0)!
let face2 = part.shape.subShape(type: .face, index: 2)!
ais.select(.face(part, ref: SubShapeRef(shape: face0, ordinal: 0)))   // additive
ais.select(.face(part, ref: SubShapeRef(shape: face2, ordinal: 2)))
ais.deselect(.face(part, ref: SubShapeRef(shape: face0, ordinal: 0)))
ais.clearSelection()
```

In practice most selections come from a pick — `handlePick` mints the `SubShapeRef` (uid included)
for you.

---

## Selection filters

Restrict what `handlePick` / `handleHover` accept, beyond `selectionMode`. See
[Selection Filters](SelectionFilters.md) for the filter types themselves.

```swift
@Published public private(set) var filters: [any SelectionFilter]

public func addFilter(_ filter: any SelectionFilter)
public func removeFilter(_ filter: any SelectionFilter)   // by reference identity
public func removeAllFilters()
```

- Installed filters combine with **AND** (a deliberate departure from OCCT's OR — see
  [Selection Filters](SelectionFilters.md) for the rationale). Never gates programmatic `select(_:)`.
- **Example:**

```swift
ais.addFilter(SurfaceTypeFilter([.cylinder]))
ais.removeAllFilters()
```

---

## Area selection

Rectangle and lasso selection over a screen-space region — honours `selectionMode` and installed
`filters` exactly like a point pick. See [Area Selection](AreaSelection.md) for `AreaSelectionMode`,
`SelectionScheme`, and the SwiftUI gesture integration (`AreaSelectionController`,
`.attachAreaSelection(_:)`).

```swift
public func selectRectangle(from: CGPoint, to: CGPoint,
                            mode: AreaSelectionMode = .enclosed,
                            scheme: SelectionScheme = .replace,
                            viewportSize: CGSize)

public func selectPolygon(_ points: [CGPoint],
                          mode: AreaSelectionMode = .enclosed,
                          scheme: SelectionScheme = .replace,
                          viewportSize: CGSize)
```

- **Example:**

```swift
ais.selectRectangle(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300),
                    viewportSize: CGSize(width: 800, height: 600))
```

---

## setStyle(_:for:)

Restyle a displayed object in place — updates the underlying `ViewportBody`'s color and visibility.

```swift
public func setStyle(_ style: PresentationStyle, for object: InteractiveObject)
```

- **Example:**

```swift
ais.setStyle(.ghosted, for: part)
```

---

## setHighlightStyle(_:)

Set the colors used by the highlight overlay and refresh the current selection visuals immediately.

```swift
public func setHighlightStyle(_ style: HighlightStyle)
```

- **Example:**

```swift
ais.setHighlightStyle(HighlightStyle(selectionColor: SIMD3<Float>(1, 0.65, 0)))
```

---

## add(_:)

Add a dimension to the scene. Pushes its `viewportMeasurement` to `viewport.measurements`, where the
renderer's overlay picks it up. Idempotent for the same instance (re-adding refreshes its anchors).

A dimension whose anchors do not resolve (`anchorPoints` is `[]`, see
[Dimensions](Dimensions.md#dimension)) is registered but draws nothing, rather than being drawn at
the world origin. Call `refreshDimensionMeasurement(_:)` once its anchors can resolve to make it
appear.

```swift
@discardableResult
public func add<D: Dimension>(_ dimension: D) -> D
```

- **Returns:** the same dimension, for chaining.
- **Example:**

```swift
let v0 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 0)!, ordinal: 0)
let v6 = SubShapeRef(shape: part.shape.subShape(type: .vertex, index: 6)!, ordinal: 6)
let lin = ais.add(LinearDimension(from: .vertex(part, ref: v0), to: .vertex(part, ref: v6)))
```

---

## remove(_:)-dimension

Remove a previously-added dimension.

```swift
public func remove(_ dimension: any Dimension)
```

- **Example:**

```swift
ais.remove(lin)
```

---

## dimensions

All dimensions currently displayed in this context.

```swift
public var dimensions: [any Dimension] { get }
```

- **Example:**

```swift
print(ais.dimensions.count)
```

---

## refreshDimensionMeasurement(_:)

Re-fetch a dimension's `viewportMeasurement` and replace it in place in `viewport.measurements`. Call
after the underlying anchors moved (e.g. a target `Shape` mutated).

Anchors that stopped resolving drop the measurement from the overlay, and anchors that started
resolving add it back.

```swift
public func refreshDimensionMeasurement(_ dimension: any Dimension)
```

- **Example:**

```swift
ais.refreshDimensionMeasurement(lin)
```

---

## remap(_:using:rebindingTo:)

Remap a `Selection` whose sub-shapes were captured against an earlier shape state into a new
`Selection` against `newObject`, using history absorbed into `graph` via
`BRepGraph.add(_:absorbing:inputRoots:operationName:)`. This is the lower-level primitive
`update(_:to:absorbing:operationName:)` calls internally — reach for it directly only if you're
managing the `BRepGraph` yourself rather than going through `update`.

```swift
public func remap(
    _ selection: Selection,
    using graph: BRepGraph,
    rebindingTo newObject: InteractiveObject
) -> Selection
```

- **Parameters:** `selection` — the pre-mutation selection; `graph` — the `BRepGraph` that absorbed
  the operation's history (input and result must share this one instance); `newObject` — the
  post-mutation scene object the result references.
- **Returns:** a `Selection` against `newObject`, resolved through each sub-shape's `SubShapeRef.uid` —
  never a stored index. `1 → 1` (modified in place) keeps the same node re-resolved to a fresh uid;
  `1 → N` (e.g. a face split by a cut) expands into N entries; `1 → 0` (deleted) is dropped — see
  `isDeleted(_:in:)`. A sub-shape with no `uid` is dropped: there's nothing durable to resolve it by.
  `.body(_)` always rebinds to `newObject`.
- **Example:**

```swift
let remapped = ais.remap(oldSelection, using: graph, rebindingTo: newObj)
for sub in remapped.subshapes { ais.select(sub) }
```

---

## isDeleted(_:in:)

Whether a sub-shape's durable node was explicitly consumed by history absorbed into `graph` — as
opposed to simply never being mentioned by any recorded operation. `remap`'s silent drop can't tell
these apart on its own; both look like "absent from the result."

```swift
public func isDeleted(_ subshape: SubShape, in graph: BRepGraph) -> Bool
```

- **Returns:** `false` for `.body` sub-shapes, and for any sub-shape with no `uid` or whose `uid` isn't
  `graph`'s own — there's no node in `graph` to ask about.
- **Example:**

```swift
if ais.isDeleted(pickedFace, in: graph) {
    print("the cut removed that face entirely")
}
```
