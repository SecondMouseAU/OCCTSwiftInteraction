# CADViewportService — API reference

`OCCTSwiftCADKit` provides a shared SwiftUI Metal CAD viewport: import STEP/STL/BREP
geometry, render it, route face/edge/vertex-picking results — single or multi-select —
back to your app, and paint scalar fields (deviation heatmaps and similar) over a body.
The public surface is `CADViewportService` (the controller/state owner), `CADViewportView`
(the SwiftUI view), the `PickedEntity`/`PickedFaceInfo`/`PickedEdgeInfo`/`PickedVertexInfo`/
`SelectionSummary`/`ScalarField`/`ColorMap`/`ScalarFieldLegend`/`LegendStop`/`FaceBounds`
result types, and `CADViewportError`.

```swift
import OCCTSwiftCADKit
```

Platforms: iOS 18+ / macOS 15+ (Metal feature requirements from `OCCTSwiftViewport`).

---

## `CADViewportService`

```swift
@MainActor
@Observable
public final class CADViewportService
```

`@Observable` `@MainActor` service that owns the loaded B-Rep `Shape`, drives the Metal
viewport, and routes picking results back to the caller via `selection`. Caller-supplied
geometry (stock boxes, toolpaths, flat-pattern outlines, annotations) is staged through
the overlay API and composited with the model bodies and any selection highlights on
every viewport rebuild.

### Initializer

```swift
public init(configuration: _ViewportConfiguration = .init(
    rotationStyle: .turntable,
    displayMode: .shadedWithEdges,
    lightingConfiguration: .threePoint,
    showViewCube: true,
    showAxes: true,
    showGrid: true,
    pickingConfiguration: _PickingConfiguration(isEnabled: true)
))
```

Constructs the underlying `_ViewportController` and `InteractiveContext`. Pass a custom
`_ViewportConfiguration` (from `OCCTSwiftViewport`) to change rotation style, display
mode, lighting, overlays, or picking. The default configuration enables face picking.

```swift
// Default configuration (picking on, shaded-with-edges, turntable rotation):
let viewport = CADViewportService()

// Custom: wireframe, no grid, picking disabled.
let custom = CADViewportService(configuration: .init(
    rotationStyle: .turntable,
    displayMode: .wireframe,
    lightingConfiguration: .threePoint,
    showViewCube: true,
    showAxes: true,
    showGrid: false,
    pickingConfiguration: _PickingConfiguration(isEnabled: false)
))
```

### Properties

