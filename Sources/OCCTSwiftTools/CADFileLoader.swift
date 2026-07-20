// CADFileLoader.swift
// OCCTSwiftTools
//
// Bridge layer: wraps OCCTSwiftIO's headless `ShapeLoader` to produce
// `ViewportBody` + `CADBodyMetadata` from CAD files. The file-format,
// progress, exporter, and manifest types live in `OCCTSwiftIO`; this file
// owns only the Shape → Body bridge logic.

import Foundation
import simd
import OCCTSwift
import OCCTSwiftViewport
@_exported import OCCTSwiftIO

/// Result of loading a CAD file with renderable bodies attached.
///
/// For headless / shape-only loads (no Viewport dep), use
/// `OCCTSwiftIO.ShapeLoader.load` and `ShapeLoadResult` directly.
public struct CADLoadResult: @unchecked Sendable {
    public var bodies: [ViewportBody]
    public var metadata: [String: CADBodyMetadata]
    public var shapes: [Shape]
    public var dimensions: [DimensionInfo]
    public var geomTolerances: [GeomToleranceInfo]
    public var datums: [DatumInfo]

    public init(bodies: [ViewportBody] = [], metadata: [String: CADBodyMetadata] = [:],
                shapes: [Shape] = [], dimensions: [DimensionInfo] = [],
                geomTolerances: [GeomToleranceInfo] = [], datums: [DatumInfo] = []) {
        self.bodies = bodies
        self.metadata = metadata
        self.shapes = shapes
        self.dimensions = dimensions
        self.geomTolerances = geomTolerances
        self.datums = datums
    }
}

/// Loads CAD files via OCCTSwiftIO and bridges the resulting shapes to
/// `ViewportBody` + `CADBodyMetadata` for renderable + pickable consumers.
public enum CADFileLoader {

    /// Loads a CAD file and returns viewport bodies with selection metadata.
    /// - Parameter progress: optional progress + cancellation observer. Honored
    ///   by `.step` and `.iges` formats only — STL/OBJ/BREP loaders are
    ///   single-call upstream and don't surface progress. If `progress.shouldCancel()`
    ///   returns `true`, the import throws `OCCTSwift.ImportError.cancelled`.
    public static func load(
        from url: URL,
        format: CADFileFormat,
        progress: ImportProgress? = nil
    ) async throws -> CADLoadResult {
        let ioResult = try await ShapeLoader.load(from: url, format: format, progress: progress)
        return bridgeWithFallback(
            ioResult: ioResult, idPrefix: format.rawValue,
            url: url, format: format, progress: progress
        )
    }

    /// Loads bodies from a script manifest (manifest.json + BREP files).
    public static func loadFromManifest(at url: URL) throws -> CADLoadResult {
        let ioResult = try ShapeLoader.loadFromManifest(at: url)

        var bodies: [ViewportBody] = []
        var metadata: [String: CADBodyMetadata] = [:]
        var shapes: [Shape] = []

        for (index, pair) in ioResult.shapesWithColors.enumerated() {
            let descriptor = ioResult.manifest?.bodies[index]
            let bodyID = "script-\(descriptor?.id ?? "\(index)")"
            let rgba = pair.color ?? SIMD4<Float>(0.7, 0.7, 0.7, 1.0)

            let (body, meta) = shapeToBodyAndMetadata(pair.shape, id: bodyID, color: rgba)
            if let body {
                bodies.append(body)
                shapes.append(pair.shape)
                if let meta { metadata[bodyID] = meta }
            }
        }

        return CADLoadResult(bodies: bodies, metadata: metadata, shapes: shapes)
    }

    // MARK: - Bridge with STL/IGES robust fallback

