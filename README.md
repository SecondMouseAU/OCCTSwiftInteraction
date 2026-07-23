# OCCTSwiftCADKit

SwiftUI Metal viewport + CAD file import (STEP/STL/BREP) + face picking, for apps built on [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) and [OCCTSwiftViewport](https://github.com/SecondMouseAU/OCCTSwiftViewport).

Extracted from PadCAM's `CADViewportService`/`CADViewportView` so multiple OCCT-based apps (PadCAM, an UnfoldEngine test app, etc.) can share the same viewport plumbing without forking it.

## What's in the box

- `CADViewportService` — `@Observable` `@MainActor` service that owns the loaded `Shape`, drives the Metal viewport, and routes face-picking results back via `selectedFace: PickedFaceInfo?`. Caller-supplied geometry (stock boxes, toolpaths, flat-pattern outlines, custom annotations) is staged via `setOverlay(id:bodies:)`/`clearOverlay(id:)`.
- `CADViewportView` — SwiftUI wrapper around the Metal viewport with selection-info banner and display-mode controls.
- `PickedFaceInfo`, `FaceBounds` — face metadata returned by picking (no CAM- or unfold-specific dependencies).
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
            selectedFace: viewport.selectedFace,
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
