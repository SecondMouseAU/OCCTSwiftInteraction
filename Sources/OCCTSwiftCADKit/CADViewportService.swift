import Foundation
import SwiftUI
import Combine
import simd
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools
import OCCTSwiftAIS

/// Manages a loaded B-Rep `Shape`, drives the Metal viewport, and routes
/// face-picking results back to the caller.
///
/// Use `loadFile(from:)`/`loadShape(_:id:)`/`loadFromData(_:filename:)` to
/// import geometry. Caller-supplied geometry like stock boxes, toolpaths, or
/// flat-pattern outlines is staged via the `setOverlay(id:bodies:)` API; the
/// service composites them with the model bodies and any selection highlight
/// every time it rebuilds the viewport's body list.
///
/// AIS widgets (manipulator, dimensions, sub-shape selection) install against
/// `interactiveContext`; the bodies they append are composited with the
/// CADKit-owned bodies into a single rendered array.
@MainActor
@Observable
public final class CADViewportService {
    /// Viewport controller — exposes camera, display mode, picking config,
    /// etc. Construct with custom configuration via `init(configuration:)`.
    public let controller: _ViewportController

    /// AIS interactive context backed by this service's viewport. Use to
    /// install `ManipulatorWidget`, add dimensions, or display extra
    /// `InteractiveObject`s. Bodies appended via `display(_:)` /
    /// `appendInternalBody(_:)` are composited with the CADKit-owned bodies
    /// (model + overlays + selection highlight) and rendered through the
    /// same array that `CADViewportView` binds to.
    public let interactiveContext: InteractiveContext

    /// All bodies currently displayed in the viewport. Composed of: model
    /// bodies (from imported file) + overlay layers (caller-managed) +
    /// selection highlight (managed internally on pick) + AIS-owned bodies
    /// (manipulator handles, displayed shapes, dimensions). Mirrors
    /// `interactiveContext.bodies`.
    public private(set) var bodies: [_ViewportBody] = []

    /// The loaded OCCTSwift shape. `nil` until something is loaded.
    public private(set) var loadedShape: OCCTSwift.Shape?

    /// Currently selected face. `nil` if nothing is picked.
    public private(set) var selectedFace: PickedFaceInfo?

    private var modelBodies: [_ViewportBody] = []
    /// Internal rather than private so tests can seed it directly when exercising
    /// `rebuildIdentity`/`resolveFacePick` against a synthetic multi-body scenario without
    /// a real multi-body file on disk.
    var metadata: [String: CADBodyMetadata] = [:]
    private var overlays: [String: [_ViewportBody]] = [:]
    private var selectionBody: _ViewportBody?
    private var ownedBodyIDs: Set<String> = []
    private var bodiesSubscription: AnyCancellable?

    // MARK: - Durable identity (per loaded body)

    /// The raw shape each model body was tessellated from, keyed by body id.
    private var bodyShapes: [String: OCCTSwift.Shape] = [:]

    /// One `BRepGraph` per loaded body, retained for its shape's lifetime — this is what
    /// makes `PickedFaceInfo.uid` populatable, and what a later absorb-history mechanic
    /// (mirroring `InteractiveContext.update(_:to:absorbing:operationName:)`) would need.
    /// Absent for a body whose graph failed to construct (a pathological shape); such a
    /// body's picks mint `uid == nil`.
    private var bodyGraphs: [String: BRepGraph] = [:]

    /// Face-ordinal → (`Shape`, `GraphUID`?) table per loaded body, keyed by body id.
    private var faceIdentity: [String: FaceIdentityTable] = [:]

    public init(configuration: _ViewportConfiguration = .init(
        rotationStyle: .turntable,
        displayMode: .shadedWithEdges,
        lightingConfiguration: .threePoint,
        showViewCube: true,
        showAxes: true,
        showGrid: true,
        pickingConfiguration: _PickingConfiguration(isEnabled: true)
    )) {
        let controller = _ViewportController(configuration: configuration)
        self.controller = controller
        self.interactiveContext = InteractiveContext(viewport: controller)
        controller.onPick = { [weak self] result in
            Task { @MainActor in
                self?.handlePick(result)
            }
        }
        self.bodiesSubscription = interactiveContext.$bodies
            .receive(on: RunLoop.main)
            .sink { [weak self] new in
                self?.bodies = new
            }
    }

