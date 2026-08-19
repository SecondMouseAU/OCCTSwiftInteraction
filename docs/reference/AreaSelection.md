---
title: Area Selection
parent: API Reference
---

# Area Selection

Rectangle and lasso (freeform polygon) area selection, plus the SwiftUI drag-gesture integration.

## Topics

- [AreaSelectionMode](#areaselectionmode) · [SelectionScheme](#selectionscheme) · [InteractiveContext.selectRectangle(from:to:mode:scheme:viewportSize:)](#interactivecontextselectrectanglefromtomodeschemeviewportsize) · [InteractiveContext.selectPolygon(_:mode:scheme:viewportSize:)](#interactivecontextselectpolygon_modeschemeviewportsize) · [AreaSelectionTool](#areaselectiontool) · [AreaSelectionController](#areaselectioncontroller) · [attachAreaSelection(_:)](#attachareaselection_)

---

## AreaSelectionMode

How a rectangle/lasso selection decides whether a candidate sub-shape counts as "inside" the region.

```swift
public enum AreaSelectionMode: Sendable {
    case enclosed
    case intersecting
}
```

- **`.enclosed`:** every one of the candidate's representative screen-space points must fall inside
  the region.
- **`.intersecting`:** at least one does.

Both are tested against each candidate's own **vertices**, projected to screen space via
`ProjectionUtility.worldToScreen(point:vpMatrix:viewportSize:)` — not a GPU pixel scan (OCCTSwiftViewport
has no batch/region pick API; see [OCCTSwiftViewport#90](https://github.com/SecondMouseAU/OCCTSwiftViewport/issues/90)).
This means: no occlusion handling (a hidden sub-shape can still match), and a region entirely inside a
large face's interior — touching none of its vertices — won't register as `.intersecting`.

---

## SelectionScheme

How the matched set combines with the existing `Selection`. Mirrors OCCT's `AIS_SelectionScheme`.

```swift
public enum SelectionScheme: Sendable {
    case replace
    case add
    case remove
    case xor
}
```

- **`.replace`:** the matched set becomes the new selection.
- **`.add`:** union with the current selection.
- **`.remove`:** subtract the matched set from the current selection.
- **`.xor`:** toggle — matched sub-shapes already selected are deselected, and vice versa.

---

## InteractiveContext.selectRectangle(from:to:mode:scheme:viewportSize:)

```swift
public func selectRectangle(
    from: CGPoint,
    to: CGPoint,
    mode: AreaSelectionMode = .enclosed,
    scheme: SelectionScheme = .replace,
    viewportSize: CGSize
)
```

- **Parameters:** `from`/`to` — the two opposite corners of the rectangle, in the gesture-receiving
  view's local coordinates (top-left origin, Y-down — the same convention a SwiftUI `DragGesture`'s
  `location` uses); `viewportSize` — that view's current size, for NDC → screen conversion.
- Honours `selectionMode` (only kinds present there are enumerated as candidates) and every installed
  `filters` entry (a candidate a filter rejects doesn't match), exactly like a point pick.
- Skips objects whose `PresentationStyle.visible` is `false`.
- A `.body` candidate is tested against its bounding-box corners, so an object whose `Shape.bounds`
  is nil (no bounding box) is not a body candidate at all, the same way a sub-shape kind with no
  identity table is skipped. It is never treated as a zero-size box at the world origin, which would
  otherwise match any region drawn over the origin.
- **Example:**

```swift
ais.selectRectangle(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300),
                    mode: .enclosed, viewportSize: CGSize(width: 800, height: 600))
```

---

## InteractiveContext.selectPolygon(_:mode:scheme:viewportSize:)

```swift
public func selectPolygon(
    _ points: [CGPoint],
    mode: AreaSelectionMode = .enclosed,
    scheme: SelectionScheme = .replace,
    viewportSize: CGSize
)
```

- **Parameters:** `points` — the lasso path, implicitly closed (fewer than 3 points is a no-op).
  Same coordinate convention and gating as `selectRectangle`.
- **Example:**

```swift
ais.selectPolygon(dragPoints, mode: .intersecting, viewportSize: viewportSize)
```

---

## AreaSelectionTool

Which interaction a drag gesture performs once `.attachAreaSelection(_:)` is installed.

```swift
public enum AreaSelectionTool: Sendable, Equatable {
    case navigate
    case rectangle
    case lasso
}
```

- **`.navigate`** (the default): the drag passes straight through to camera orbit — attaching the
  modifier changes nothing until the app explicitly switches tools. There's no hit-test to arbitrate a
  drag's intent the way `ManipulatorWidget` does for gizmo handles, so tool selection is an explicit,
  app-driven toggle (a "select tool" button), not a modifier key.
- **`.rectangle`** / **`.lasso`**: the drag draws a rubber-band/lasso overlay and, on release, calls
  `selectRectangle`/`selectPolygon`.

---

## AreaSelectionController

Drag-gesture state for area selection. Bind one to a viewport view via `.attachAreaSelection(_:)`.

```swift
@MainActor
public final class AreaSelectionController: ObservableObject {
    public let context: InteractiveContext
    public var tool: AreaSelectionTool      // default .navigate
    public var mode: AreaSelectionMode      // default .enclosed
    public var scheme: SelectionScheme      // default .replace

    public init(context: InteractiveContext)
}
```

- **Example:**

```swift
let controller = AreaSelectionController(context: ais)
controller.tool = .rectangle
```

---

## attachAreaSelection(_:)

```swift
public extension View {
    func attachAreaSelection(_ controller: AreaSelectionController) -> some View
}
```

Wraps a viewport view with a `.highPriorityGesture(DragGesture)` (mirroring
`ManipulatorWidget`/`attachManipulator(_:)`'s exact architecture) plus a live rubber-band (rectangle)
or lasso outline drawn as a plain SwiftUI overlay — OCCTSwiftViewport's `MetalViewportView` has no
content-injection point of its own, so the overlay is composited from outside it, the same way the
manipulator's gesture layer is.

- **Example:**

```swift
MetalViewportView(controller: ais.viewport, bodies: $ais.bodies)
    .attachAreaSelection(controller)
```