    /// STL and IGES files commonly fail the primary loader → bridge path
    /// (mesh generation returns nil because the input has gaps OCCT's basic
    /// importer can't close). Fall back to the sewing/healing variant on
    /// per-shape bridge failure. STEP / OBJ / BREP have no such fallback —
    /// the primary loader is the only one.
    private static func bridgeWithFallback(
        ioResult: ShapeLoadResult,
        idPrefix: String,
        url: URL,
        format: CADFileFormat,
        progress: ImportProgress?
    ) -> CADLoadResult {
        var bodies: [ViewportBody] = []
        var metadata: [String: CADBodyMetadata] = [:]
        var shapes: [Shape] = []
        var needsRobustReload = false

        for (index, pair) in ioResult.shapesWithColors.enumerated() {
            let bodyID = "\(idPrefix)-\(index)"
            let rgba = pair.color ?? SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
            let stl = (format == .stl)

            let (body, meta) = shapeToBodyAndMetadata(pair.shape, id: bodyID, color: rgba, stl: stl)
            if let body {
                bodies.append(body)
                shapes.append(pair.shape)
                if let meta { metadata[bodyID] = meta }
            } else if format == .stl || format == .iges {
                needsRobustReload = true
                break
            }
        }

        // STL/IGES fallback path: re-load via the robust loader and bridge again.
        // Since OCCTSwift v1.11.3 a multibody STL comes back as a compound of
        // solids (OCCTSwift#302), so this is no longer single-shape — the reload
        // splits it into one ViewportBody per body.
        if needsRobustReload {
            return reloadRobustAndBridge(idPrefix: idPrefix, url: url, format: format, progress: progress)
        }

        return CADLoadResult(
            bodies: bodies, metadata: metadata, shapes: shapes,
            dimensions: ioResult.dimensions,
            geomTolerances: ioResult.geomTolerances,
            datums: ioResult.datums
        )
    }

    private static func reloadRobustAndBridge(
        idPrefix: String, url: URL, format: CADFileFormat, progress: ImportProgress?
    ) -> CADLoadResult {
        // The robust reload mirrors the primary load's blocking call — we're
        // already on a detached task at this point (outer load() is async),
        // so a sync call is fine.
        do {
            let ioRobust: ShapeLoadResult
            switch format {
            case .stl:
                let robust = try Shape.loadSTLRobust(from: url)
                ioRobust = ShapeLoadResult(shapesWithColors: bodyEntries(from: robust))
            case .iges:
                let robust = try Shape.loadIGESRobust(from: url, progress: progress)
                ioRobust = ShapeLoadResult(shapesWithColors: bodyEntries(from: robust))
            default:
                return CADLoadResult()
            }

            var bodies: [ViewportBody] = []
            var metadata: [String: CADBodyMetadata] = [:]
            var shapes: [Shape] = []
            for (index, pair) in ioRobust.shapesWithColors.enumerated() {
                let bodyID = "\(idPrefix)-\(index)"
                let rgba = pair.color ?? SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
                let (body, meta) = shapeToBodyAndMetadata(pair.shape, id: bodyID, color: rgba)
                if let body {
                    bodies.append(body)
                    shapes.append(pair.shape)
                    if let meta { metadata[bodyID] = meta }
                } else {
                    shapes.append(pair.shape)
                }
            }
            return CADLoadResult(bodies: bodies, metadata: metadata, shapes: shapes)
        } catch {
            return CADLoadResult()
        }
    }

    /// One `shapesWithColors` entry per body, so a multibody robust reload becomes
    /// one `ViewportBody` per body rather than a single lumped one.
    ///
    /// Mirrors `OCCTSwiftIO.ShapeLoader`'s own split — this path calls
    /// `Shape.loadSTLRobust` directly (it is sync, `ShapeLoader.loadRobust` is
    /// async), so it needs the same handling rather than inheriting it. A `.solid`
    /// stays one entry; a compound splits into its solids; a result with no solids
    /// stays the whole shape. Robust reloads carry no colour.
    ///
    /// Internal rather than private so it can be unit-tested directly: the
    /// robust-reload path that uses it only fires when the primary mesh bridge
    /// fails, which is not deterministically reproducible in a test.
    static func bodyEntries(from shape: Shape) -> [(shape: Shape, color: SIMD4<Float>?)] {
        let bodies = shape.shapeType == .solid ? [shape] : shape.subShapes(ofType: .solid)
        return (bodies.isEmpty ? [shape] : bodies).map { (shape: $0, color: nil) }
    }

