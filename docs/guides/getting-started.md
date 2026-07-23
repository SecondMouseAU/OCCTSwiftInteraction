# Getting started with OCCTSwiftCADKit

This guide walks through embedding the shared CAD viewport in a SwiftUI app, importing
STEP/STL/BREP files (single-shape or multi-entity/assembly), and handling face/edge/vertex
pick selections (single or multi-select). Every snippet uses only the real public API of
`OCCTSwiftCADKit`.

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
`selection`, and `clearSelection()` into a `CADViewportView`.

```swift
import OCCTSwiftCADKit
import SwiftUI

struct CADScreen: View {
    @State private var viewport = CADViewportService()

    var body: some View {
        CADViewportView(
            bodies: viewport.bodies,
            controller: viewport.controller,
            selection: viewport.selection,
            onClearSelection: { viewport.clearSelection() }
        )
    }
}
```

`CADViewportView` renders the Metal viewport with a selection-info banner (top) and
display-mode / standard-view controls (bottom-trailing) built in.

<!-- 3D render TODO: empty CADViewportView with the built-in controls -->

## 3. Import a STEP / STL / BREP file

`loadFile(from:)`/`loadShape(_:id:)`/`loadFromData(_:filename:)` are the deprecated,
single-shape convenience: each **replaces** every other model body. For loading several
parts or an assembly side by side, see [§4](#4-multi-body-and-assembly-loading-optional).

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
            selection: viewport.selection,
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

## 4. Multi-body and assembly loading (optional)

`load(_:id:transform:)` and `loadFile(from:id:progress:)` display several parts — or
several of an assembly's occurrences — as distinct, addressable **entities**, coexisting
rather than replacing one another. Unlike the deprecated single-shape overloads, camera
focus is *not* automatic; call `focus(on:)` once you've loaded what should be visible.

```swift
viewport.load(housingShape, id: "housing")
viewport.load(coverShape, id: "cover", transform: [
    1, 0, 0,
    0, 1, 0,
    0, 0, 1,
    0, 0, 45,       // 45mm along Z — a rigid 12-element affine matrix:
])                  // 9 rotation elements (row-major 3x3), then translation.
viewport.focus(on: ["housing", "cover"])
```

```swift
try await viewport.loadFile(from: partAURL, id: "partA")
try await viewport.loadFile(from: partBURL, id: "partB")
```

A file with several bodies (e.g. a multibody STEP/STL) registers as **one** entity whose
underlying body ids are `"<id>-0"`, `"<id>-1"`, etc. Loading again under an id already in
use replaces that entity.

```swift
viewport.loadedShapes                      // [String: OCCTSwift.Shape], keyed by entity id
viewport.shape(id: "housing")               // OCCTSwift.Shape?
viewport.visibility = ["cover": false]      // hide one entity
viewport.remove(id: "cover")                // drop one entity
viewport.removeAll()                        // drop every multi-entity load
```

A pick reports the **body** hit (`PickedEntity.bodyID`); map it back to the entity that
owns it with `entityID(forBodyID:)`:

```swift
for hit in viewport.selection {
    if let entityID = viewport.entityID(forBodyID: hit.bodyID) {
        print("hit entity:", entityID)
    }
}
```

The multi-entity API and the deprecated single-shape overloads are safe to mix — they
share one internal entity registry, so `loadShape(_:id:)`/`loadFile(from:progress:)`
(which still replace every model body) register what they load there too, and
`loadedShapes`/`visibility`/`removeAll()`/`entityID(forBodyID:)` all see it. `loadedShape`
(deprecated) still returns the single shape when exactly one entity is loaded, however it
was loaded.

### Memory behavior

Each occurrence loaded via `load(_:id:transform:)` is tessellated independently — v1 does
not deduplicate geometry across repeated instances of the same underlying part (an
assembly's "product and occurrence" model, where placement lives on the occurrence and
definitions are shared, is not implemented). Measured on this machine: loading 1245
occurrences of a plain 10×8×6mm box (a synthetic proxy — not the actual reference
corpus's own geometry, which is more complex) cost **~646 MB** resident memory, about
0.52 MB/occurrence. Real parts with more complex geometry (fillets, holes, threads) will
cost more per occurrence than this proxy. For an assembly with many repeated instances of
a small number of unique products, sharing tessellated geometry across occurrences of the
same product would very likely reduce memory substantially — worth a follow-up if
per-occurrence memory becomes a real constraint at your assembly's scale.

## 5. Handle a pick

Face picking is enabled by default. When the user taps a face, the service updates its
`selection` property (`[PickedEntity]`) — a real viewport pick always replaces the whole
selection with the one entity hit, so `selection` is `[.face(PickedFaceInfo)]` for a
single face pick. Because `CADViewportService` is `@Observable`, read `selection` directly
in your view to react.

```swift
struct CADScreen: View {
    @State private var viewport = CADViewportService()

    var body: some View {
        VStack {
            if case .face(let face)? = viewport.selection.first, viewport.selection.count == 1 {
                Text(face.description)                 // "Horizontal face at Z=20.0, 50.0x30.0mm"
                Text("Face #\(face.faceIndex) · area \(face.area, format: .number) mm²")
                Button("Clear") { viewport.clearSelection() }
            }

            CADViewportView(
                bodies: viewport.bodies,
                controller: viewport.controller,
                selection: viewport.selection,
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
if case .face(let face)? = viewport.selection.first, let occtFace = Face(face.shape) {
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

`selectedFace: PickedFaceInfo?` and `selected: PickedEntity?` still work as deprecated
conveniences — each non-nil only when the selection is exactly one entity (and, for
`selectedFace`, only when that entity is a face) — for callers not yet migrated to
`selection`.

## 6. Edge and vertex picking (optional)

Opt a body into edge and/or vertex picking via `selectionModes` (default `[.face]`):

```swift
viewport.selectionModes = [.face, .edge, .vertex]
```

`selection`'s entries now include `.edge(PickedEdgeInfo)` or `.vertex(PickedVertexInfo)`
too, each carrying the same durable-identity shape as `PickedFaceInfo` (`shape`/`uid`,
plus an ephemeral ordinal):

```swift
for entity in viewport.selection {
    switch entity {
    case .face(let face):
        print(face.description)
    case .edge(let edge):
        print(edge.description)             // "Line edge, 25.0mm"
        print(edge.startPoint, edge.endPoint)
    case .vertex(let vertex):
        print(vertex.description)           // "Vertex at (10.0, 5.0, 0.0)mm"
    }
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

## 7. Multi-selection (optional)

A real viewport pick always replaces the whole `selection` (see [§5](#5-handle-a-pick)).
Build a multi-selection programmatically with `select(_:scheme:)`:

```swift
viewport.select(faceA)                       // .replace (default) — selection = [faceA]
viewport.select(faceB, scheme: .add)         // selection = [faceA, faceB]
viewport.select(faceA, scheme: .remove)      // selection = [faceB]
viewport.select(faceB, scheme: .xor)         // toggles faceB off — selection = []
```

`SelectionScheme` is `OCCTSwiftAIS.SelectionScheme` (`.replace`/`.add`/`.remove`/`.xor`) —
the same combination semantics `selectRectangle`/`selectPolygon` area selection uses on
the AIS side. Membership follows `PickedEntity`'s own durable-identity `Equatable` (`uid`
when both sides have one), so the same face/edge/vertex is recognized as already-selected
even if it was picked at a different ephemeral ordinal.

Every selected entity is highlighted — a translucent yellow triangle patch aggregating
every selected face, a bright cyan polyline aggregating every selected edge's segments, a
bright magenta point sprite per selected vertex.

```swift
if let summary = viewport.selectionSummary {
    print(summary.faceCount, summary.edgeCount, summary.vertexCount)
    print(summary.totalArea, summary.totalLength)   // sums over selected faces/edges
    print(summary.bounds)                            // combined ShapeBounds, or nil if empty
}
```

The selection survives operations unrelated to it: removing an entity
(`remove(id:)`/`removeAll()`) drops only the selection entries that referenced *that*
entity's bodies, leaving everything else selected.

`selectedFace`/`selected` (both deprecated, see [§5](#5-handle-a-pick)) still work as
single-selection conveniences.

## 8. Overlays (optional)

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
  `PickedFaceInfo` / `PickedEdgeInfo` / `PickedVertexInfo` / `SelectionSummary` /
  `FaceBounds` types, and `CADViewportError`.
