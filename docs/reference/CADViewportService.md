# CADViewportService — API reference

`OCCTSwiftCADKit` provides a shared SwiftUI Metal CAD viewport: import STEP/STL/BREP
geometry, render it, and route face-picking results back to your app. The public
surface is `CADViewportService` (the controller/state owner), `CADViewportView` (the
SwiftUI view), the `PickedFaceInfo`/`FaceBounds` result types, and `CADViewportError`.

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
viewport, and routes face-picking results back to the caller via `selectedFace`.
Caller-supplied geometry (stock boxes, toolpaths, flat-pattern outlines, annotations)
is staged through the overlay API and composited with the model bodies and any
selection highlight on every viewport rebuild.

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
| `loadedShape` | `OCCTSwift.Shape?` | The loaded shape, or `nil` until something is loaded. Read-only. |
| `selectedFace` | `PickedFaceInfo?` | Currently picked face, or `nil`. Read-only; updated internally on pick. |
| `shapeBounds` | `ShapeBounds?` | Axis-aligned bounds of `loadedShape`, or `nil`. |
| `overlayIDs` | `[String]` | Sorted ids of overlay layers currently staged. |

### File import

```swift
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

### Face selection

```swift
public func clearSelection()
```

Clears the current face selection and removes the highlight body. Selection is
otherwise set internally when the user picks a face in the viewport — observe the
`selectedFace` property to react.

```swift
// React to picks (e.g. inside a SwiftUI view observing the @Observable service):
if let face = viewport.selectedFace {
    print(face.description)            // e.g. "Horizontal face at Z=20.0, 50.0x30.0mm"
    print("face index:", face.faceIndex)
}

// Programmatically clear:
viewport.clearSelection()
```

<!-- 3D render TODO: viewport with a picked face highlighted in yellow -->

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
    selectedFace: PickedFaceInfo? = nil,
    onClearSelection: (() -> Void)? = nil
)
```

- **`bodies`** — the bodies to render; pass `service.bodies`.
- **`controller`** — the viewport controller; pass `service.controller`.
- **`selectedFace`** — the picked face to show in the banner; pass `service.selectedFace`.
- **`onClearSelection`** — invoked by the banner's close button; wire to `service.clearSelection()`.

The built-in controls set `controller.displayMode` (`.shaded`, `.shadedWithEdges`,
`.wireframe`) and call `controller.goToStandardView(.isometricFrontRight)`.

```swift
CADViewportView(
    bodies: viewport.bodies,
    controller: viewport.controller,
    selectedFace: viewport.selectedFace,
    onClearSelection: { viewport.clearSelection() }
)
```

<!-- 3D render TODO: CADViewportView with selection banner and display-mode controls -->

---

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
}
```

Metadata about a face picked in the viewport. `shape` and `uid` are the durable identity
of the pick, captured once at pick time from the picked body's `FaceIdentityTable`.
`faceIndex` is the ephemeral render-path ordinal the pick came from — valid only against
that body's own tessellation. Don't subscript `loadedShape.faces()[faceIndex]` to
re-derive the face: once a face is shared between two shells, that non-deduplicating
traversal counts the shared face once per shell, so the same ordinal can silently name a
different face than the one actually picked. Construct a `Face` from `shape` instead. No
CAM- or unfold-specific dependencies.

```swift
if let face = viewport.selectedFace, let occtFace = Face(face.shape) {
    print("area:", face.area, "horizontal:", face.isHorizontal)
    print("durable handle available:", face.uid != nil)
}
```

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
let b = viewport.selectedFace?.bounds
print(b?.width ?? 0, b?.height ?? 0)
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