    // MARK: - Mesh parameter presets

    /// High-quality mesh parameters for smooth curved surface rendering (no GPU tessellation).
    public static let highQualityMeshParams: MeshParameters = {
        var p = MeshParameters.default
        p.deflection = 0.03          // 3× finer than default 0.1
        p.angle = 0.2                // ~11° (vs default 0.5 rad ≈ 29°)
        p.angleInterior = 0.2        // Match interior B-spline quality
        p.controlSurfaceDeflection = true
        p.inParallel = true
        return p
    }()

    /// Moderate mesh parameters for GPU tessellation (PN triangles).
    /// Balanced: enough triangles for good normals, large enough for visible PN displacement.
    public static let tessellationMeshParams: MeshParameters = {
        var p = MeshParameters.default
        p.deflection = 0.1           // OCCT default — moderate triangle density
        p.angle = 0.35               // ~20° — good normal quality for PN patches
        p.controlSurfaceDeflection = true
        p.inParallel = true
        return p
    }()

    // MARK: - Shape → Body bridge

    /// Converts an OCCTSwift Shape to a ViewportBody and optional metadata.
    /// - Parameter stl: If true, uses coarser deflection suitable for pre-tessellated STL data
    /// - Parameter deflection: Custom linear deflection override. Lower = smoother (default 0.1, STL uses 1.0).
    /// - Parameter gpuTessellation: If true, uses coarser CPU mesh (GPU PN triangles will refine).
    /// - Parameter edgeDeflection: Linear deflection for the **wireframe edge polylines**
    ///   (independent of the triangle `deflection`). Lower = denser/smoother edges.
    ///   Defaults to `defaultEdgeDeflection` (0.005). Coarsen this for geometry whose
    ///   edges follow long fine curves — e.g. helical threads, where the default
    ///   produces an illegibly dense, slow-to-render wireframe (issue #24).
    /// - Parameter maxPointsPerEdge: Hard cap on points per edge polyline.
    ///   Defaults to `defaultMaxPointsPerEdge` (1000). A lower cap bounds the line
    ///   count for pathologically long edges regardless of `edgeDeflection`.
    /// - Parameter includeMeasurements: If true, populates `metadata.measurements`
    ///   with per-face areas and per-edge lengths (via `Shape.measure`). Off by
    ///   default — face-area iteration is O(faces) and not free for large assemblies.
    /// - Parameter directMesh: If true, hand OCCT's de-interleaved triangulation
    ///   (`mesh.vertexData` / `mesh.normalData`) straight to the renderer via
    ///   `ViewportBody.directMesh(...)`, skipping the per-vertex interleave loop, the
    ///   `NormalSmoothing` pass, and the extra resident CPU copy. A load-time / memory
    ///   win for large or many-body scenes; the rendered result is the same (OCCT's
    ///   per-vertex normals from a fine B-Rep mesh are already analytic-quality — see
    ///   OCCTSwiftViewport v1.1.22 / #81, where skipping NormalSmoothing is the intended
    ///   behaviour). **Caveat:** a direct body carries the mesh vertices (for bbox / fit /
    ///   CPU raycast) but not the B-Rep corner vertex-pick data or per-segment edge-pick
    ///   indices, so face display, face GPU-pick, CPU raycast and edge *display* work, but
    ///   B-Rep vertex-picking and edge-index picking on the body itself do not. The
    ///   returned `metadata` still carries the full pick vertices / face indices, so an app
    ///   can drive those itself. Off by default (source/behaviour-compatible).
    public static func shapeToBodyAndMetadata(
        _ shape: Shape,
        id bodyID: String,
        color rgba: SIMD4<Float>,
        stl: Bool = false,
        deflection customDeflection: Double? = nil,
        gpuTessellation: Bool = false,
        edgeDeflection: Double = defaultEdgeDeflection,
        maxPointsPerEdge: Int = defaultMaxPointsPerEdge,
        includeMeasurements: Bool = false,
        directMesh useDirectMesh: Bool = false
    ) -> (ViewportBody?, CADBodyMetadata?) {
        let (body, meta, _, _, _) = bridgeShapeToBody(
            shape, id: bodyID, color: rgba, stl: stl, deflection: customDeflection,
            gpuTessellation: gpuTessellation, edgeDeflection: edgeDeflection,
            maxPointsPerEdge: maxPointsPerEdge, includeMeasurements: includeMeasurements,
            directMesh: useDirectMesh, graph: nil
        )
        return (body, meta)
    }

