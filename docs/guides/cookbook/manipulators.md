---
title: Transform manipulators
parent: Cookbook
nav_order: 4
---

# Transform manipulators

`ManipulatorWidget` is a three-axis translate or rotate gizmo bound to one `InteractiveObject`. It
renders on the viewport's overlay layer (always on top) and its picks route to the widget pick stream
rather than the user selection. `Manipulator+SwiftUI.swift` adds a SwiftUI gesture integration.

## Install a translate gizmo

```swift
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftAIS

let ais = InteractiveContext(viewport: ViewportController())
let part = ais.display(Shape.box(width: 10, height: 5, depth: 3)!)

let widget = ManipulatorWidget(target: part, mode: .translate)
widget.size = 6               // arrow length in world units; pick relative to the bbox
widget.shaftRadius = 0.05
widget.snapTranslate = 0.25   // snap drags to 0.25-unit increments
widget.onChange = { transform in /* live during drag */ }
widget.onCommit = { transform in /* on gesture release */ }
widget.install(in: ais)       // three axis-arrow bodies appear
```

`install(in:)` adds three arrow bodies tagged `ais.widget.<UUID>.<x|y|z>`. During a drag the target
body's transform becomes `preInstallTransform * widget.transform`, so the user sees the part move
live. `uninstall()` removes the handles and restores the pre-install transform.

## Rotate mode

Swap the mode and use `snapRotateDeg`; the gizmo renders three torus rings instead of arrows.

```swift
let rot = ManipulatorWidget(target: part, mode: .rotate)
rot.size = 6
rot.rotateRingRadius = 5         // major radius (defaults to size * 0.85)
rot.rotateTubeRadius = 0.06      // tube radius (defaults to shaftRadius * 1.2)
rot.snapRotateDeg = 15           // snap to 15° steps
rot.install(in: ais)
```

(`Mode.scale` is reserved — `hitTest` / `beginDrag` are no-ops for it.)

## SwiftUI integration

`.attachManipulator(_:)` wraps a viewport view with a `.highPriorityGesture(DragGesture)` that
hit-tests the widget on touch-down, drives its drag when a handle was grabbed, and otherwise forwards
the gesture to the camera (orbit). The widget must already be `install(in:)`-ed — the modifier reads
`widget.context` to find the viewport.

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

## Driving a drag manually

For a custom gesture stack, call the hit-test / drag API directly. NDC is `[-1, 1]` with +Y up.

```swift
let ndc: SIMD2<Float> = ...                  // your gesture point mapped to NDC
let cam = ais.viewport.cameraState
let aspect = ais.viewport.lastAspectRatio

if !widget.isDragging,
   let axis = widget.hitTest(ndc: ndc, camera: cam, aspect: aspect) {
    widget.beginDrag(axis: axis, ndc: ndc, camera: cam, aspect: aspect)
}
widget.updateDrag(ndc: ndc, camera: cam, aspect: aspect)
// On gesture end:
widget.endDrag(commit: true)                 // fires onCommit when commit == true
```

Observe `widget.transform`, `widget.isInstalled`, and `widget.activeAxis` (all `@Published`) to react
to the gizmo's state. `widget.reset()` snaps the transform back to identity.
