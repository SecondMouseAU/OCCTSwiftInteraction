---
title: Manipulators
parent: API Reference
---

# Manipulators

`ManipulatorWidget` is a three-axis translate or rotate gizmo bound to one `InteractiveObject`. It
installs into an `InteractiveContext`, renders on the overlay layer (always on top), and routes its
picks to the widget pick stream. `Manipulator+SwiftUI.swift` adds the `.attachManipulator(_:)` View
modifier. `@MainActor`, `ObservableObject`.

## Topics

- [ManipulatorWidget.Mode](#manipulatorwidgetmode) · [ManipulatorWidget.Axis](#manipulatorwidgetaxis) · [init(target:mode:)](#inittargetmode) · [Tunable properties](#tunable-properties) · [Observable state](#observable-state) · [install(in:) / uninstall()](#installin--uninstall) · [hitTest(ndc:camera:aspect:)](#hittestndccameraaspect) · [beginDrag / updateDrag / endDrag](#begindrag--updatedrag--enddrag) · [reset()](#reset) · [attachManipulator(_:) (SwiftUI)](#attachmanipulator_-swiftui)

---

## ManipulatorWidget.Mode

The gizmo's mode. `.scale` is reserved — its hit-test and drag paths are no-ops.

```swift
public enum Mode: Sendable {
    case translate
    case rotate
    case scale     // reserved
}
```

---

## ManipulatorWidget.Axis

The three world axes. Each carries a unit `direction` and a display `color`.

```swift
public enum Axis: Hashable, Sendable, CaseIterable {
    case x, y, z
    public var direction: SIMD3<Float> { get }   // unit vector along the axis
    public var color: SIMD4<Float> { get }       // x red, y green, z blue
}
```

---

## init(target:mode:)

Build a widget for a target object.

```swift
public init(target: InteractiveObject, mode: Mode = .translate)
public let target: InteractiveObject
public let mode: Mode
```

- **Parameters:** `target` — the displayed object to manipulate; `mode` — translate (default) or rotate.
- **Example:**

```swift
let widget = ManipulatorWidget(target: part, mode: .translate)
```

---

## Tunable properties

```swift
public var size: Float                  // arrow length / ring reference; default 1.0
public var shaftRadius: Float           // arrow shaft radius; default 0.025
public var rotateTubeRadius: Float?     // ring tube radius; default shaftRadius * 1.2
public var rotateRingRadius: Float?     // ring major radius; default size * 0.85
public var hitNDCTolerance: Float       // translate hit threshold (NDC); default 0.04
public var rotateHitTolerance: Float?   // rotate hit threshold (world); default 2.5 * tubeRadius
public var rotateAxisDotMin: Float      // min |cos| for a ring to be hit-testable; default 0.05
public var snapTranslate: Float?        // translate snap increment (world units)
public var snapRotateDeg: Float?        // rotate snap increment (degrees)
public var onChange: ((simd_float4x4) -> Void)?   // fires live during drag
public var onCommit: ((simd_float4x4) -> Void)?   // fires on endDrag(commit: true)
```

- **Example:**

```swift
widget.size = 6
widget.snapTranslate = 0.25
widget.onCommit = { transform in applyToShape(transform) }
```

---

## Observable state

```swift
@Published public private(set) var transform: simd_float4x4
@Published public private(set) var isInstalled: Bool
@Published public private(set) var activeAxis: Axis?
public var isDragging: Bool { get }                       // activeAxis != nil
public weak private(set) var context: InteractiveContext? // set between install and uninstall
```

- **Example:**

```swift
if widget.isDragging { print("dragging axis:", widget.activeAxis as Any) }
```

---

## install(in:) / uninstall()

Install the gizmo into a context (adds three handle bodies); uninstall removes them and restores the
target's pre-install transform.

```swift
public func install(in context: InteractiveContext)
public func uninstall()
```

- **Example:**

```swift
widget.install(in: ais)
// ...
widget.uninstall()
```

---

## hitTest(ndc:camera:aspect:)

Return which axis (if any) lies under the pointer. NDC is `[-1, 1]` with +Y up.

```swift
public func hitTest(ndc: SIMD2<Float>, camera: CameraState, aspect: Float) -> Axis?
```

- **Parameters:** `ndc` — pointer in normalized device coords; `camera` — the viewport `CameraState`;
  `aspect` — viewport aspect ratio.
- **Returns:** the grabbed `Axis`, or `nil`.
- **Example:**

```swift
let axis = widget.hitTest(ndc: ndc, camera: ais.viewport.cameraState,
                          aspect: ais.viewport.lastAspectRatio)
```

---

## beginDrag / updateDrag / endDrag

Drive a drag once `hitTest` found an axis.

```swift
public func beginDrag(axis: Axis, ndc: SIMD2<Float>, camera: CameraState, aspect: Float)
public func updateDrag(ndc: SIMD2<Float>, camera: CameraState, aspect: Float)
public func endDrag(commit: Bool = true)
```

- **Parameters:** as `hitTest`, plus `axis` for `beginDrag`; `commit` fires `onCommit` when true.
- **Example:**

```swift
let cam = ais.viewport.cameraState
let aspect = ais.viewport.lastAspectRatio
if let axis = widget.hitTest(ndc: ndc, camera: cam, aspect: aspect) {
    widget.beginDrag(axis: axis, ndc: ndc, camera: cam, aspect: aspect)
}
widget.updateDrag(ndc: ndc, camera: cam, aspect: aspect)
widget.endDrag(commit: true)
```

---

## reset()

Reset the running transform to identity (and re-apply handle / target transforms if installed).

```swift
public func reset()
```

- **Example:**

```swift
widget.reset()
```

---

## attachManipulator(_:) (SwiftUI)

A `View` modifier (`Manipulator+SwiftUI.swift`) that wraps a viewport view with a
`.highPriorityGesture(DragGesture)`. It hit-tests the widget on touch-down, drives its drag when a
handle was grabbed, and otherwise forwards the gesture to the camera (orbit). The widget must already
be `install(in:)`-ed.

```swift
public extension View {
    func attachManipulator(_ widget: ManipulatorWidget) -> some View
}
```

- **Parameters:** `widget` — an installed `ManipulatorWidget`.
- **Returns:** the view with the gesture attached.
- **Example:**

```swift
import SwiftUI

@MainActor
struct EditorView: View {
    @StateObject private var ais = InteractiveContext(viewport: ViewportController())
    @StateObject private var widget: ManipulatorWidget

    init() {
        let ctx = InteractiveContext(viewport: ViewportController())
        _ais = StateObject(wrappedValue: ctx)
        let part = ctx.display(Shape.box(width: 10, height: 5, depth: 3)!)
        let w = ManipulatorWidget(target: part, mode: .translate)
        w.install(in: ctx)
        _widget = StateObject(wrappedValue: w)
    }

    var body: some View {
        MetalViewportView(controller: ais.viewport, bodies: $ais.bodies)
            .attachManipulator(widget)
    }
}
```