    /// Overload of `shapeToBodyAndMetadata` that also emits a `FaceIdentityTable` mapping every
    /// ordinal in the returned metadata's `faceIndices` back to the `Shape` it was tessellated
    /// from — and, when `graph` is supplied, to the durable `GraphUID` minted from that graph.
    /// See issue #42 and `FaceIdentityTable`'s documentation for why this exists: a face ordinal
    /// resolved via `shape.subShapes(ofType: .face)[ordinal]` silently misaligns once a face is
    /// shared between two shells, and this captures the correspondence directly instead.
    ///
    /// Pass a `BRepGraph` built from this same `shape` to populate `FaceIdentityTable.uids`
    /// — minted via `graph.findNode(for:)` on each ordinal's face `Shape`, so `IsSame` semantics
    /// hold. Without a graph, only `FaceIdentityTable.shapes` is populated.
    ///
    /// All other parameters match `shapeToBodyAndMetadata`. To also get `EdgeIdentityTable` /
    /// `VertexIdentityTable`, use `shapeToBodyMetadataAndIdentities` instead.
    public static func shapeToBodyMetadataAndIdentity(
        _ shape: Shape,
        id bodyID: String,
        color rgba: SIMD4<Float>,
        stl: Bool = false,
        deflection customDeflection: Double? = nil,
        gpuTessellation: Bool = false,
        edgeDeflection: Double = defaultEdgeDeflection,
        maxPointsPerEdge: Int = defaultMaxPointsPerEdge,
        includeMeasurements: Bool = false,
        directMesh useDirectMesh: Bool = false,
        graph: BRepGraph? = nil
    ) -> (ViewportBody?, CADBodyMetadata?, FaceIdentityTable?) {
        let (body, meta, faceIdentity, _, _) = bridgeShapeToBody(
            shape, id: bodyID, color: rgba, stl: stl, deflection: customDeflection,
            gpuTessellation: gpuTessellation, edgeDeflection: edgeDeflection,
            maxPointsPerEdge: maxPointsPerEdge, includeMeasurements: includeMeasurements,
            directMesh: useDirectMesh, graph: graph
        )
        return (body, meta, faceIdentity)
    }

