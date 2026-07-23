# Getting started with OCCTSwiftCADKit

This guide walks through embedding the shared CAD viewport in a SwiftUI app, importing
STEP/STL/BREP files (single-shape or multi-entity/assembly), handling face/edge/vertex
pick selections (single or multi-select), and painting scalar fields (deviation heatmaps
and similar) over a body. Every snippet uses only the real public API of
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

## 9. Scalar field display (optional)

Paint a scalar value over a loaded body — deviation, curvature, wall thickness, confidence,
anything indexed by face or triangle — with `setScalarField(_:forBody:)`:

```swift
let deviationField = ScalarField(
    domain: .perFace,                    // or .perTriangle, for a mesh-domain value
    values: perFaceDeviationMM,          // [Double], indexed like PickedFaceInfo.faceIndex
    range: -2.0...2.0,                   // nil auto-ranges to values' own min/max
    colorMap: .diverging(center: 0),     // signed deviation: inside vs outside are different failures
    label: "deviation",
    unit: "mm"
)
viewport.setScalarField(deviationField, forBody: "candidate")
```

Updating or clearing a field (`setScalarField(nil, forBody:)`) rebuilds that body — its
geometry is unchanged, but currently this does re-upload the whole body, not just the
style buffer. That's a deliberate workaround, not the design: `OCCTSwiftViewport`'s own
`ViewportBody.triangleStyles` is documented to support a cheap in-place mutation instead,
but this was empirically confirmed (rendering before/after and comparing pixels) to
silently not update an already-rendered body against its currently-pinned floor — the
renderer only rebuilds GPU buffers when a body's `generation` changes, and an in-place
mutation never changes it. Once that's fixed upstream, this can switch back to the cheap
path with no change to `setScalarField`'s own signature.

`ColorMap` covers the common cases:

```swift
.viridis, .magma, .turbo              // sequential ramps for an unsigned magnitude
.diverging(center: 0)                 // two-sided ramp — use for signed deviation
.threshold(levels: [0.5, 1.0])        // discrete pass/warn/fail bands
.custom([(0.0, blue), (2.0, red)])    // explicit (value, color) stops, linearly interpolated
```

A face pick reports its scalar value directly — no separate lookup needed:

```swift
if case .face(let face)? = viewport.selection.first, viewport.selection.count == 1 {
    if let value = face.scalarValue {
        print("\(face.description): \(value) mm")
    }
}
```

The legend is part of the feature, not a nicety — read it to render a color bar with real
tick labels rather than a decorative gradient:

```swift
if let legend = viewport.scalarFieldLegend {
    Text("\(legend.label) (\(legend.unit ?? ""))")
    // legend.stops: [(value, color)], evenly spaced across legend.range
}
```

`scalarFieldLegend` reports the most recently set field (across whichever body it's on);
`scalarField(forBody:)` reads any particular body's field directly.

**Performance:** rebuilding a body's triangle styles scales linearly with triangle count.
Measured on this machine: a single body with 25,132 triangles took ~4.3ms per
`setScalarField` call (~0.17µs/triangle) — a synthetic proxy (a finely-tessellated
cylinder), not the actual reference corpus's own geometry, but representative of the cost
shape for a body at that scale.

## 10. Mesh/solid comparison (optional)

Reconstruction review means seeing a source mesh and a candidate solid together and
understanding where they differ. Load both as separate entities, then drive
`setComparison(_:)`:

```swift
viewport.load(sourceMesh, id: "reference")
viewport.load(reconstructedSolid, id: "candidate")

viewport.setComparison(ComparisonView(
    referenceID: "reference",
    candidateID: "candidate",
    mode: .overlay(referenceOpacity: 0.3)   // ghost the reference behind the candidate
))
```

Four modes:

```swift
.overlay(referenceOpacity: 0.3)      // reference ghosted behind the candidate
.deviation                            // candidate painted via the scalar field path (see below)
.sideBySide                           // candidate offset next to the reference, one shared camera
.wipe(axis: .x, position: 0)          // spatially split: reference below `position`, candidate above
```

`.deviation` doesn't compute anything itself — CADKit stays free of measurement
responsibility, matching the same trade-off `setScalarField` makes elsewhere. Compute the
per-face/per-triangle distance from candidate to reference yourself and set it first:

```swift
viewport.setScalarField(deviationField, forBody: "candidate")
viewport.setComparison(ComparisonView(referenceID: "reference", candidateID: "candidate", mode: .deviation))
```

Calling `setComparison` again — with a different mode, or updated `position`/
`referenceOpacity` for the same mode, e.g. while the user drags a wipe slider — first
undoes whatever the previous comparison did before applying the new one, so calls don't
compound. `setComparison(nil)` restores both entities to their plain display without
reloading either one.

`.wipe` is a plain CPU-side triangle filter (each body keeps only the triangles on its
side of the plane), not `ViewportController.clipPlanes` — that mechanism clips the whole
scene uniformly, so it can't show the reference and candidate differently. A side effect:
a wiped body's wireframe edges and vertex-picking aren't preserved, only its shaded
triangles — the split is a review affordance, not a full re-tessellation.

`.overlay`/`.sideBySide` mutate a body's color/transform in place — cheap, since the
renderer reads both fresh every frame rather than caching them (unlike the scalar-field
style buffer above). `.wipe` rebuilds each side's body (a fresh `generation`, like
`setScalarField` does), scaled to that body's triangle count.