    // MARK: - File Import

    /// Load a CAD file (STEP/.stp, STL, BREP) from disk into the viewport.
    /// Returns the loaded `Shape`. Camera is automatically focused on the
    /// shape's bounding box.
    ///
    /// Pass an `ImportProgress` (e.g. `ImportProgressClosure`) to observe
    /// STEP/IGES import progress and/or request cooperative cancellation;
    /// cancellation surfaces as `ImportError.cancelled`.
    @discardableResult
    public func loadFile(
        from url: URL,
        progress: ImportProgress? = nil
    ) async throws -> OCCTSwift.Shape {
        let ext = url.pathExtension.lowercased()
        let format: CADFileFormat
        switch ext {
        case "step", "stp": format = .step
        case "stl": format = .stl
        case "brep": format = .brep
        default: throw CADViewportError.unsupportedFormat(ext)
        }

        let result = try await CADFileLoader.load(from: url, format: format, progress: progress)
        guard let firstShape = result.shapes.first else {
            throw CADViewportError.emptyFile
        }

        self.loadedShape = firstShape
        self.modelBodies = result.bodies
        self.metadata = result.metadata
        rebuildIdentity(bodies: result.bodies, shapes: result.shapes)
        clearSelection()
        rebuildBodies()
        focusOnLoadedShape()
        return firstShape
    }

