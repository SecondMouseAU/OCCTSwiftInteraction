# OCCTSwiftCADKit

SwiftUI Metal viewport + CAD file import (STEP/STL/BREP) + face/edge/vertex picking + scalar field (deviation heatmap) display, for apps built on [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) and [OCCTSwiftViewport](https://github.com/SecondMouseAU/OCCTSwiftViewport).

Extracted from PadCAM's `CADViewportService`/`CADViewportView` so multiple OCCT-based apps (PadCAM, an UnfoldEngine test app, etc.) can share the same viewport plumbing without forking it.

## What's in the box

- `CADViewportService` — `@Observable` `@MainActor` service that owns the loaded geometry, drives the Metal viewport, and routes picking results back via `selection: [PickedEntity]`, gated by `selectionModes` (default face-only; opt into edge/vertex picking by adding `.edge`/`.vertex`). Build a multi-selection with `select(_:scheme:)` (`.replace`/`.add`/`.remove`/`.xor`, mirroring `OCCTSwiftAIS.SelectionScheme`); `selectionSummary` reports aggregate count/area/length/bounds. `load(_:id:transform:)`/`loadFile(from:id:progress:)` display several parts or assembly occurrences side by side as distinct, addressable entities (`loadedShapes`, `visibility`, `remove(id:)`, `focus(on:)`); the single-shape `loadFile(from:progress:)`/`loadShape(_:id:)` still work as a deprecated convenience. Caller-supplied geometry (stock boxes, toolpaths, flat-pattern outlines, custom annotations) is staged via `setOverlay(id:bodies:)`/`clearOverlay(id:)`.
- `CADViewportView` — SwiftUI wrapper around the Metal viewport with selection-info banner and display-mode controls.
- `PickedEntity` — `.face(PickedFaceInfo)` / `.edge(PickedEdgeInfo)` / `.vertex(PickedVertexInfo)`, each carrying durable identity (a `Shape` + optional `BRepGraph.GraphUID`) alongside an ephemeral render-path ordinal. No CAM- or unfold-specific dependencies.
- `SelectionSummary` — aggregate count by kind, total face area, total edge length, and combined bounds over the current selection.
- `ScalarField` / `ColorMap` / `ScalarFieldLegend` — paint a scalar value (deviation, curvature, wall thickness, confidence...) per face or per triangle via `setScalarField(_:forBody:)`; `.viridis`/`.magma`/`.turbo` sequential ramps, `.diverging(center:)` for signed values, `.threshold(levels:)` for discrete bands, `.custom(stops:)`. A face pick reports its value (`PickedFaceInfo.scalarValue`); `scalarFieldLegend` reports the range/unit/color stops for rendering a legend.
- `CADViewportError` — `unsupportedFormat`, `emptyFile`, `loadFailed`.

## Quick start

```swift
import OCCTSwiftCADKit
import SwiftUI

struct MyView: View {
    @State private var viewport = CADViewportService()

    var body: some View {
        CADViewportView(
            bodies: viewport.bodies,
            controller: viewport.controller,
            selection: viewport.selection,
            onClearSelection: { viewport.clearSelection() }
        )
        .task {
            try? await viewport.loadFile(from: URL(fileURLWithPath: "/path/to/part.step"))
        }
    }
}
```

### Adding overlays

Stock boxes, toolpaths, flat patterns — anything that isn't part of the imported model — go through the overlay API:

```swift
viewport.setOverlay(id: "stock", bodies: [stockBox])
viewport.setOverlay(id: "toolpath", bodies: rapidLines + cutLines)
viewport.clearOverlay(id: "toolpath")
```

Overlays composite in alphabetical order of their `id` (so use `0_stock`, `1_toolpath` if z-order matters).

## Dependencies

- [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) — geometry kernel (ships the binary `OCCT.xcframework`)
- [OCCTSwiftViewport](https://github.com/SecondMouseAU/OCCTSwiftViewport) — Metal renderer
- [OCCTSwiftTools](https://github.com/SecondMouseAU/OCCTSwiftTools) — `CADFileLoader`, `CADBodyMetadata`, `BodyUtilities` (its own repo since `OCCTSwiftViewport` 0.51.0 — no longer a target inside Viewport)
- [OCCTSwiftAIS](https://github.com/SecondMouseAU/OCCTSwiftAIS) — `InteractiveContext`, `ManipulatorWidget`, `Dimension`, sub-shape selection (exposed via `service.interactiveContext`)

URL-based SPM dependencies, pinned to floors in `Package.swift`. If a sibling checkout (`../<name>`) is present next to this repo, it's used instead — so a local OCCT-ecosystem checkout shares one `OCCT.xcframework` rather than each repo fetching its own copy. Fresh clones and CI always resolve the URL pin.

## Platforms

iOS 18+ / macOS 15+ (matching `OCCTSwiftViewport`'s Metal feature requirements).

## License

Private repository. No public license at this time.