## 11. Clipping and section planes (optional)

Cut away geometry to see inside a part — internal bores, pockets, ribs — or inspect exact
cross-sections along a prismatic axis:

```swift
let planeID = viewport.addClippingPlane(origin: .zero, normal: SIMD3(0, 0, 1))
```

Geometry on the side the normal points away from is hidden. By default
(`showCapSurface: true`) the cut also shows solid material rather than looking hollow — this
is a genuine B-Rep split and retessellation of the affected body(ies), not a shader trick
(`OCCTSwiftViewport` has no shader-level capping), so it costs real per-body geometry work on
every clipping-plane change, unlike the instant, GPU-only hollow clip underneath it.

For the common "step a plane along a prismatic axis" case, `sectionSweep` reuses a single
dedicated plane instead of accumulating one per call — safe to call every frame of a drag:

```swift
viewport.sectionSweep(axis: SIMD3(0, 0, 1), position: sliderValue)
```

If you're scrubbing quickly on complex geometry, disable capping for the duration of the
drag (cheap, instant hollow clip) and only turn it back on once the drag settles:

```swift
viewport.clippingPlanes[0].showCapSurface = isDragging ? false : true
```

Multiple planes compose — both the hollow clip and, for cap-enabled planes, the cut itself
(a sequential chain of splits, so the visible remainder is their intersection):

```swift
viewport.addClippingPlane(origin: .zero, normal: SIMD3(1, 0, 0), showCapSurface: false)
viewport.addClippingPlane(origin: .zero, normal: SIMD3(0, 1, 0), showCapSurface: false)
```

Picking respects active clipping planes — a face/edge/vertex pick's own position is tested
against every enabled plane before it resolves, even though `OCCTSwiftViewport`'s own GPU
pick pass doesn't do this itself, so clipped-away geometry never steals a pick.

```swift
viewport.removeClippingPlane(id: planeID)   // clears just that one; clippingPlanes = [] clears all
```

**Reload behavior:** capping doesn't automatically re-apply when you reload an entity under
an id that was previously capped (mirrors `setScalarField` not surviving a reload either —
same "caller re-applies" contract). Re-set `clippingPlanes = clippingPlanes` to force a
refresh without changing anything.

## 12. Escalation: asking a bounded question about geometry (optional)

The runtime half of a human-in-the-loop model — an agent (an MCP-connected reconstruction
pipeline, say) asks a question grounded in specific geometry and awaits an answer, without
needing to own the UI itself:

```swift
let request = EscalationRequest(
    id: "hole-42",
    entities: [pickedFace],           // highlighted automatically when presented
    question: "Through-hole or blind pocket?",
    candidates: [
        EscalationCandidate(id: "through", label: "Through-hole"),
        EscalationCandidate(id: "blind", label: "Blind pocket"),
    ],
    context: ["depth": "12.4mm", "diameter": "6.0mm"]
)

let response = await viewport.present(request)
```

`present(_:)` highlights `request.entities` the same way a real pick would (replacing the
current `selection`), shows any candidate's `previewBodyID` if supplied, and suspends until
answered. Elsewhere in your view hierarchy, observing the same `viewport`:

```swift
if let request = viewport.pendingEscalation {
    EscalationCardView(
        request: request,
        selection: viewport.selection,
        onChoose: { viewport.respond(.chose(candidateID: $0)) },
        onUseSelection: { viewport.respondWithCurrentSelection() },
        onDefer: { viewport.respond(.deferred) },
        onReject: { viewport.respond(.rejected(reason: $0)) }
    )
}
```

Two things make this more than a dialog box:

- **The request's entities are highlighted**, so the question is grounded in visible
  geometry rather than a floating description.
- **The human can answer by picking geometry instead of choosing a candidate** —
  `respondWithCurrentSelection()` wraps whatever `selection` currently holds in
  `.picked(...)`, for "none of those, this one."

`EscalationCardView` is one adaptive layout (capped to a comfortable phone-width column)
rather than separate macOS/iOS view types — usable as a floating panel on a larger surface
too. If a previous escalation is still pending when you call `present(_:)` again, it's
resolved `.deferred` first, so calling it repeatedly is always safe. Removing (or reloading)
an entity a pending escalation references — or a full `removeAll()` — auto-resolves it
`.rejected` rather than leaving `present(_:)` suspended over geometry that's gone.

## Next steps

- See [`docs/reference/CADViewportService.md`](../reference/CADViewportService.md) for the
  full public API: every method signature, the `ShapeBounds` / `PickedEntity` /
  `PickedFaceInfo` / `PickedEdgeInfo` / `PickedVertexInfo` / `SelectionSummary` /
  `ScalarField` / `ColorMap` / `ScalarFieldLegend` / `ComparisonView` / `ComparisonMode` /
  `Axis` / `ClippingPlane` / `EscalationRequest` / `EscalationCandidate` /
  `EscalationResponse` / `FaceBounds` types, and `CADViewportError`.
