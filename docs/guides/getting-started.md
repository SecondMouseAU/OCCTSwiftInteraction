# Getting started with OCCTSwiftCADKit

This guide walks through embedding the shared CAD viewport in a SwiftUI app, importing a
STEP/STL/BREP file, and handling face/edge/vertex pick selections. Every snippet uses
only the real public API of `OCCTSwiftCADKit`.

Platforms: iOS 18+ / macOS 15+.

## 1. Add the package

`OCCTSwiftCADKit` depends on the OCCTSwift ecosystem (`OCCTSwift`, `OCCTSwiftViewport`,
`OCCTSwiftTools`, `OCCTSwiftAIS`); Swift Package Manager resolves these transitively.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/SecondMouseAU/OCCTSwiftCADKit.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["OCCTSwiftCADKit"]),
]
```

```swift
import OCCTSwiftCADKit
import SwiftUI
```

## 2. Embed the viewport

Create a `CADViewportService` as `@State` and bind its `bodies`, `controller`,
`selected`, and `clearSelection()` into a `CADViewportView`.

```swift
import OCCTSwiftCADKit
import SwiftUI

struct CADScreen: View {
    @State private var viewport = CADViewportService()

    var body: some View {
        CADViewportView(
            bodies: viewport.bodies,
            controller: viewport.controller,
            selected: viewport.selected,
            onClearSelection: { viewport.clearSelection() }
        )
    }
}
```

`CADViewportView` renders the Metal viewport with a selection-info banner (top) and
display-mode / standard-view controls (bottom-trailing) built in.

<!-- 3D render TODO: empty CADViewportView with the built-in controls -->

## 3. Import a STEP / STL / BREP file

Call `loadFile(from:)` with a file URL — the extension picks the format
(`.step`/`.stp`, `.stl`, `.brep`). The camera auto-focuses on the loaded shape. Run it
from `.task` or a button action.

```swift
struct CADScreen: View {
    @State private var viewport = CADViewportService()

    var body: some View {
        CADViewportView(
            bodies: viewport.bodies,
            controller: viewport.controller,
            selected: viewport.selected,
            onClearSelection: { viewport.clearSelection() }
        )
        .task {
            do {
                let url = URL(fileURLWithPath: "/path/to/part.step")
                let shape = try await viewport.loadFile(from: url)
                print("Loaded \(shape.faces().count) faces")
            } catch let error as CADViewportError {
                print(error.errorDescription ?? "load failed")
            } catch {
                print("import failed:", error)
            }
        }
    }
}
```

<!-- 3D render TODO: viewport showing an imported STEP model -->

### Importing from a file picker (iOS)

When you only have `Data` (from `.fileImporter` or drag-and-drop), use
`loadFromData(_:filename:)` — the filename's extension drives format detection.

```swift
.fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
    guard case .success(let url) = result else { return }
    Task {
        let data = try Data(contentsOf: url)
        try await viewport.loadFromData(data, filename: url.lastPathComponent)
    }
}
```

### Displaying an in-memory shape

If you already have an `OCCTSwift.Shape` (built programmatically), skip the file loader
with `loadShape(_:id:)`.

```swift
let box = Shape.box(width: 50, height: 30, depth: 20)
viewport.loadShape(box, id: "model")
```

## 4. Handle a pick

Face picking is enabled by default. When the user taps a face, the service updates its
`selected` property (a `PickedEntity`, `.face(PickedFaceInfo)` for a face pick). Because
`CADViewportService` is `@Observable`, read `selected` directly in your view to react.

```swift
struct CADScreen: View {
    @State private var viewport = CADViewportService()

    var body: some View {
        VStack {
            if case .face(let face)? = viewport.selected {
                Text(face.description)                 // "Horizontal face at Z=20.0, 50.0x30.0mm"
                Text("Face #\(face.faceIndex) · area \(face.area, format: .number) mm²")
                Button("Clear") { viewport.clearSelection() }
            }

            CADViewportView(
                bodies: viewport.bodies,
                controller: viewport.controller,
                selected: viewport.selected,
                onClearSelection: { viewport.clearSelection() }
            )
        }
        .task {
            try? await viewport.loadFile(from: URL(fileURLWithPath: "/path/to/part.step"))
        }
    }
}
```

The picked entity is highlighted in the viewport automatically. To do further geometric
analysis, construct a `Face` from `face.shape` — the durable identity captured at pick
time — rather than re-deriving it from `face.faceIndex`:

```swift
if case .face(let face)? = viewport.selected, let occtFace = Face(face.shape) {
    // ...analyze occtFace via OCCTSwift...
}
```

`face.faceIndex` is the ephemeral render-path ordinal the pick came from — valid only
against that body's own tessellation. Don't use it to subscript
`loadedShape.faces()[face.faceIndex]`: once a face is shared between two shells, that
enumeration counts the shared face once per shell, so the same ordinal can name a
different face than the one actually picked. `face.uid` additionally carries a durable
`BRepGraph.GraphUID` when a graph was available at pick time — the handle that survives
a later mutation an ordinal alone does not.

<!-- 3D render TODO: viewport with a picked face highlighted and the selection banner -->

`selectedFace: PickedFaceInfo?` still works as a deprecated convenience — non-nil only
for face picks, `nil` for everything else including edge/vertex picks — for callers not
yet migrated off it.

## 5. Edge and vertex picking (optional)

Opt a body into edge and/or vertex picking via `selectionModes` (default `[.face]`):

```swift
viewport.selectionModes = [.face, .edge, .vertex]
```

`selected` now resolves to `.edge(PickedEdgeInfo)` or `.vertex(PickedVertexInfo)` too,
each carrying the same durable-identity shape as `PickedFaceInfo` (`shape`/`uid`, plus an
ephemeral ordinal):

```swift
switch viewport.selected {
case .face(let face):
    print(face.description)
case .edge(let edge):
    print(edge.description)             // "Line edge, 25.0mm"
    print(edge.startPoint, edge.endPoint)
case .vertex(let vertex):
    print(vertex.description)           // "Vertex at (10.0, 5.0, 0.0)mm"
case nil:
    break
}
```

A body whose `ViewportBody` has no `edgeIndices`/`vertices` populated (not edge/vertex
pickable, e.g. a loose mesh with no recovered solid) simply never produces an edge/vertex
pick on that body — face picking on the same body is unaffected. `selectionModes` also
gates face picking itself; remove `.face` to disable it.

`SelectionMode` is `OCCTSwiftAIS.SelectionMode` — the same type
`InteractiveContext.selectionMode` uses — but `CADViewportService.selectionModes` is an
entirely separate, independent selection system: the two don't share state, and
`SelectionMode.body` has no effect here (there's no whole-body `PickedEntity` case).

## 6. Overlays (optional)

Anything that isn't part of the imported model — stock boxes, toolpaths, flat-pattern
outlines, annotations — goes through named overlay layers. They composite with the model
and selection on every rebuild, in ascending `id` order.

```swift
viewport.setOverlay(id: "0_stock", bodies: [stockBox])
viewport.setOverlay(id: "1_toolpath", bodies: rapidLines + cutLines)
viewport.clearOverlay(id: "1_toolpath")
viewport.clearAllOverlays()
```

## Next steps

- See [`docs/reference/CADViewportService.md`](../reference/CADViewportService.md) for the
  full public API: every method signature, the `ShapeBounds` / `PickedEntity` /
  `PickedFaceInfo` / `PickedEdgeInfo` / `PickedVertexInfo` / `FaceBounds` types, and
  `CADViewportError`.