| Property | Type | Description |
| --- | --- | --- |
| `controller` | `_ViewportController` | Viewport controller — camera, display mode, picking config. Bind into `CADViewportView`. |
| `interactiveContext` | `InteractiveContext` | AIS interactive context backed by this viewport. Install `ManipulatorWidget`, dimensions, or extra `InteractiveObject`s here; appended bodies are composited with the CADKit-owned bodies. |
| `bodies` | `[_ViewportBody]` | All bodies currently displayed: model bodies + overlay layers + selection highlight + AIS-owned bodies. Read-only; mirrors `interactiveContext.bodies`. |
| `loadedShape` | `OCCTSwift.Shape?` | **Deprecated**, use `loadedShapes`/`shape(id:)`. Non-nil only when exactly one entity is loaded, however it was loaded. |
| `loadedShapes` | `[String: OCCTSwift.Shape]` | Multi-entity loads, keyed by entity id (see [Multi-body / assembly](#multi-body--assembly)). |
| `selection` | `[PickedEntity]` | Every currently selected face/edge/vertex. Read-only; a real pick replaces it wholesale — build a multi-selection with `select(_:scheme:)`. |
| `selectionSummary` | `SelectionSummary?` | Aggregate measures over `selection` — count by kind, total area/length, combined bounds. `nil` when empty. |
| `selected` | `PickedEntity?` | **Deprecated**, use `selection`. Non-nil only when the selection is exactly one entity. |
| `selectionModes` | `Set<SelectionMode>` | Which sub-shape kinds picking resolves. Defaults to `[.face]`. |
| `selectedFace` | `PickedFaceInfo?` | **Deprecated**, use `selection`. Non-nil only when the selection is exactly one face. |
| `shapeBounds` | `ShapeBounds?` | Axis-aligned bounds of the single loaded shape, or `nil` (see `loadedShape`'s single-entity caveat). |
| `overlayIDs` | `[String]` | Sorted ids of overlay layers currently staged. |
| `visibility` | `[String: Bool]` | Per-entity visibility, keyed by entity id. |
| `scalarFieldLegend` | `ScalarFieldLegend?` | Legend for the most recently set scalar field (see [Scalar fields](#scalar-fields)). `nil` if none is set. |

### File import (single-shape, deprecated)

`loadFile(from:progress:)`, `loadShape(_:id:)`, and `loadFromData(_:filename:progress:)`
each **replace every model body**, including any loaded via the multi-entity API below —
safe to mix with it, since both register in the same internal entity registry. See
[Multi-body / assembly](#multi-body--assembly) for loading several parts or an assembly.

```swift
@available(*, deprecated)
@discardableResult
public func loadFile(from url: URL, progress: ImportProgress? = nil) async throws -> OCCTSwift.Shape
```

Loads a CAD file from disk into the viewport and returns the loaded `Shape`. The
extension selects the format: `.step`/`.stp` → STEP, `.stl` → STL, `.brep` → BREP.
The camera is automatically focused on the shape's bounding box.

- **Parameters:**
  - `url` — file URL on disk.
  - `progress` — optional `ImportProgress` (e.g. `ImportProgressClosure`) to observe
    STEP/IGES import progress and request cooperative cancellation.
- **Returns:** the first loaded `OCCTSwift.Shape`.
- **Throws:** `CADViewportError.unsupportedFormat(ext)` for any other extension;
  `CADViewportError.emptyFile` if the file contains no geometry; `ImportError.cancelled`
  if cancelled via `progress`.

```swift
let url = URL(fileURLWithPath: "/path/to/part.step")
let shape = try await viewport.loadFile(from: url)
print("Loaded shape with \(shape.faces().count) faces")
```

```swift
// Observe progress and allow cancellation.
let progress = ImportProgressClosure { fraction in
    print("import \(Int(fraction * 100))%")
}
try await viewport.loadFile(from: url, progress: progress)
```

---

```swift
@available(*, deprecated)
public func loadShape(_ shape: OCCTSwift.Shape, id: String = "model")
```

Displays an in-memory `OCCTSwift.Shape` (e.g. one built programmatically) without going
through the file loader. Tessellates the shape, replaces the model bodies, clears any
selection, and re-focuses the camera.

```swift
let box = Shape.box(width: 50, height: 30, depth: 20)
viewport.loadShape(box, id: "stockModel")
```

---

```swift
@available(*, deprecated)
@discardableResult
public func loadFromData(_ data: Data, filename: String, progress: ImportProgress? = nil) async throws -> OCCTSwift.Shape
```

Convenience for callers that have file `Data` rather than a URL (e.g. `.fileImporter`
results or drag-and-drop on iOS). Writes the data to a temporary file named `filename`
(the extension drives format detection), loads it, and removes the temp file. Same
return value and errors as `loadFile(from:progress:)`.

```swift
// From a SwiftUI .fileImporter result:
let data = try Data(contentsOf: pickedURL)
try await viewport.loadFromData(data, filename: pickedURL.lastPathComponent)
```

### Multi-body / assembly

Several parts — or several of an assembly's occurrences — can display simultaneously as
distinct, addressable **entities**, rather than one replacing another. Shares one entity
registry with the deprecated single-shape overloads above (see their note), so
`loadedShapes`/`visibility`/`removeAll()`/`entityID(forBodyID:)` see everything currently
loaded regardless of which API loaded it.

```swift
@discardableResult
public func load(_ shape: OCCTSwift.Shape, id: String, transform: [Double]? = nil) -> String

@discardableResult
public func loadFile(from url: URL, id: String, progress: ImportProgress? = nil) async throws -> String

@discardableResult
public func loadFromData(_ data: Data, filename: String, id: String, progress: ImportProgress? = nil) async throws -> String
```

- **`id`** — the entity id. Loading again under an id already in use replaces that
  entity. Required on every overload (unlike the deprecated `loadFile(from:progress:)`
  family's implicit single entity) — a defaulted `id` would make e.g.
  `loadFile(from: url)` ambiguous against the deprecated 2-argument overload.
- **`transform`** (`load` only) — places the shape before tessellating it. A rigid
  12-element affine matrix matching `OCCTSwift.Shape.transformed(matrix:)`'s layout:
  `[r00,r01,r02, r10,r11,r12, r20,r21,r22, tx,ty,tz]` (row-major 3x3 rotation, then
  translation). `nil` (default) leaves the shape as-is.
- **Returns:** `id`, echoed back.
- A file with several bodies (e.g. a multibody STEP/STL) registers as **one** entity
  whose underlying body ids are `"<id>-0"`, `"<id>-1"`, etc.
- Camera is **not** auto-focused (unlike the deprecated single-shape overloads) — call
  `focus(on:)` explicitly.

```swift
viewport.load(housingShape, id: "housing")
viewport.load(coverShape, id: "cover", transform: [
    1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 45,   // 45mm along Z
])
try await viewport.loadFile(from: partAURL, id: "partA")
```

```swift
public func remove(id: String)                                    // remove one entity
public func removeAll()                                           // remove every multi-entity load
public var loadedShapes: [String: OCCTSwift.Shape] { get }        // keyed by entity id
public func shape(id: String) -> OCCTSwift.Shape?
public func entityID(forBodyID bodyID: String) -> String?         // which entity owns a pick's bodyID
public var visibility: [String: Bool] { get set }                 // per-entity visibility
public func focus(on ids: [String])                               // frame the camera on a subset
```

```swift
viewport.visibility = ["cover": false]
viewport.focus(on: ["housing"])
viewport.remove(id: "cover")

for hit in viewport.selection {
    if let entityID = viewport.entityID(forBodyID: hit.bodyID) {
        print("hit entity:", entityID)
    }
}
```

**Memory behavior:** each occurrence loaded via `load(_:id:transform:)` is tessellated
independently — v1 does not deduplicate geometry across repeated instances of the same
part (an assembly's shared-definition/occurrence model is not implemented). Measured on
this machine: 1245 occurrences of a plain 10×8×6mm box (a synthetic proxy, not the actual
reference corpus's own geometry) cost ~646 MB resident memory, ~0.52 MB/occurrence — real
parts will cost more per occurrence than this proxy. Sharing tessellated geometry across
occurrences of the same product would very likely reduce memory substantially for an
assembly with many repeated instances of a small number of unique products; worth a
follow-up if this becomes a real constraint.

### Overlay layers

Overlays are named layers of caller-managed geometry, composited with the model and
selection highlight on every viewport rebuild. Layers composite in ascending order of
their `id` (use `0_stock`, `1_toolpath` if z-order matters).

```swift
public func setOverlay(id: String, bodies: [_ViewportBody])  // add or replace a layer
public func clearOverlay(id: String)                          // remove one layer
public func clearAllOverlays()                                // remove every layer (model + selection untouched)
public var overlayIDs: [String] { get }                       // sorted layer ids
```

```swift
viewport.setOverlay(id: "0_stock", bodies: [stockBox])
viewport.setOverlay(id: "1_toolpath", bodies: rapidLines + cutLines)
viewport.clearOverlay(id: "1_toolpath")
print(viewport.overlayIDs) // ["0_stock"]
```

<!-- 3D render TODO: viewport with a model plus a stock-box overlay -->

### Selection

```swift
public func clearSelection()

public func select(_ entity: PickedEntity, scheme: SelectionScheme = .replace)
```

`clearSelection()` empties `selection` and removes the highlight bodies. A real viewport
pick always calls `select(_:scheme: .replace)` internally — matching `OCCTSwiftAIS`'s own
point-pick behavior — so `selection` becomes `[thatOneEntity]` on every plain pick.
`selectionModes` (default `[.face]`) gates which kinds resolve; add `.edge`/`.vertex` to
opt into edge/vertex picking, or remove `.face` to disable face picking.

```swift
// React to picks (e.g. inside a SwiftUI view observing the @Observable service):
for entity in viewport.selection {
    switch entity {
    case .face(let face):
        print(face.description)            // e.g. "Horizontal face at Z=20.0, 50.0x30.0mm"
        print("face index:", face.faceIndex)
    case .edge(let edge):
        print(edge.description)            // e.g. "Line edge, 25.0mm"
    case .vertex(let vertex):
        print(vertex.description)          // e.g. "Vertex at (10.0, 5.0, 0.0)mm"
    }
}

// Opt into edge/vertex picking (default is face-only):
viewport.selectionModes = [.face, .edge, .vertex]

// Programmatically clear:
viewport.clearSelection()
```

Each highlight is visually distinguishable by kind: a translucent yellow triangle patch
aggregating every selected face's own triangles, a bright cyan polyline aggregating every
selected edge's segments, a bright magenta point sprite per selected vertex. A body whose
`ViewportBody` has no `edgeIndices`/`vertices` populated (not edge/vertex pickable) simply
never produces an edge/vertex pick on that body — face picking on the same body is
unaffected.

`SelectionMode` is `OCCTSwiftAIS.SelectionMode` (the same type
`InteractiveContext.selectionMode` uses), but `selectionModes` is an independent
selection system — the two don't share state, and `SelectionMode.body` has no effect
here (there's no whole-body `PickedEntity` case).

<!-- 3D render TODO: viewport with a picked face highlighted in yellow -->
<!-- 3D render TODO: viewport with a picked edge highlighted in cyan -->
<!-- 3D render TODO: viewport with a picked vertex highlighted in magenta -->

### Multi-selection

Build a selection spanning more than one entity with `select(_:scheme:)`:

```swift
public func select(_ entity: PickedEntity, scheme: SelectionScheme = .replace)
```

- **`scheme`** — `OCCTSwiftAIS.SelectionScheme` (`.replace`/`.add`/`.remove`/`.xor`), the
  same combination semantics `selectRectangle`/`selectPolygon` area selection uses on the
  AIS side. `.replace` (default) assigns `selection = [entity]`; `.add` appends if not
  already present; `.remove` drops it; `.xor` toggles it. Membership uses `PickedEntity`'s
  own `uid`-preferring `Equatable`, so the same durable face/edge/vertex is recognized as
  already-selected regardless of which ephemeral ordinal it was picked at this time.

```swift
viewport.select(faceA)                       // selection = [faceA]
viewport.select(faceB, scheme: .add)         // selection = [faceA, faceB]
viewport.select(faceA, scheme: .remove)      // selection = [faceB]
viewport.select(faceB, scheme: .xor)         // selection = []
```

The selection survives operations unrelated to it: `remove(id:)`/`removeAll()` drop only
the selection entries that referenced the removed entity's bodies, leaving the rest
selected — the selection honestly reports what's gone by no longer containing it, rather
than either lingering on stale picks or being wiped wholesale for an unrelated change.

```swift
public var selectionSummary: SelectionSummary? { get }
```

Aggregate measures over the current selection — see [`SelectionSummary`](#selectionsummary).
`nil` when `selection` is empty.

```swift
if let summary = viewport.selectionSummary {
    print(summary.faceCount, summary.edgeCount, summary.vertexCount)
    print(summary.totalArea, summary.totalLength)
    print(summary.bounds)
}
```

### Scalar fields

```swift
public func setScalarField(_ field: ScalarField?, forBody id: String)
public func scalarField(forBody id: String) -> ScalarField?
public var scalarFieldLegend: ScalarFieldLegend? { get }
```

`setScalarField` paints (or, with `nil`, clears) a scalar value per face or per triangle
over a loaded body — deviation, curvature, wall thickness, confidence: anything indexed by
face ordinal or triangle.

**Current cost:** this rebuilds the whole body (a fresh `generation`), not just its GPU
`TriangleStyle` buffer. `OCCTSwiftViewport`'s own `ViewportBody.triangleStyles` is
documented to support a cheap in-place mutation instead (`generation` unchanged, only the
style buffer re-uploads) — but that was empirically confirmed to silently not update an
already-rendered body against `OCCTSwiftViewport`'s currently-pinned floor: its renderer
only rebuilds a body's GPU buffers when `generation` changes, and an in-place
`triangleStyles` mutation never changes it. This is a workaround for what looks like an
upstream caching bug, tracked as a known limitation — `setScalarField`'s own signature
won't need to change if/when it's fixed upstream.

```swift
let field = ScalarField(
    domain: .perFace,
    values: perFaceDeviationMM,           // [Double], indexed like PickedFaceInfo.faceIndex
    range: -2.0...2.0,                    // nil auto-ranges to values' own min/max
    colorMap: .diverging(center: 0),
    label: "deviation",
    unit: "mm"
)
viewport.setScalarField(field, forBody: "candidate")
viewport.scalarField(forBody: "candidate")   // ScalarField? — round-trips what was set
viewport.setScalarField(nil, forBody: "candidate")   // clears it
```

`scalarFieldLegend` reports the most recently set (still-active) field's label, unit,
range, and evenly-spaced color stops — read it to render a color bar with real tick
labels; an unlabelled heatmap is decorative. Removing/replacing a body clears its field
(and the legend, if it was that body's field being reported).

```swift
if let legend = viewport.scalarFieldLegend {
    print(legend.label, legend.unit ?? "", legend.range)
    for stop in legend.stops { print(stop.value, stop.color) }
}
```

A face pick reports its scalar value directly (`PickedFaceInfo.scalarValue: Double?`) —
see [`PickedFaceInfo`](#pickedfaceinfo). `nil` when no field is set on that body.

See [`ScalarField`](#scalarfield) / [`ColorMap`](#colormap) / [`ScalarFieldLegend`](#scalarfieldlegend)
for the full type definitions.

### Comparison

```swift
public private(set) var comparison: ComparisonView?
public func setComparison(_ comparison: ComparisonView?)
```

Displays two already-loaded entities against each other — typically a source mesh
(`referenceID`) and a reconstructed solid (`candidateID`) — for reconstruction review.
Settable and clearable repeatedly (including switching to a different mode, or a different
`position`/`referenceOpacity` for the same mode) without reloading either entity: each call
first undoes whatever the previous comparison did before applying the new one.

```swift
viewport.load(sourceMesh, id: "reference")
viewport.load(reconstructedSolid, id: "candidate")

viewport.setComparison(ComparisonView(referenceID: "reference", candidateID: "candidate", mode: .overlay(referenceOpacity: 0.3)))
viewport.setComparison(ComparisonView(referenceID: "reference", candidateID: "candidate", mode: .wipe(axis: .x, position: 0)))
viewport.setComparison(nil)   // restores both entities' plain display
```

- **`.overlay(referenceOpacity:)`** ghosts the reference by lowering its bodies' alpha
  (clamped to `0...1`). An in-place mutation of `_ViewportBody.color` — safe, since the
  renderer reads `color` fresh into its per-frame uniforms rather than caching it behind
  `generation` the way `triangleStyles` is (see the [scalar fields](#scalar-fields)
  section above for that distinction).
- **`.deviation`** is a marker only — CADKit doesn't compute the reference-to-candidate
  distance itself. Call `setScalarField(_:forBody:)` on the candidate with the
  precomputed values first; this mode just records that deviation display is active, so
  clearing it (`setComparison(nil)`, or switching to a different mode) also clears the
  candidate's scalar field.
- **`.sideBySide`** offsets the candidate's bodies along X so it sits beside the reference
  rather than overlapping it, via `_ViewportBody.transform` (also read live per frame, so
  no re-tessellation). Since there's only ever one camera/viewport, "linked cameras" is
  automatic.
- **`.wipe(axis:position:)`** spatially splits the two at a plane perpendicular to `axis`
  at world coordinate `position`: the reference is visible where its geometry's
  coordinate along `axis` is less than `position`, the candidate where it's greater or
  equal. Implemented by filtering each body's own triangles (not
  `ViewportController.clipPlanes`, which clips the whole scene uniformly and can't show
  the two sides differently) — see `CLAUDE.md`'s "Things to be careful about" for why, and
  what a wiped body loses (wireframe edges, vertex-picking) as a result.

`comparison` reports the currently active `ComparisonView`, or `nil`. Removing (or
reloading, which removes then re-adds) either the reference or candidate entity clears the
comparison rather than leaving it referencing stale geometry.

See [`ComparisonView`](#comparisonview) / [`ComparisonMode`](#comparisonmode) /
[`Axis`](#axis) for the full type definitions.

### `CADViewportService.ShapeBounds`

```swift
public struct ShapeBounds: Sendable, Equatable {
    public let minX, minY, minZ: Double
    public let maxX, maxY, maxZ: Double
    public var sizeX: Double { maxX - minX }
    public var sizeY: Double { maxY - minY }
    public var sizeZ: Double { maxZ - minZ }
}
```

Axis-aligned bounds of the loaded shape, returned by the `shapeBounds` property.

```swift
if let b = viewport.shapeBounds {
    print("size:", b.sizeX, b.sizeY, b.sizeZ)
}
```

---

## `CADViewportView`

```swift
public struct CADViewportView: View
```

SwiftUI wrapper around the Metal viewport, with a selection-info banner (top) and
display-mode + standard-view controls (bottom-trailing). Bind it to a
`CADViewportService`.

### Initializer

```swift
public init(
    bodies: [_ViewportBody],
    controller: _ViewportController,
    selection: [PickedEntity] = [],
    onClearSelection: (() -> Void)? = nil
)
```

- **`bodies`** — the bodies to render; pass `service.bodies`.
- **`controller`** — the viewport controller; pass `service.controller`.
- **`selection`** — the selected entities to show in the banner; pass `service.selection`.
- **`onClearSelection`** — invoked by the banner's close button; wire to `service.clearSelection()`.

The built-in controls set `controller.displayMode` (`.shaded`, `.shadedWithEdges`,
`.wireframe`) and call `controller.goToStandardView(.isometricFrontRight)`.

```swift
CADViewportView(
    bodies: viewport.bodies,
    controller: viewport.controller,
    selection: viewport.selection,
    onClearSelection: { viewport.clearSelection() }
)
```

The banner shows the single entity's description when `selection.count == 1`, or "N
selected" for a larger selection — for a richer multi-selection summary, build your own
UI from `service.selectionSummary` alongside `CADViewportView`.

Two deprecated overloads still work for callers not yet migrated: `init(bodies:controller:
selected:onClearSelection:)` (wraps a single `PickedEntity?` into `selection`) and
`init(bodies:controller:selectedFace:onClearSelection:)` (wraps a single `PickedFaceInfo?`
into `.face(_:)`).

<!-- 3D render TODO: CADViewportView with selection banner and display-mode controls -->

---

## `PickedEntity`

```swift
public enum PickedEntity: Sendable, Equatable {
    case face(PickedFaceInfo)
    case edge(PickedEdgeInfo)
    case vertex(PickedVertexInfo)

    public var bodyID: String { get }
}
```

A pick result generalised over which kind of sub-shape was hit. `CADViewportService.selection`
is `[PickedEntity]`. Every case's payload shares the same durable-identity shape (`shape`/`uid`,
plus an ephemeral render-path ordinal). `bodyID` reads whichever case's `bodyID` field,
regardless of kind — pass it to `entityID(forBodyID:)` to find which multi-entity load (if
any) owns the picked body.

## `PickedFaceInfo`

```swift
public struct PickedFaceInfo: Sendable, Equatable {
    public let shape: OCCTSwift.Shape        // durable: the picked face's own Shape
    public let uid: BRepGraph.GraphUID?      // durable: minted from the body's BRepGraph, when available
    public let faceIndex: Int                // ephemeral: render-path ordinal, this body's tessellation only
    public let bodyID: String
    public let isHorizontal: Bool
    public let isVertical: Bool
    public let bounds: FaceBounds
    public let zLevel: Float?
    public let area: Double
    public let description: String  // e.g. "Horizontal face at Z=20.0, 50.0x30.0mm"
    public let scalarValue: Double? // this face's value from the body's ScalarField, if any
}
```

Metadata about a face picked in the viewport. `shape` and `uid` are the durable identity
of the pick, captured once at pick time from the picked body's `FaceIdentityTable`.
`faceIndex` is the ephemeral render-path ordinal the pick came from — valid only against
that body's own tessellation. Don't subscript `loadedShape.faces()[faceIndex]` to
re-derive the face: once a face is shared between two shells, that non-deduplicating
traversal counts the shared face once per shell, so the same ordinal can silently name a
different face than the one actually picked. Construct a `Face` from `shape` instead.
`scalarValue` is resolved from `setScalarField(_:forBody:)`'s field at pick time — `nil`
unless a field is set on this body. No CAM- or unfold-specific dependencies.

```swift
if case .face(let face)? = viewport.selection.first, viewport.selection.count == 1, let occtFace = Face(face.shape) {
    print("area:", face.area, "horizontal:", face.isHorizontal)
    print("durable handle available:", face.uid != nil)
}
```

## `PickedEdgeInfo`

```swift
public struct PickedEdgeInfo: Sendable, Equatable {
    public let shape: OCCTSwift.Shape
    public let uid: BRepGraph.GraphUID?
    public let edgeIndex: Int                 // ephemeral: render-path ordinal into edgeIndices
    public let bodyID: String
    public let curveType: OCCTSwift.Edge.CurveType
    public let length: Double
    public let startPoint: SIMD3<Double>
    public let endPoint: SIMD3<Double>
    public let description: String  // e.g. "Line edge, 25.0mm"
}
```

Metadata about an edge picked in the viewport. Only produced when `selectionModes`
contains `.edge`, and only for bodies with `edgeIndices` populated. `shape`/`uid` are the
durable identity, captured from the picked body's `EdgeIdentityTable`; construct an
`Edge` from `shape` (`Edge(shape)`) for edge-specific queries beyond `curveType`/
`length`/`startPoint`/`endPoint`.

```swift
if case .edge(let edge)? = viewport.selection.first, viewport.selection.count == 1 {
    print(edge.curveType, edge.length, edge.startPoint, edge.endPoint)
}
```

## `PickedVertexInfo`

```swift
public struct PickedVertexInfo: Sendable, Equatable {
    public let shape: OCCTSwift.Shape
    public let uid: BRepGraph.GraphUID?
    public let vertexIndex: Int               // ephemeral: render-path ordinal into vertexIndices
    public let bodyID: String
    public let position: SIMD3<Double>
    public let description: String  // e.g. "Vertex at (10.0, 5.0, 0.0)mm"
}
```

Metadata about a vertex picked in the viewport. Only produced when `selectionModes`
contains `.vertex`, and only for bodies with `vertices` populated. `shape`/`uid` are the
durable identity, captured from the picked body's `VertexIdentityTable`; `position` is
the world-space location (also available as `shape.vertices().first`, since OCCTSwift
exposes vertices positionally rather than as their own class).

```swift
if case .vertex(let vertex)? = viewport.selection.first, viewport.selection.count == 1 {
    print(vertex.position)
}
```

## `SelectionSummary`

```swift
public struct SelectionSummary: Sendable, Equatable {
    public let faceCount: Int
    public let edgeCount: Int
    public let vertexCount: Int
    public let totalArea: Double                       // sum of PickedFaceInfo.area
    public let totalLength: Double                     // sum of PickedEdgeInfo.length
    public let bounds: CADViewportService.ShapeBounds?  // combined 3D bounds
}
```

Aggregate measures over `CADViewportService.selection`, returned by `selectionSummary`.
`bounds` combines every selected entity's own bounds (a face/edge's geometric bounds, or a
vertex's position as a zero-size bounds) — `nil` only when the selection is empty, in
which case `selectionSummary` itself is `nil` too.

```swift
if let summary = viewport.selectionSummary {
    print("\(summary.faceCount) faces, \(summary.edgeCount) edges, \(summary.vertexCount) vertices")
    print("total area:", summary.totalArea, "total length:", summary.totalLength)
    if let b = summary.bounds { print("size:", b.sizeX, b.sizeY, b.sizeZ) }
}
```

## `ScalarField`

```swift
public struct ScalarField: Sendable {
    public enum Domain: Sendable, Equatable { case perFace, perTriangle }
    public let domain: Domain
    public let values: [Double]              // indexed by face ordinal (.perFace) or triangle (.perTriangle)
    public let range: ClosedRange<Double>?   // nil auto-ranges to values' own min/max
    public let colorMap: ColorMap
    public let label: String
    public let unit: String?

    public var effectiveRange: ClosedRange<Double>? { get }  // range, or the auto-ranged min/max
}
```

A scalar value per face or per triangle, set via `CADViewportService.setScalarField(_:forBody:)`.
`.perFace` indexes `values` the same way `PickedFaceInfo.faceIndex` does; `.perTriangle`
indexes directly by triangle, for a value that varies within a face. A `.nan` entry (or a
missing index) leaves that triangle unpainted rather than a wrong color.

```swift
let field = ScalarField(
    domain: .perFace,
    values: perFaceDeviationMM,
    range: -2.0...2.0,
    colorMap: .diverging(center: 0),
    label: "deviation",
    unit: "mm"
)
```

## `ColorMap`

```swift
public enum ColorMap: Sendable, Equatable {
    case viridis, magma, turbo
    case diverging(center: Double)
    case threshold(levels: [Double])
    case custom([(Double, SIMD4<Float>)])

    public func color(for value: Double, in range: ClosedRange<Double>) -> SIMD4<Float>
}
```

- **`.viridis`/`.magma`/`.turbo`** — sequential ramps (dark→light), for an unsigned
  magnitude (curvature, thickness, confidence). Approximate reproductions of the published
  matplotlib/Google colormaps of the same name (anchor-color interpolation for
  viridis/magma; Google's published polynomial fit for turbo) — close enough for review
  purposes, not colorimetrically exact.
- **`.diverging(center:)`** — a two-sided blue→white→red ramp about `center`, scaled by the
  larger of `range`'s distance to `center` on either side. Use for signed deviation:
  material outside the source and material missing from it are different failures, and a
  one-ended ramp hides which is which.
- **`.threshold(levels:)`** — discrete bands: `levels` are the ascending boundaries between
  them (e.g. `[0.5, 1.0]` → 3 bands). Colors cycle through a small built-in
  pass(green)/warn(yellow)/caution(orange)/fail(red)/purple palette, repeating if there are
  more bands than colors.
- **`.custom(stops:)`** — explicit `(value, color)` stops (raw values, not normalized 0–1),
  linearly interpolated between the two bracketing stops; clamped to the nearest stop's
  color outside their span.

`color(for:in:)` is what `setScalarField`/`scalarFieldLegend` call internally — call it
yourself to preview a color map without setting a field.

## `ScalarFieldLegend`

```swift
public struct ScalarFieldLegend: Sendable, Equatable {
    public let label: String
    public let unit: String?
    public let range: ClosedRange<Double>
    public let stops: [LegendStop]  // 9 evenly-spaced (value, color) samples across range
}
```

Everything a UI needs to render a scalar field's legend — a color bar with real tick
labels, not a decorative gradient. Returned by `CADViewportService.scalarFieldLegend`.

```swift
if let legend = viewport.scalarFieldLegend {
    Text("\(legend.label)\(legend.unit.map { " (\($0))" } ?? "")")
    ForEach(legend.stops, id: \.value) { stop in
        // render a swatch for stop.color, labeled stop.value
    }
}
```

## `LegendStop`

```swift
public struct LegendStop: Sendable, Equatable {
    public let value: Double
    public let color: SIMD4<Float>
}
```

One labeled point on a `ScalarFieldLegend`.

## `ComparisonView`

```swift
public struct ComparisonView: Sendable, Equatable {
    public let referenceID: String        // typically the source mesh
    public let candidateID: String        // typically the reconstructed solid
    public let mode: ComparisonMode
}
```

A comparison between two already-loaded entities, set via `CADViewportService.setComparison(_:)`.

## `ComparisonMode`

```swift
public enum ComparisonMode: Sendable, Equatable {
    case overlay(referenceOpacity: Double)
    case deviation
    case sideBySide
    case wipe(axis: Axis, position: Double)
}
```

See the [Comparison](#comparison) section above for what each case does.

## `Axis`

```swift
public enum Axis: Sendable, Equatable, CaseIterable {
    case x, y, z
}
```

Axis a `.wipe` comparison splits along. A local mirror of the same concept elsewhere in the
ecosystem (e.g. `OCCTSwiftAIS.ManipulatorWidget.Axis`), kept separate so this package's
public surface doesn't couple to a widget-specific type for an unrelated concept.

## `FaceBounds`

```swift
public struct FaceBounds: Sendable, Equatable, Codable {
    public let minX, maxX, minY, maxY: Float
    public var width: Float  { maxX - minX }
    public var height: Float { maxY - minY }
}
```

XY bounds of a picked face in world coordinates (millimetres).

```swift
if case .face(let face)? = viewport.selection.first, viewport.selection.count == 1 {
    print(face.bounds.width, face.bounds.height)
}
```

---

## `CADViewportError`

```swift
public enum CADViewportError: Error, LocalizedError {
    case unsupportedFormat(String)  // "Unsupported file format: .<ext>"
    case emptyFile                  // "File contains no geometry"
    case loadFailed(String)         // "Load failed: <msg>"
}
```

Thrown by the import methods. Conforms to `LocalizedError`, so `errorDescription`
yields a user-facing message.

```swift
do {
    try await viewport.loadFile(from: url)
} catch let error as CADViewportError {
    print(error.errorDescription ?? "load failed")
}
```
