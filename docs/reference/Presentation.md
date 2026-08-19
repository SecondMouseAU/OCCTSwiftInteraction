---
title: Presentation
parent: API Reference
---

# Presentation

Visual treatment for displayed objects and the highlight overlay. `PresentationStyle` controls how an
`InteractiveObject` looks; `DisplayMode` enumerates the render modes; `HighlightStyle` sets the
selection / hover colors. All are `Sendable` value types.

## Topics

- [DisplayMode](#displaymode) · [PresentationStyle](#presentationstyle) · [HighlightStyle](#highlightstyle)

---

## DisplayMode

```swift
public enum DisplayMode: Hashable, Sendable {
    case shaded
    case wireframe
    case shadedWithEdges
}
```

- **Example:**

```swift
let style = PresentationStyle(displayMode: .wireframe)
```

---

## PresentationStyle

How a displayed `InteractiveObject` looks. `display(_:style:)` applies `color`, `transparency`, and
`visible` to the underlying `ViewportBody`.

```swift
public struct PresentationStyle: Sendable, Equatable {
    public var color: SIMD3<Float>
    public var transparency: Float
    public var displayMode: DisplayMode
    public var visible: Bool

    public init(color: SIMD3<Float> = SIMD3<Float>(0.7, 0.7, 0.7),
                transparency: Float = 0,
                displayMode: DisplayMode = .shadedWithEdges,
                visible: Bool = true)

    public static let `default`: PresentationStyle      // light grey, shaded with edges
    public static let ghosted: PresentationStyle        // grey, 0.7 transparency, shaded
    public static let highlighted: PresentationStyle    // orange, shaded with edges
    public static let hovered: PresentationStyle        // cyan, shaded with edges
}
```

- **Parameters:** `color` — RGB; `transparency` — 0 (opaque) to 1; `displayMode`; `visible`.
- **Example:**

```swift
let part = ais.display(box, style: PresentationStyle(
    color: SIMD3<Float>(0.7, 0.6, 0.4), displayMode: .shadedWithEdges))
ais.setStyle(.ghosted, for: part)
```

---

## HighlightStyle

Colors used by the highlight overlay for selected and hovered sub-shapes.

```swift
public struct HighlightStyle: Sendable, Equatable {
    public var selectionColor: SIMD3<Float>
    public var hoverColor: SIMD3<Float>
    public var outlineWidth: Float

    public init(selectionColor: SIMD3<Float> = SIMD3<Float>(1.0, 0.65, 0.0),   // orange
                hoverColor: SIMD3<Float> = SIMD3<Float>(0.3, 0.8, 1.0),        // cyan
                outlineWidth: Float = 2.0)

    public static let `default`: HighlightStyle
}
```

- **Parameters:** `selectionColor` — tint for selected sub-shapes; `hoverColor` — hover tint
  (body-level only today); `outlineWidth` — outline width.
- **Example:**

```swift
ais.setHighlightStyle(HighlightStyle(
    selectionColor: SIMD3<Float>(1, 0.65, 0),
    hoverColor:     SIMD3<Float>(0.3, 0.8, 1),
    outlineWidth:   2.0
))
```
