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

    /// Currently picked sub-shape (face, edge, or vertex), gated by `selectionModes`.
    /// `nil` if nothing is picked.
    public private(set) var selected: PickedEntity?

    /// Which sub-shape kinds picking resolves. Defaults to `[.face]`, matching this
    /// service's behavior before edge/vertex picking existed — add `.edge`/`.vertex` to
    /// opt in. `.body` has no effect here (there is no whole-body `PickedEntity` case);
    /// it exists on `SelectionMode` for `OCCTSwiftAIS.InteractiveContext.selectionMode`,
    /// a separate, independent selection system this service does not share state with.
    public var selectionModes: Set<SelectionMode> = [.face]

    /// Currently selected face, or `nil` if nothing is picked or the current pick is an
    /// edge or vertex.
    @available(*, deprecated, message: "Use `selected` instead — returns non-nil only for face picks.")
    public var selectedFace: PickedFaceInfo? {
        if case .face(let info)? = selected { return info }
        return nil
    }

    /// Internal rather than private so tests can seed it directly — e.g. a synthetic body
    /// with empty `edgeIndices`/`vertices` to exercise the "not edge/vertex-pickable"
    /// degrade-gracefully path without a real non-pickable file on disk.
    var modelBodies: [_ViewportBody] = []
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

    /// Edge-ordinal → (`Shape`, `GraphUID`?) table per loaded body, keyed by body id.
    private var edgeIdentity: [String: EdgeIdentityTable] = [:]

    /// Vertex-ordinal → (`Shape`, `GraphUID`?) table per loaded body, keyed by body id.
    private var vertexIdentity: [String: VertexIdentityTable] = [:]

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
        let (body, meta, faceTable, edgeTable, vertexTable) = CADFileLoader.shapeToBodyMetadataAndIdentities(
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
        if let edgeTable {
            self.edgeIdentity[id] = edgeTable
        }
        if let vertexTable {
            self.vertexIdentity[id] = vertexTable
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
            self.edgeIdentity = [:]
            self.vertexIdentity = [:]
            return
        }

        var newShapes: [String: OCCTSwift.Shape] = [:]
        var newGraphs: [String: BRepGraph] = [:]
        var newFaceIdentity: [String: FaceIdentityTable] = [:]
        var newEdgeIdentity: [String: EdgeIdentityTable] = [:]
        var newVertexIdentity: [String: VertexIdentityTable] = [:]

        for (index, body) in bodies.enumerated() {
            let shape = shapes[index]
            newShapes[body.id] = shape
            let graph = BRepGraph(shape: shape)
            if let graph {
                newGraphs[body.id] = graph
            }
            newFaceIdentity[body.id] = Self.makeFaceIdentityTable(shape: shape, graph: graph)
            newEdgeIdentity[body.id] = Self.makeEdgeIdentityTable(shape: shape, graph: graph)
            newVertexIdentity[body.id] = Self.makeVertexIdentityTable(shape: shape, graph: graph)
        }

        self.bodyShapes = newShapes
        self.bodyGraphs = newGraphs
        self.faceIdentity = newFaceIdentity
        self.edgeIdentity = newEdgeIdentity
        self.vertexIdentity = newVertexIdentity
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

    /// Mirrors `OCCTSwiftTools.CADFileLoader`'s own (private) `makeEdgeIdentityTable`: map
    /// every `shape.edges()` ordinal (the same `TopTools_IndexedMapOfShape` traversal
    /// `edgeIndices` is built from) to its `Shape` and, when available, `GraphUID`.
    private static func makeEdgeIdentityTable(shape: OCCTSwift.Shape, graph: BRepGraph?) -> EdgeIdentityTable {
        let edgeShapes = shape.edges().compactMap { OCCTSwift.Shape.fromEdge($0) }
        guard let graph else {
            return EdgeIdentityTable(shapes: edgeShapes)
        }
        let uids: [BRepGraph.GraphUID?] = edgeShapes.map { edgeShape in
            guard let node = graph.findNode(for: edgeShape) else { return nil }
            return graph.uid(ofNodeKind: Int(node.kind.rawValue), index: node.index)
        }
        return EdgeIdentityTable(shapes: edgeShapes, uids: uids)
    }

    /// Mirrors `OCCTSwiftTools.CADFileLoader`'s own (private) `makeVertexIdentityTable`: map
    /// every `shape.subShapes(ofType: .vertex)` ordinal (the same `TopTools_IndexedMapOfShape`
    /// traversal `vertexIndices` is built from) to its `Shape` and, when available, `GraphUID`.
    private static func makeVertexIdentityTable(shape: OCCTSwift.Shape, graph: BRepGraph?) -> VertexIdentityTable {
        let vertexShapes = shape.subShapes(ofType: .vertex)
        guard let graph else {
            return VertexIdentityTable(shapes: vertexShapes)
        }
        let uids: [BRepGraph.GraphUID?] = vertexShapes.map { vertexShape in
            guard let node = graph.findNode(for: vertexShape) else { return nil }
            return graph.uid(ofNodeKind: Int(node.kind.rawValue), index: node.index)
        }
        return VertexIdentityTable(shapes: vertexShapes, uids: uids)
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

    // MARK: - Selection

    /// Clear the current selection (and any highlight body).
    public func clearSelection() {
        selected = nil
        selectionBody = nil
        rebuildBodies()
    }

    private func handlePick(_ result: _PickResult?) {
        guard let result, let entity = resolveEntityPick(result) else {
            clearSelection()
            return
        }

        selected = entity
        buildSelectionHighlight(for: entity)
    }

    /// Dispatches a GPU pick to the resolver for its kind, gated by `selectionModes`.
    private func resolveEntityPick(_ result: _PickResult) -> PickedEntity? {
        switch result.kind {
        case .face:
            return resolveFacePick(bodyID: result.bodyID, triangleIndex: result.triangleIndex).map(PickedEntity.face)
        case .edge:
            return resolveEdgePick(bodyID: result.bodyID, segmentIndex: result.triangleIndex).map(PickedEntity.edge)
        case .vertex:
            return resolveVertexPick(bodyID: result.bodyID, pointIndex: result.triangleIndex).map(PickedEntity.vertex)
        }
    }

    /// Resolves a triangle-level GPU pick to durable face identity via the picked body's
    /// `FaceIdentityTable`. `internal` rather than `private` so it can be exercised
    /// directly in tests without round-tripping through the viewport's async pick
    /// callback — `handlePick` is the only production caller.
    func resolveFacePick(bodyID: String, triangleIndex: Int) -> PickedFaceInfo? {
        guard selectionModes.contains(.face) else { return nil }
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

    /// Resolves a line-segment-level GPU pick to durable edge identity via the picked
    /// body's `EdgeIdentityTable`. Reads `edgeIndices` off the `_ViewportBody` itself
    /// (unlike faces, `CADBodyMetadata` carries edge data as per-polyline groups, not a
    /// flat per-segment array) — a body with no `edgeIndices` populated (not edge-pickable,
    /// per `ViewportBody`'s own documentation) degrades to `nil` here rather than
    /// mis-picking. `internal` for the same testability reason as `resolveFacePick`.
    func resolveEdgePick(bodyID: String, segmentIndex: Int) -> PickedEdgeInfo? {
        guard selectionModes.contains(.edge) else { return nil }
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
              segmentIndex >= 0, segmentIndex < body.edgeIndices.count else {
            return nil
        }

        let edgeIndex = Int(body.edgeIndices[segmentIndex])
        guard edgeIndex >= 0 else { return nil }

        let identity = edgeIdentity[bodyID]
        var edgeShape = identity?.shape(forOrdinal: edgeIndex)
        if edgeShape == nil, let edges = bodyShapes[bodyID]?.edges(), edgeIndex < edges.count {
            edgeShape = OCCTSwift.Shape.fromEdge(edges[edgeIndex])
        }
        guard let edgeShape, let edge = Edge(edgeShape) else { return nil }
        let uid = identity?.uid(forOrdinal: edgeIndex)

        let endpoints = edge.endpoints
        let typeStr: String
        switch edge.curveType {
        case .line: typeStr = "Line"
        case .circle: typeStr = "Circle"
        case .ellipse: typeStr = "Ellipse"
        case .hyperbola: typeStr = "Hyperbola"
        case .parabola: typeStr = "Parabola"
        case .bezierCurve: typeStr = "Bezier"
        case .bsplineCurve: typeStr = "B-spline"
        case .offsetCurve: typeStr = "Offset curve"
        case .other: typeStr = "Curve"
        }
        let desc = "\(typeStr) edge, \(String(format: "%.1f", edge.length))mm"

        return PickedEdgeInfo(
            shape: edgeShape,
            uid: uid,
            edgeIndex: edgeIndex,
            bodyID: bodyID,
            curveType: edge.curveType,
            length: edge.length,
            startPoint: endpoints.start,
            endPoint: endpoints.end,
            description: desc
        )
    }

    /// Resolves a point-sprite-level GPU pick to durable vertex identity via the picked
    /// body's `VertexIdentityTable`. A body with no `vertices` populated (not
    /// vertex-pickable) degrades to `nil` here rather than mis-picking. `internal` for the
    /// same testability reason as `resolveFacePick`.
    func resolveVertexPick(bodyID: String, pointIndex: Int) -> PickedVertexInfo? {
        guard selectionModes.contains(.vertex) else { return nil }
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
              pointIndex >= 0, pointIndex < body.vertices.count else {
            return nil
        }

        // `vertexIndices` empty means identity mapping (pointIndex is the ordinal itself),
        // per ViewportBody's own documentation. Deliberately more complete here than
        // OCCTSwiftAIS's own resolveVertexSubShape, which bounds-checks against
        // `vertexIndices.count` directly and so never resolves a pick when it's empty —
        // unreached in practice since CADFileLoader always populates both arrays in
        // lockstep for a real body, but this implements the documented fallback in full.
        let vertexIndex = pointIndex < body.vertexIndices.count ? Int(body.vertexIndices[pointIndex]) : pointIndex
        guard vertexIndex >= 0 else { return nil }

        let identity = vertexIdentity[bodyID]
        var vertexShape = identity?.shape(forOrdinal: vertexIndex)
        if vertexShape == nil, let vertices = bodyShapes[bodyID]?.subShapes(ofType: .vertex),
           vertexIndex < vertices.count {
            vertexShape = vertices[vertexIndex]
        }
        guard let vertexShape else { return nil }
        let uid = identity?.uid(forOrdinal: vertexIndex)

        let renderPosition = body.vertices[pointIndex]
        let position = vertexShape.vertices().first ?? SIMD3<Double>(
            Double(renderPosition.x), Double(renderPosition.y), Double(renderPosition.z)
        )
        let desc = String(format: "Vertex at (%.1f, %.1f, %.1f)mm", position.x, position.y, position.z)

        return PickedVertexInfo(
            shape: vertexShape,
            uid: uid,
            vertexIndex: vertexIndex,
            bodyID: bodyID,
            position: position,
            description: desc
        )
    }

    private func buildSelectionHighlight(for entity: PickedEntity) {
        switch entity {
        case .face(let info):
            buildFaceHighlight(bodyID: info.bodyID, faceIndex: Int32(info.faceIndex))
        case .edge(let info):
            buildEdgeHighlight(bodyID: info.bodyID, edgeIndex: Int32(info.edgeIndex))
        case .vertex(let info):
            buildVertexHighlight(position: info.position)
        }
    }

    private func buildFaceHighlight(bodyID: String, faceIndex: Int32) {
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

    /// Distinguishable from the face highlight: a bright cyan polyline built from just the
    /// picked edge's own segments (gathered from `body.edges` via `edgeIndices`), rather
    /// than a translucent triangle patch.
    private func buildEdgeHighlight(bodyID: String, edgeIndex: Int32) {
        guard let body = modelBodies.first(where: { $0.id == bodyID }) else {
            selectionBody = nil
            rebuildBodies()
            return
        }

        var segments: [[SIMD3<Float>]] = []
        var segmentCursor = 0
        for polyline in body.edges {
            let segmentCount = max(polyline.count - 1, 0)
            guard segmentCount > 0 else { continue }
            for s in 0..<segmentCount {
                defer { segmentCursor += 1 }
                guard segmentCursor < body.edgeIndices.count,
                      body.edgeIndices[segmentCursor] == edgeIndex else { continue }
                segments.append([polyline[s], polyline[s + 1]])
            }
        }

        guard !segments.isEmpty else {
            selectionBody = nil
            rebuildBodies()
            return
        }

        selectionBody = _ViewportBody(
            id: "selection_highlight",
            vertexData: [],
            indices: [],
            edges: segments,
            color: SIMD4<Float>(0.1, 0.9, 1.0, 1.0)
        )
        rebuildBodies()
    }

    /// Distinguishable from face/edge highlights: a bright magenta point sprite at the
    /// picked vertex's own durable position.
    private func buildVertexHighlight(position: SIMD3<Double>) {
        selectionBody = _ViewportBody(
            id: "selection_highlight",
            vertexData: [],
            indices: [],
            edges: [],
            vertices: [SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))],
            vertexIndices: [0],
            color: SIMD4<Float>(1.0, 0.15, 0.9, 1.0),
            pointRadius: 6,
            primitiveKind: .point
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