    /// Display an in-memory shape (e.g. one constructed programmatically via
    /// OCCTSwift) without going through the file loader.
    public func loadShape(_ shape: OCCTSwift.Shape, id: String = "model") {
        self.loadedShape = shape
        let graph = BRepGraph(shape: shape)
        let (body, meta, faceTable) = CADFileLoader.shapeToBodyMetadataAndIdentity(
            shape,
            id: id,
            color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0),
            graph: graph
        )
        if let body {
            self.modelBodies = [body]
        }
        if let meta {
            self.metadata[id] = meta
        }
        self.bodyShapes[id] = shape
        if let graph {
            self.bodyGraphs[id] = graph
        }
        if let faceTable {
            self.faceIdentity[id] = faceTable
        }
        clearSelection()
        rebuildBodies()
        focusOnLoadedShape()
    }

    /// Builds a `BRepGraph` and `FaceIdentityTable` per body from a multi-body file load's
    /// raw shapes, keyed by body id. `CADFileLoader.load(from:format:)` has no
    /// identity-table overload — it owns the STL/IGES robust-reload fallback, which this
    /// package shouldn't reimplement just to get identity — so the table is built directly
    /// from `shape.faces()` instead of re-tessellating each body through
    /// `shapeToBodyMetadataAndIdentity`. `shape.faces()` is the same non-deduplicating
    /// traversal the mesher used to assign `CADBodyMetadata.faceIndices` in the first place
    /// (see `FaceIdentityTable`'s own documentation), so ordinals line up without a second
    /// tessellation pass.
    ///
    /// Requires `bodies` and `shapes` to correspond positionally (`shapes[i]` is the shape
    /// `bodies[i]` was tessellated from) — true for `CADFileLoader.load(from:format:)`'s
    /// primary bridge, where both arrays are appended together only on tessellation success.
    /// Its STL/IGES robust-reload fallback (`reloadRobustAndBridge`) can violate this: it
    /// appends to `shapes` on every input even when that input's body tessellation fails, so
    /// a body-tessellation failure part-way through a multibody robust reload shifts `shapes`
    /// out of alignment with `bodies` for every subsequent entry. Detectable from the outside
    /// only via the count mismatch it produces (`shapes.count > bodies.count`) — when that
    /// happens, this method skips building identity entirely rather than risk pairing a body
    /// with the wrong shape, matching this pack's own rule that `uid`/`shape` should be
    /// absent rather than wrong.
    func rebuildIdentity(bodies: [_ViewportBody], shapes: [OCCTSwift.Shape]) {
        guard bodies.count == shapes.count else {
            self.bodyShapes = [:]
            self.bodyGraphs = [:]
            self.faceIdentity = [:]
            return
        }

        var newShapes: [String: OCCTSwift.Shape] = [:]
        var newGraphs: [String: BRepGraph] = [:]
        var newIdentity: [String: FaceIdentityTable] = [:]

        for (index, body) in bodies.enumerated() {
            let shape = shapes[index]
            newShapes[body.id] = shape
            let graph = BRepGraph(shape: shape)
            if let graph {
                newGraphs[body.id] = graph
            }
            newIdentity[body.id] = Self.makeFaceIdentityTable(shape: shape, graph: graph)
        }

        self.bodyShapes = newShapes
        self.bodyGraphs = newGraphs
        self.faceIdentity = newIdentity
    }

    /// Mirrors `OCCTSwiftTools.CADFileLoader`'s own (private) `makeFaceIdentityTable`: map
    /// every `shape.faces()` ordinal to its `Shape`, and, when a graph is available, to the
    /// `GraphUID` minted via `graph.findNode(for:)` on that same face `Shape` so `IsSame`
    /// semantics hold.
    private static func makeFaceIdentityTable(shape: OCCTSwift.Shape, graph: BRepGraph?) -> FaceIdentityTable {
        let faceShapes = shape.faces().compactMap { OCCTSwift.Shape.fromFace($0) }
        guard let graph else {
            return FaceIdentityTable(shapes: faceShapes)
        }
        let uids: [BRepGraph.GraphUID?] = faceShapes.map { faceShape in
            guard let node = graph.findNode(for: faceShape) else { return nil }
            return graph.uid(ofNodeKind: Int(node.kind.rawValue), index: node.index)
        }
        return FaceIdentityTable(shapes: faceShapes, uids: uids)
    }

    /// Convenience for callers that have file `Data` rather than a URL
    /// (e.g. `.fileImporter` results, drag-and-drop on iOS).
    @discardableResult
    public func loadFromData(
        _ data: Data,
        filename: String,
        progress: ImportProgress? = nil
    ) async throws -> OCCTSwift.Shape {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(filename)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await loadFile(from: tempURL, progress: progress)
    }

    private func focusOnLoadedShape() {
        guard let shape = loadedShape else { return }
        let b = shape.bounds
        let center = SIMD3<Float>(
            Float((b.min.x + b.max.x) / 2),
            Float((b.min.y + b.max.y) / 2),
            Float((b.min.z + b.max.z) / 2)
        )
        let maxDim = Float(max(b.max.x - b.min.x, max(b.max.y - b.min.y, b.max.z - b.min.z)))
        controller.focusOn(point: center, distance: maxDim * 2.5)
    }

    // MARK: - Shape Info

    public struct ShapeBounds: Sendable, Equatable {
        public let minX: Double, minY: Double, minZ: Double
        public let maxX: Double, maxY: Double, maxZ: Double
        public var sizeX: Double { maxX - minX }
        public var sizeY: Double { maxY - minY }
        public var sizeZ: Double { maxZ - minZ }
    }

    public var shapeBounds: ShapeBounds? {
        guard let shape = loadedShape else { return nil }
        let b = shape.bounds
        return ShapeBounds(
            minX: b.min.x, minY: b.min.y, minZ: b.min.z,
            maxX: b.max.x, maxY: b.max.y, maxZ: b.max.z
        )
    }

    // MARK: - Overlay Layers

    /// Add or replace a named overlay layer. The bodies are composited with
    /// the model + selection highlight on every viewport rebuild. Use this
    /// for stock boxes, toolpath polylines, flat-pattern outlines, bend
    /// strips, custom annotations — anything that isn't part of the imported
    /// model.
    public func setOverlay(id: String, bodies: [_ViewportBody]) {
        overlays[id] = bodies
        rebuildBodies()
    }

    /// Remove a named overlay layer.
    public func clearOverlay(id: String) {
        overlays.removeValue(forKey: id)
        rebuildBodies()
    }

    /// Remove every overlay layer. Model bodies and selection are unaffected.
    public func clearAllOverlays() {
        overlays.removeAll()
        rebuildBodies()
    }

    /// Sorted list of overlay layer ids currently in the viewport.
    public var overlayIDs: [String] { overlays.keys.sorted() }

    // MARK: - Face Selection

    /// Clear the current face selection (and any highlight body).
    public func clearSelection() {
        selectedFace = nil
        selectionBody = nil
        rebuildBodies()
    }

    private func handlePick(_ result: _PickResult?) {
        guard let result,
              let info = resolveFacePick(bodyID: result.bodyID, triangleIndex: result.triangleIndex) else {
            clearSelection()
            return
        }

        selectedFace = info
        buildSelectionHighlight(bodyID: result.bodyID, faceIndex: Int32(info.faceIndex))
    }

    /// Resolves a triangle-level GPU pick to durable face identity via the picked body's
    /// `FaceIdentityTable`. `internal` rather than `private` so it can be exercised
    /// directly in tests without round-tripping through the viewport's async pick
    /// callback — `handlePick` is the only production caller.
    func resolveFacePick(bodyID: String, triangleIndex: Int) -> PickedFaceInfo? {
        guard let meta = metadata[bodyID],
              triangleIndex >= 0, triangleIndex < meta.faceIndices.count else {
            return nil
        }

        let faceIndex = Int(meta.faceIndices[triangleIndex])
        guard faceIndex >= 0 else { return nil }

        let identity = faceIdentity[bodyID]
        var faceShape = identity?.shape(forOrdinal: faceIndex)
        if faceShape == nil, let faces = bodyShapes[bodyID]?.faces(), faceIndex < faces.count {
            faceShape = OCCTSwift.Shape.fromFace(faces[faceIndex])
        }
        guard let faceShape, let face = Face(faceShape) else { return nil }
        let uid = identity?.uid(forOrdinal: faceIndex)

        let isHoriz = face.isHorizontal()
        let isVert = face.isVertical()
        let faceBounds = face.bounds
        let faceArea = face.area()
        let zLevel = face.zLevel.map { Float($0) }

        let bounds = FaceBounds(
            minX: Float(faceBounds.min.x),
            maxX: Float(faceBounds.max.x),
            minY: Float(faceBounds.min.y),
            maxY: Float(faceBounds.max.y)
        )

        let typeStr = isHoriz ? "Horizontal" : (isVert ? "Vertical" : "Angled")
        let sizeStr = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let zStr = zLevel.map { String(format: " at Z=%.1f", $0) } ?? ""
        let desc = "\(typeStr) face\(zStr), \(sizeStr)mm"

        return PickedFaceInfo(
            shape: faceShape,
            uid: uid,
            faceIndex: faceIndex,
            bodyID: bodyID,
            isHorizontal: isHoriz,
            isVertical: isVert,
            bounds: bounds,
            zLevel: zLevel,
            area: faceArea,
            description: desc
        )
    }

    private func buildSelectionHighlight(bodyID: String, faceIndex: Int32) {
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
              let meta = metadata[bodyID] else {
            selectionBody = nil
            rebuildBodies()
            return
        }

        let stride = 6 // interleaved [px,py,pz,nx,ny,nz]
        var highlightVerts: [Float] = []
        var highlightIndices: [UInt32] = []
        var vertCount: UInt32 = 0

        let triCount = body.indices.count / 3
        for tri in 0..<triCount {
            guard tri < meta.faceIndices.count && meta.faceIndices[tri] == faceIndex else { continue }

            let i0 = Int(body.indices[tri * 3])
            let i1 = Int(body.indices[tri * 3 + 1])
            let i2 = Int(body.indices[tri * 3 + 2])

            for idx in [i0, i1, i2] {
                let base = idx * stride
                guard base + stride <= body.vertexData.count else { continue }
                highlightVerts.append(contentsOf: body.vertexData[base..<(base + stride)])
                highlightIndices.append(vertCount)
                vertCount += 1
            }
        }

        guard !highlightIndices.isEmpty else {
            selectionBody = nil
            rebuildBodies()
            return
        }

        selectionBody = _ViewportBody(
            id: "selection_highlight",
            vertexData: highlightVerts,
            indices: highlightIndices,
            edges: [],
            color: SIMD4<Float>(1.0, 0.9, 0.0, 0.5)
        )
        rebuildBodies()
    }

    // MARK: - Private

    private func rebuildBodies() {
        var fresh: [_ViewportBody] = []
        fresh.append(contentsOf: modelBodies)
        for key in overlays.keys.sorted() {
            fresh.append(contentsOf: overlays[key] ?? [])
        }
        if let sel = selectionBody { fresh.append(sel) }

        let newIDs = Set(fresh.map { $0.id })
        let toRemove = ownedBodyIDs.union(newIDs)

        var combined = interactiveContext.bodies
        combined.removeAll { toRemove.contains($0.id) }
        combined.append(contentsOf: fresh)

        interactiveContext.bodies = combined
        ownedBodyIDs = newIDs
    }
}