    /// Overload of `shapeToBodyAndMetadata` that emits identity tables for all three pickable
    /// sub-shape kinds: `FaceIdentityTable`, `EdgeIdentityTable`, `VertexIdentityTable` (issue
    /// #43). Each maps the render-path ordinal stored in the corresponding `ViewportBody` array
    /// (`faceIndices` / `edgeIndices` / `vertexIndices`) back to the `Shape` it was extracted
    /// from, and, when `graph` is supplied, to the durable `GraphUID` minted from that graph.
    ///
    /// Pass a `BRepGraph` built from this same `shape` to populate every table's `uids`.
    /// Without a graph, only `shapes` is populated on each table.
    ///
    /// All other parameters match `shapeToBodyAndMetadata`.
    public static func shapeToBodyMetadataAndIdentities(
        _ shape: Shape,
        id bodyID: String,
        color rgba: SIMD4<Float>,
        stl: Bool = false,
        deflection customDeflection: Double? = nil,
        gpuTessellation: Bool = false,
        edgeDeflection: Double = defaultEdgeDeflection,
        maxPointsPerEdge: Int = defaultMaxPointsPerEdge,
        includeMeasurements: Bool = false,
        directMesh useDirectMesh: Bool = false,
        graph: BRepGraph? = nil
    ) -> (ViewportBody?, CADBodyMetadata?, FaceIdentityTable?, EdgeIdentityTable?, VertexIdentityTable?) {
        bridgeShapeToBody(
            shape, id: bodyID, color: rgba, stl: stl, deflection: customDeflection,
            gpuTessellation: gpuTessellation, edgeDeflection: edgeDeflection,
            maxPointsPerEdge: maxPointsPerEdge, includeMeasurements: includeMeasurements,
            directMesh: useDirectMesh, graph: graph
        )
    }

    private static func bridgeShapeToBody(
        _ shape: Shape,
        id bodyID: String,
        color rgba: SIMD4<Float>,
        stl: Bool,
        deflection customDeflection: Double?,
        gpuTessellation: Bool,
        edgeDeflection: Double,
        maxPointsPerEdge: Int,
        includeMeasurements: Bool,
        directMesh useDirectMesh: Bool,
        graph: BRepGraph?
    ) -> (ViewportBody?, CADBodyMetadata?, FaceIdentityTable?, EdgeIdentityTable?, VertexIdentityTable?) {
        let measurements: ShapeMeasurements? = includeMeasurements ? shape.measure() : nil
        let mesh: Mesh?
        if let customDeflection {
            mesh = shape.mesh(linearDeflection: customDeflection)
        } else if stl {
            mesh = shape.mesh(linearDeflection: 1.0)
        } else if gpuTessellation {
            // Coarser CPU mesh — GPU PN tessellation will refine
            mesh = shape.mesh(parameters: tessellationMeshParams)
        } else {
            // Default: fine CPU mesh for smooth rendering without GPU tessellation.
            mesh = shape.mesh(parameters: highQualityMeshParams)
        }
        guard let mesh else {
            let edgePolylines = extractEdgePolylines(
                from: shape, deflection: edgeDeflection, maxPointsPerEdge: maxPointsPerEdge
            )
            if !edgePolylines.isEmpty {
                let edges = edgePolylines.map { $0.points }
                let pickVerts = sourceShapeVertexPickData(from: shape)
                let edgeIndices = flattenEdgeIndices(edgePolylines)
                let body = ViewportBody(
                    id: bodyID, vertexData: [], indices: [],
                    edges: edges,
                    edgeIndices: edgeIndices,
                    vertices: pickVerts.positions,
                    vertexIndices: pickVerts.indices,
                    color: rgba
                )
                let meta = CADBodyMetadata(
                    faceIndices: [], edgePolylines: edgePolylines,
                    vertices: pickVerts.positions,
                    measurements: measurements
                )
                let faceIdentity = FaceIdentityTable(shapes: [], uids: graph != nil ? [] : nil)
                let edgeIdentity = makeEdgeIdentityTable(from: shape, graph: graph)
                let vertexIdentity = makeVertexIdentityTable(from: shape, graph: graph)
                return (body, meta, faceIdentity, edgeIdentity, vertexIdentity)
            }
            return (nil, nil, nil, nil, nil)
        }

        let triangles = mesh.trianglesWithFaces()
        var faceIndices: [Int32] = []
        faceIndices.reserveCapacity(triangles.count)
        for tri in triangles {
            faceIndices.append(tri.faceIndex)
        }

        let indices = mesh.indices

        let edgePolylines = extractEdgePolylines(
            from: shape, deflection: edgeDeflection, maxPointsPerEdge: maxPointsPerEdge
        )
        let edges = edgePolylines.map { $0.points }
        let pickVerts = sourceShapeVertexPickData(from: shape)
        let edgeIndices = flattenEdgeIndices(edgePolylines)

        let body: ViewportBody
        if useDirectMesh {
            // Direct path (Option A): forward OCCT's de-interleaved triangulation untouched —
            // no interleave loop, no NormalSmoothing, no second CPU copy. `vertexData` /
            // `normalData` are single contiguous-Float copies straight from the kernel.
            body = ViewportBody.directMesh(
                id: bodyID,
                positions: mesh.vertexData,
                normals: mesh.normalData,
                indices: indices,
                color: rgba,
                faceIndices: faceIndices,
                edges: edges
            )
        } else {
            // Interleaved path: repack into stride-6 [px,py,pz,nx,ny,nz] and crease-smooth.
            let vertexCount = mesh.vertexCount
            var vertexData: [Float] = []
            vertexData.reserveCapacity(vertexCount * 6)
            let positions = mesh.vertices
            let normals = mesh.normals
            for i in 0..<vertexCount {
                let p = positions[i]
                let n = normals[i]
                vertexData.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z])
            }
            // Apply crease-aware normal smoothing for smooth curved surfaces
            NormalSmoothing.smoothNormals(vertexData: &vertexData, indices: indices)

