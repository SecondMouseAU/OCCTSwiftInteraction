---
title: Presentation styling
parent: Cookbook
nav_order: 7
---

# Presentation styling

`PresentationStyle` controls how a displayed `InteractiveObject` looks; `HighlightStyle` controls the
colors used for selected / hovered sub-shapes. Both are plain `Sendable` value types.

## Styling a displayed object

Pass a `PresentationStyle` to `display(_:style:)`, or change it later with `setStyle(_:for:)`.

```swift
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftAIS

let ais = InteractiveContext(viewport: ViewportController())

let style = PresentationStyle(
    color: SIMD3<Float>(0.7, 0.6, 0.4),
    transparency: 0.0,
    displayMode: .shadedWithEdges,
    visible: true
)
let part = ais.display(Shape.box(width: 10, height: 5, depth: 3)!, style: style)

// Restyle in place — e.g. ghost it out:
ais.setStyle(.ghosted, for: part)
```

`DisplayMode` is `.shaded`, `.wireframe`, or `.shadedWithEdges`. Note: `display(_:style:)` applies
`color`, `transparency`, and `visible` to the underlying `ViewportBody`; `displayMode` is carried on
the style for downstream use.

### Built-in presets

```swift
PresentationStyle.default      // light grey, shaded with edges
PresentationStyle.ghosted      // grey, 0.7 transparency, shaded
PresentationStyle.highlighted  // orange, shaded with edges
PresentationStyle.hovered      // cyan, shaded with edges
```

## Highlight colors

`HighlightStyle` sets the selection / hover colors used by the highlight overlay. Body-level
selections push to `viewport.selectedBodyIDs`; face-level selections write per-triangle styles tinted
with `selectionColor`.

```swift
ais.setHighlightStyle(HighlightStyle(
    selectionColor: SIMD3<Float>(1.0, 0.65, 0.0),  // orange
    hoverColor:     SIMD3<Float>(0.3, 0.8, 1.0),   // cyan (body-level only today)
    outlineWidth:   2.0
))
```

`setHighlightStyle(_:)` refreshes the current selection visuals immediately. `HighlightStyle.default`
is the orange-selection / cyan-hover pair shown above.
