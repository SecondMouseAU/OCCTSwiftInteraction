---
title: Home
nav_order: 1
---

# OCCTSwiftAIS documentation

High-level **Application Interactive Services** for the OCCTSwift / OCCTSwiftViewport stack —
selection-from-topology, manipulator widgets, dimension annotations, and standard scene objects,
all in pure Swift for **macOS / iOS / visionOS / tvOS**.

OCCTSwiftAIS sits at the **top of the OCCT layered stack**: it adds scene-management semantics
(selection on topology, manipulators, dimensions) as a thin Swift layer above the kernel
(`OCCTSwift`), the Metal renderer (`OCCTSwiftViewport`), and the `Shape ↔ ViewportBody` bridge
(`OCCTSwiftTools`).

```
Application
   ↑
OCCTSwiftAIS         ← this package (selection / manipulators / dimensions)
   ↑
OCCTSwiftTools       ← bridge: Shape ↔ ViewportBody
   ↑      ↑
OCCTSwift  OCCTSwiftViewport
(B-Rep)    (Metal)
```

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
            .onAppear {
                if let part = Shape.box(width: 10, height: 5, depth: 3) {
                    ais.display(part)
                }
                ais.selectionMode = [.face]
            }
            .onChange(of: ais.selection) { _, sel in
                for face in sel.faces {
                    print("selected face area:", face.area())
                }
            }
    }
}
```

`InteractiveContext` owns the scene state — which `Shape`s are displayed, what's selected, what's
hovered, which dimensions exist — over one `ViewportController` from OCCTSwiftViewport. `$ais.bodies`
is the `Binding<[ViewportBody]>` that `MetalViewportView` renders.

## Cookbook

Task-oriented, example-rich guides — each a short bit of prose plus runnable Swift. The
**[Cookbook index](guides/cookbook/)** lists every area:

[Selecting sub-shapes](guides/cookbook/selecting-subshapes.md) ·
[Transform manipulators](guides/cookbook/manipulators.md) ·
[Dimensions](guides/cookbook/dimensions.md) ·
[Standard objects](guides/cookbook/standard-objects.md) ·
[Presentation styling](guides/cookbook/presentation-styling.md)

## Reference

The **[API Reference](reference/)** documents every public type and member with real signatures:
[Selection](reference/Selection.md) ·
[InteractiveContext](reference/InteractiveContext.md) ·
[Manipulators](reference/Manipulators.md) ·
[Dimensions](reference/Dimensions.md) ·
[Standard Objects](reference/StandardObjects.md) ·
[Presentation](reference/Presentation.md).

The **[Getting Started](guides/getting-started.md)** guide wires all of this into a SwiftUI app
step by step.

## Project

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/SecondMouseAU/OCCTSwiftAIS.git", from: "1.0.3"),
```

Then add `.product(name: "OCCTSwiftAIS", package: "OCCTSwiftAIS")` to your target. OCCTSwiftAIS
transitively pulls `OCCTSwiftTools`, `OCCTSwiftViewport`, and `OCCTSwift` — no need to declare
them separately.

- **Platforms:** macOS 15+, iOS 18+, visionOS 1+, tvOS 18+ (arm64). Same floor as OCCTSwiftViewport.
- **License:** LGPL 2.1 (matching OCCT).
- **Source:** [github.com/SecondMouseAU/OCCTSwiftAIS](https://github.com/SecondMouseAU/OCCTSwiftAIS)