            body = ViewportBody(
                id: bodyID, vertexData: vertexData, indices: indices,
                edges: edges, faceIndices: faceIndices,
                edgeIndices: edgeIndices,
                vertices: pickVerts.positions,
                vertexIndices: pickVerts.indices,
                color: rgba
            )
        }
        let meta = CADBodyMetadata(
            faceIndices: faceIndices, edgePolylines: edgePolylines,
            vertices: pickVerts.positions,
            measurements: measurements
        )
        let faceIdentity = makeFaceIdentityTable(from: shape, graph: graph)
        let edgeIdentity = makeEdgeIdentityTable(from: shape, graph: graph)
        let vertexIdentity = makeVertexIdentityTable(from: shape, graph: graph)

        return (body, meta, faceIdentity, edgeIdentity, vertexIdentity)
    }

    /// Builds a `FaceIdentityTable` from `shape.faces()` — the same raw, non-deduplicating
    /// `TopExp_Explorer` traversal `OCCTShapeCreateMeshWithParams` uses to assign
    /// `Mesh.Triangle.faceIndex` — so `shapes[ordinal]` always names the exact face tessellated
    /// into the triangles carrying that ordinal, even when a face is shared between two shells
    /// (where it appears once per shell here, but collapses to one node in `graph`).
    private static func makeFaceIdentityTable(from shape: Shape, graph: BRepGraph?) -> FaceIdentityTable {
        let faceShapes = shape.faces().compactMap { Shape.fromFace($0) }
        guard let graph else {
            return FaceIdentityTable(shapes: faceShapes)
        }
        let uids: [BRepGraph.GraphUID?] = faceShapes.map { faceShape in
            guard let node = graph.findNode(for: faceShape) else { return nil }
            return graph.uid(ofNodeKind: Int(node.kind.rawValue), index: node.index)
        }
        return FaceIdentityTable(shapes: faceShapes, uids: uids)
    }

    /// Builds an `EdgeIdentityTable` from `shape.edges()`, the same `TopTools_IndexedMapOfShape`
    /// traversal `Shape.edge(at:)` and the bulk edge-polyline extractor behind
    /// `ViewportBody.edgeIndices` use, so `shapes[ordinal]` always names the exact edge behind
    /// the segments carrying that ordinal.
    private static func makeEdgeIdentityTable(from shape: Shape, graph: BRepGraph?) -> EdgeIdentityTable {
        let edgeShapes = shape.edges().compactMap { Shape.fromEdge($0) }
        guard let graph else {
            return EdgeIdentityTable(shapes: edgeShapes)
        }
        let uids: [BRepGraph.GraphUID?] = edgeShapes.map { edgeShape in
            guard let node = graph.findNode(for: edgeShape) else { return nil }
            return graph.uid(ofNodeKind: Int(node.kind.rawValue), index: node.index)
        }
        return EdgeIdentityTable(shapes: edgeShapes, uids: uids)
    }

    /// Builds a `VertexIdentityTable` from `shape.subShapes(ofType: .vertex)`, the same
    /// `TopTools_IndexedMapOfShape` traversal `Shape.vertices()` / `Shape.vertex(at:)` behind
    /// `ViewportBody.vertexIndices` use, so `shapes[ordinal]` always names the exact vertex
    /// behind the pick point carrying that ordinal.
    private static func makeVertexIdentityTable(from shape: Shape, graph: BRepGraph?) -> VertexIdentityTable {
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

    // MARK: - Edge / Vertex extraction helpers

    /// Flatten polyline-keyed edge indices into the per-segment array
    /// `ViewportBody.edgeIndices` expects. A polyline of N points contributes
    /// (N - 1) line segments, each tagged with the source edge's index.
    private static func flattenEdgeIndices(
        _ edgePolylines: [(edgeIndex: Int, points: [SIMD3<Float>])]
    ) -> [Int32] {
        var result: [Int32] = []
        for (edgeIndex, points) in edgePolylines {
            let segments = max(points.count - 1, 0)
            if segments > 0 {
                result.append(contentsOf: repeatElement(Int32(edgeIndex), count: segments))
            }
        }
        return result
    }

    /// Default linear deflection for wireframe edge polyline extraction.
    /// Fine enough for typical CAD edges; coarsen via `edgeDeflection` for
    /// dense curved geometry (e.g. helical threads) — see issue #24.
    public static let defaultEdgeDeflection: Double = 0.005

    /// Default per-edge point cap for wireframe polyline extraction.
    public static let defaultMaxPointsPerEdge: Int = 1000

    private static func extractEdgePolylines(
        from shape: Shape,
        deflection: Double = defaultEdgeDeflection,
        maxPointsPerEdge: Int = defaultMaxPointsPerEdge
    ) -> [(edgeIndex: Int, points: [SIMD3<Float>])] {
        // One bulk bridge pass (OCCTSwift ≥1.10.0). Looping `edgePolyline(at:)` rebuilds
        // the shape's full edge map per call — O(edges²), 20s at 12k edges and the reason
        // mesh-scale imports hung every shapeToBodyAndMetadata consumer (OCCTSwift#275,
        // OCCTMCP#75). The INDEXED variant is required here, not `allEdgePolylines`:
        // `edgeIndex` feeds `ViewportBody.edgeIndices` pick identity, and the dense
        // variant's positions drift off the `edge(at:)` index space at the first
        // skipped (degenerate/failed) edge.
        var result: [(edgeIndex: Int, points: [SIMD3<Float>])] = []
        for (edgeIndex, polyline) in shape.allEdgePolylinesIndexed(
            deflection: deflection, maxPointsPerEdge: maxPointsPerEdge
        ) {
            let floatPoints = polyline.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
            guard floatPoints.count >= 2 else { continue }
            result.append((edgeIndex: edgeIndex, points: floatPoints))
        }
        return result
    }

    /// Collect source-shape vertices and their identity index array for the
    /// vertex-pick pass. Indexing matches `shape.vertices()` so consumers can
    /// round-trip a picked `primitiveIndex` back to a `TopoDS_Vertex` via
    /// `shape.vertex(at: primitiveIndex)`.
    private static func sourceShapeVertexPickData(
        from shape: Shape
    ) -> (positions: [SIMD3<Float>], indices: [Int32]) {
        let sourceVerts = shape.vertices()
        let positions = sourceVerts.map {
            SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
        }
        let indices = (0..<sourceVerts.count).map(Int32.init)
        return (positions, indices)
    }
}
