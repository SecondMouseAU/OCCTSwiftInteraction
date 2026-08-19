// CADFileLoader.swift
// OCCTSwiftTools
//
// Bridge layer: wraps OCCTSwiftIO's headless `ShapeLoader` to produce
// `ViewportBody` + `CADBodyMetadata` from CAD files. The file-format,
// progress, exporter, and manifest types live in `OCCTSwiftIO`; this file
// owns only the Shape → Body bridge logic.

import Foundation
import OCCTSwift
@_exported import OCCTSwiftIO
import OCCTSwiftViewport
import simd

/// Result of loading a CAD file with renderable bodies attached.
///
/// For headless / shape-only loads (no Viewport dep), use
/// `OCCTSwiftIO.ShapeLoader.load` and `ShapeLoadResult` directly.
public struct CADLoadResult: @unchecked Sendable {
    public var bodies: [ViewportBody]
    public var metadata: [String: CADBodyMetadata]

    /// Every shape the load produced, in load order.
    ///
    /// **Do not pair this with `bodies` positionally.** It holds on the primary bridge, where both
    /// arrays are appended together only on tessellation success, but not for the STL/IGES robust
    /// reload (`reloadRobustAndBridge`), which appends a shape even when that input produced no
    /// body and so shifts every later pairing: a body would be handed another body's geometry.
    /// Use `identity` instead, which the loader keys by body id at the moment each body is
    /// created, so the pairing is never inferred from the outside. See OCCTSwiftInteraction#7.
    public var shapes: [Shape]
    public var dimensions: [DimensionInfo]
    public var geomTolerances: [GeomToleranceInfo]
    public var datums: [DatumInfo]

    /// The shape, `BRepGraph` and three ordinal-to-identity tables for each loaded body, keyed by
    /// `ViewportBody.id`.
    ///
    /// Empty unless the load was asked for it (`includeIdentity: true`), because building it costs
    /// a `BRepGraph` per body and a consumer that only renders should not pay for one. See
    /// `ShapeIdentity` for the measured cost.
    ///
    /// This is the supported way to get identity out of a multi-body file load. Before
    /// OCCTSwiftInteraction#7 there was none, and every consumer rebuilt the tables from
    /// `shapes` and `bodies` itself, which is both duplicated work and the pairing hazard
    /// documented on `shapes` above.
    public var identity: [String: ShapeIdentity]

    public init(
        bodies: [ViewportBody] = [], metadata: [String: CADBodyMetadata] = [:],
        shapes: [Shape] = [], dimensions: [DimensionInfo] = [],
        geomTolerances: [GeomToleranceInfo] = [], datums: [DatumInfo] = [],
        identity: [String: ShapeIdentity] = [:]
    ) {
        self.bodies = bodies
        self.metadata = metadata
        self.shapes = shapes
        self.dimensions = dimensions
        self.geomTolerances = geomTolerances
        self.datums = datums
        self.identity = identity
    }
}

/// Loads CAD files via OCCTSwiftIO and bridges the resulting shapes to
/// `ViewportBody` + `CADBodyMetadata` for renderable + pickable consumers.
public enum CADFileLoader {

    /// Loads a CAD file and returns viewport bodies with selection metadata.
    /// - Parameters:
    ///   - url: location of the CAD file to load.
    ///   - format: the file's CAD format, selecting which OCCTSwiftIO loader is used.
    ///   - progress: optional progress + cancellation observer. Honored by `.step` and
    ///     `.iges` formats only; STL/OBJ/BREP loaders are single-call upstream and don't
    ///     surface progress.
    ///   - includeIdentity: If `true`, populates `CADLoadResult.identity` with a `ShapeIdentity`
    ///     per loaded body: the shape it was tessellated from, a `BRepGraph` built for it, and the
    ///     three ordinal-to-identity tables `SubShapePickResolver` reads. Off by default because
    ///     each body costs a `BRepGraph`, which serialises the whole shape to a BREP string on the
    ///     way through (measured at roughly half the cost of meshing it), and a consumer that
    ///     loads geometry to render or reproject it never picks. Turn it on for anything that
    ///     does: it is the only supported way to get identity out of a multi-body file load, and
    ///     it is built inside the loader precisely so no consumer has to pair `shapes` with
    ///     `bodies` itself. See OCCTSwiftInteraction#7.
    /// - Returns: The loaded bodies with their selection metadata.
    /// - Throws: Whatever the underlying `OCCTSwiftIO.ShapeLoader.load` throws for the given
    ///   `format` (a malformed or unreadable file), or `OCCTSwift.ImportError.cancelled` if
    ///   `progress.shouldCancel()` returns `true` during a `.step`/`.iges` load.
    public static func load(
        from url: URL,
        format: CADFileFormat,
        progress: ImportProgress? = nil,
        includeIdentity: Bool = false
    ) async throws -> CADLoadResult {
        let ioResult = try await ShapeLoader.load(from: url, format: format, progress: progress)
        return bridgeWithFallback(
            ioResult: ioResult, idPrefix: format.rawValue,
            url: url, format: format, progress: progress,
            includeIdentity: includeIdentity
        )
    }

    /// Loads bodies from a script manifest (manifest.json + BREP files).
    ///
    /// - Parameters:
    ///   - url: location of the manifest.
    ///   - includeIdentity: see `load(from:format:progress:includeIdentity:)`.
    /// - Returns: The loaded bodies with their selection metadata, and, when asked, one
    ///   `ShapeIdentity` per body.
    /// - Throws: Whatever `OCCTSwiftIO.ShapeLoader.loadFromManifest` throws for an unreadable or
    ///   malformed manifest, or for a BREP file it references that cannot be read.
    public static func loadFromManifest(
        at url: URL,
        includeIdentity: Bool = false
    ) throws -> CADLoadResult {
        let ioResult = try ShapeLoader.loadFromManifest(at: url)

        var bodies: [ViewportBody] = []
        var metadata: [String: CADBodyMetadata] = [:]
        var shapes: [Shape] = []
        var identity: [String: ShapeIdentity] = [:]

        for (index, pair) in ioResult.shapesWithColors.enumerated() {
            let descriptor = ioResult.manifest?.bodies[index]
            let bodyID = "script-\(descriptor?.id ?? "\(index)")"
            let rgba = pair.color ?? SIMD4<Float>(0.7, 0.7, 0.7, 1.0)

            let (body, meta) = shapeToBodyAndMetadata(pair.shape, id: bodyID, color: rgba)
            if let body {
                bodies.append(body)
                shapes.append(pair.shape)
                if let meta { metadata[bodyID] = meta }
                if includeIdentity { identity[bodyID] = ShapeIdentity(shape: pair.shape) }
            }
        }

        return CADLoadResult(
            bodies: bodies, metadata: metadata, shapes: shapes, identity: identity)
    }

    // MARK: - Bridge with STL/IGES robust fallback

    /// STL and IGES files commonly fail the primary loader → bridge path (mesh generation
    /// returns nil because the input has gaps OCCT's basic importer can't close).
    ///
    /// Fall back to the sewing/healing variant on per-shape bridge failure. STEP / OBJ / BREP
    /// have no such fallback; the primary loader is the only one.
    private static func bridgeWithFallback(
        ioResult: ShapeLoadResult,
        idPrefix: String,
        url: URL,
        format: CADFileFormat,
        progress: ImportProgress?,
        includeIdentity: Bool
    ) -> CADLoadResult {
        var bodies: [ViewportBody] = []
        var metadata: [String: CADBodyMetadata] = [:]
        var shapes: [Shape] = []
        var identity: [String: ShapeIdentity] = [:]
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
                if includeIdentity { identity[bodyID] = ShapeIdentity(shape: pair.shape) }
            } else if format == .stl || format == .iges {
                needsRobustReload = true
                break
            }
        }

        // STL/IGES fallback path: re-load via the robust loader and bridge again.
        // Since OCCTSwift v1.11.3 a multibody STL comes back as a compound of
        // solids (OCCTSwift#302), so this is no longer single-shape; the reload
        // splits it into one ViewportBody per body.
        if needsRobustReload {
            return reloadRobustAndBridge(
                idPrefix: idPrefix, url: url, format: format, progress: progress,
                includeIdentity: includeIdentity)
        }

        return CADLoadResult(
            bodies: bodies, metadata: metadata, shapes: shapes,
            dimensions: ioResult.dimensions,
            geomTolerances: ioResult.geomTolerances,
            datums: ioResult.datums,
            identity: identity
        )
    }

    private static func reloadRobustAndBridge(
        idPrefix: String, url: URL, format: CADFileFormat, progress: ImportProgress?,
        includeIdentity: Bool
    ) -> CADLoadResult {
        // The robust reload mirrors the primary load's blocking call; we're
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
            var identity: [String: ShapeIdentity] = [:]
            for (index, pair) in ioRobust.shapesWithColors.enumerated() {
                let bodyID = "\(idPrefix)-\(index)"
                let rgba = pair.color ?? SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
                let (body, meta) = shapeToBodyAndMetadata(pair.shape, id: bodyID, color: rgba)
                if let body {
                    bodies.append(body)
                    shapes.append(pair.shape)
                    if let meta { metadata[bodyID] = meta }
                    // Keyed by the body id this shape actually produced, in the same branch that
                    // produced it. This is the loop that creates the pairing hazard documented on
                    // `CADLoadResult.shapes`: the `else` below appends a shape with no body, so
                    // every later positional pairing shifts. Identity never pairs positionally, so
                    // there is nothing here for a consumer to get wrong (OCCTSwiftInteraction#7).
                    if includeIdentity { identity[bodyID] = ShapeIdentity(shape: pair.shape) }
                } else {
                    shapes.append(pair.shape)
                }
            }
            return CADLoadResult(
                bodies: bodies, metadata: metadata, shapes: shapes, identity: identity)
        } catch {
            return CADLoadResult()
        }
    }

    /// One `shapesWithColors` entry per body, so a multibody robust reload becomes
    /// one `ViewportBody` per body rather than a single lumped one.
    ///
    /// Mirrors `OCCTSwiftIO.ShapeLoader`'s own split; this path calls
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
        p.deflection = 0.03  // 3× finer than default 0.1
        p.angle = 0.2  // ~11° (vs default 0.5 rad ≈ 29°)
        p.angleInterior = 0.2  // Match interior B-spline quality
        p.controlSurfaceDeflection = true
        p.inParallel = true
        return p
    }()

    /// Moderate mesh parameters for GPU tessellation (PN triangles).
    ///
    /// Balanced: enough triangles for good normals, large enough for visible PN displacement.
    public static let tessellationMeshParams: MeshParameters = {
        var p = MeshParameters.default
        p.deflection = 0.1  // OCCT default: moderate triangle density
        p.angle = 0.35  // ~20°: good normal quality for PN patches
        p.controlSurfaceDeflection = true
        p.inParallel = true
        return p
    }()

    // MARK: - Shape → Body bridge

    /// Converts an OCCTSwift Shape to a ViewportBody and optional metadata.
    /// - Parameters:
    ///   - shape: the source `Shape` to convert.
    ///   - bodyID: stable id for the resulting body.
    ///   - rgba: fallback RGBA color for the body.
    ///   - stl: If true, uses coarser deflection suitable for pre-tessellated STL data.
    ///   - customDeflection: Custom linear deflection override. Lower = smoother (default 0.1,
    ///     STL uses 1.0).
    ///   - gpuTessellation: If true, uses coarser CPU mesh (GPU PN triangles will refine).
    ///   - edgeDeflection: Linear deflection for the **wireframe edge polylines**
    ///     (independent of the triangle `deflection`). Lower = denser/smoother edges.
    ///     Defaults to `defaultEdgeDeflection` (0.005). Coarsen this for geometry whose
    ///     edges follow long fine curves, e.g. helical threads, where the default
    ///     produces an illegibly dense, slow-to-render wireframe (issue #24).
    ///   - maxPointsPerEdge: Hard cap on points per edge polyline.
    ///     Defaults to `defaultMaxPointsPerEdge` (1000). A lower cap bounds the line
    ///     count for pathologically long edges regardless of `edgeDeflection`.
    ///   - includeMeasurements: If true, populates `metadata.measurements`
    ///     with per-face areas and per-edge lengths (via `Shape.measure`). Off by
    ///     default; face-area iteration is O(faces) and not free for large assemblies.
    ///   - useDirectMesh: If true, hand OCCT's de-interleaved triangulation
    ///     (`mesh.vertexData` / `mesh.normalData`) straight to the renderer via
    ///     `ViewportBody.directMesh(...)`, skipping the per-vertex interleave loop, the
    ///     `NormalSmoothing` pass, and the extra resident CPU copy. A load-time / memory
    ///     win for large or many-body scenes; the rendered result is the same (OCCT's
    ///     per-vertex normals from a fine B-Rep mesh are already analytic-quality; see
    ///     OCCTSwiftViewport v1.1.22 / #81, where skipping NormalSmoothing is the intended
    ///     behaviour). **Caveat:** a direct body carries the mesh vertices (for bbox / fit /
    ///     CPU raycast) but not the B-Rep corner vertex-pick data or per-segment edge-pick
    ///     indices, so face display, face GPU-pick, CPU raycast and edge *display* work, but
    ///     B-Rep vertex-picking and edge-index picking on the body itself do not. The
    ///     returned `metadata` still carries the full pick vertices / face indices, so an app
    ///     can drive those itself. Off by default (source/behaviour-compatible).
    /// - Returns: The body (`nil` if mesh generation and the edge-polyline fallback both
    ///   produce nothing) paired with its selection metadata.
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
        let (body, meta, _) = bridgeShapeToBody(
            shape, id: bodyID, color: rgba, stl: stl, deflection: customDeflection,
            gpuTessellation: gpuTessellation, edgeDeflection: edgeDeflection,
            maxPointsPerEdge: maxPointsPerEdge, includeMeasurements: includeMeasurements,
            directMesh: useDirectMesh, identity: false, graph: nil
        )
        return (body, meta)
    }

    /// Overload of `shapeToBodyAndMetadata` that also emits a `FaceIdentityTable` mapping every
    /// ordinal in the returned metadata's `faceIndices` back to the `Shape` it was tessellated
    /// from, and, when `graph` is supplied, to the durable `GraphUID` minted from that graph.
    /// See issue #42 and `FaceIdentityTable`'s documentation for why this exists: pre-OCCTSwift-2.0.0,
    /// a face ordinal resolved via `shape.subShapes(ofType: .face)[ordinal]` silently misaligned
    /// once a face was shared between two shells, and this captures the correspondence directly
    /// instead of relying on two enumerations agreeing. OCCTSwift v2.0.0 (#541/#613) closed that
    /// particular divergence upstream (see `makeFaceIdentityTable` below), but the table remains
    /// the cheap, identity-correct path: no re-walk of `shape.faces()` per pick, and `GraphUID`
    /// resolution needs `graph.findNode(for:)`'s identity match regardless of enumeration.
    ///
    /// Pass a `BRepGraph` built from this same `shape` to populate `FaceIdentityTable.uids`,
    /// minted via `graph.findNode(for:)` on each ordinal's face `Shape`, so `IsSame` semantics
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
        let (body, meta, identity) = bridgeShapeToBody(
            shape, id: bodyID, color: rgba, stl: stl, deflection: customDeflection,
            gpuTessellation: gpuTessellation, edgeDeflection: edgeDeflection,
            maxPointsPerEdge: maxPointsPerEdge, includeMeasurements: includeMeasurements,
            directMesh: useDirectMesh, identity: true, graph: graph
        )
        return (body, meta, identity?.faces)
    }

    /// Overload of `shapeToBodyAndMetadata` that emits identity tables for all three pickable
    /// sub-shape kinds: `FaceIdentityTable`, `EdgeIdentityTable`, `VertexIdentityTable` (issue #43).
    ///
    /// Each maps the render-path ordinal stored in the corresponding `ViewportBody` array
    /// (`faceIndices` / `edgeIndices` / `vertexIndices`) back to the `Shape` it was extracted
    /// from, and, when `graph` is supplied, to the durable `GraphUID` minted from that graph.
    ///
    /// Pass a `BRepGraph` built from this same `shape` to populate every table's `uids`.
    /// Without a graph, only `shapes` is populated on each table.
    ///
    /// All other parameters match `shapeToBodyAndMetadata`.
    ///
    /// Table construction itself is `ShapeIdentity`'s since OCCTSwiftInteraction#7; this overload
    /// is the one-pass convenience for a caller that wants a mesh and identity from the same call.
    /// A caller that already has a `ViewportBody`, or that wants identity for a shape it is not
    /// tessellating, builds a `ShapeIdentity` directly instead.
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
    ) -> (
        ViewportBody?, CADBodyMetadata?, FaceIdentityTable?, EdgeIdentityTable?,
        VertexIdentityTable?
    ) {
        let (body, meta, identity) = bridgeShapeToBody(
            shape, id: bodyID, color: rgba, stl: stl, deflection: customDeflection,
            gpuTessellation: gpuTessellation, edgeDeflection: edgeDeflection,
            maxPointsPerEdge: maxPointsPerEdge, includeMeasurements: includeMeasurements,
            directMesh: useDirectMesh, identity: true, graph: graph
        )
        return (body, meta, identity?.faces, identity?.edges, identity?.vertices)
    }

    // The `identity` flag is whether to build the `ShapeIdentity` at all, which is distinct from
    // `graph == nil` (build the tables, but without durable uids). Skipping it entirely is what
    // `shapeToBodyAndMetadata` wants: it discards the tables, and building three of them walks the
    // shape's face, edge and vertex maps for nothing.
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
        identity: Bool,
        graph: BRepGraph?
    ) -> (ViewportBody?, CADBodyMetadata?, ShapeIdentity?) {
        let measurements: ShapeMeasurements? = includeMeasurements ? shape.measure() : nil
        let mesh: Mesh?
        if let customDeflection {
            mesh = shape.mesh(linearDeflection: customDeflection)
        } else if stl {
            mesh = shape.mesh(linearDeflection: 1.0)
        } else if gpuTessellation {
            // Coarser CPU mesh: GPU PN tessellation will refine
            mesh = shape.mesh(parameters: tessellationMeshParams)
        } else {
            // Default: fine CPU mesh for smooth rendering without GPU tessellation.
            mesh = shape.mesh(parameters: highQualityMeshParams)
        }
        guard let mesh else {
            return edgePolylineOnlyBridge(
                shape, id: bodyID, color: rgba, edgeDeflection: edgeDeflection,
                maxPointsPerEdge: maxPointsPerEdge, measurements: measurements,
                identity: identity, graph: graph
            )
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
            // Direct path (Option A): forward OCCT's de-interleaved triangulation untouched,
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

        return (body, meta, identity ? ShapeIdentity(shape: shape, graph: graph) : nil)
    }

    /// The bridge's fallback branch: a shape whose `mesh(...)` returned nil, rendered as edge
    /// polylines with vertex pick points and no triangles at all.
    ///
    /// Internal rather than private so it can be unit-tested directly, the same reason
    /// `bodyEntries` is. This branch fires only when meshing fails outright, which is the very
    /// condition that triggers the STL/IGES robust reload, and it is not reachable from a
    /// synthetic shape: a wire, an edge and a lone vertex all mesh to an empty `Mesh` rather than
    /// to nil (measured), so they come back through the meshed branch with `faceIndices: []`.
    ///
    /// Identity here is the ordinary `ShapeIdentity`, built the same way as on the meshed branch.
    /// It used to be special-cased, substituting an empty `FaceIdentityTable` on the grounds that
    /// no face ordinal exists when nothing was tessellated. That was the one place any copy of
    /// this logic varied a table's *content*, it was asymmetric with the edge and vertex tables
    /// built in full on this same branch, and it was inert: `SubShapePickResolver.resolveFace`
    /// bounds-checks against `faceIndices`, which is empty here, so the face table is never read
    /// through a pick either way. Dropped in favour of one rule (OCCTSwiftInteraction#7). The
    /// table now answers "which faces does this shape have, and what are their durable uids" even
    /// for a shape the mesher could not handle, which is strictly more than it answered before.
    static func edgePolylineOnlyBridge(
        _ shape: Shape,
        id bodyID: String,
        color rgba: SIMD4<Float>,
        edgeDeflection: Double,
        maxPointsPerEdge: Int,
        measurements: ShapeMeasurements?,
        identity: Bool,
        graph: BRepGraph?
    ) -> (ViewportBody?, CADBodyMetadata?, ShapeIdentity?) {
        let edgePolylines = extractEdgePolylines(
            from: shape, deflection: edgeDeflection, maxPointsPerEdge: maxPointsPerEdge
        )
        guard !edgePolylines.isEmpty else { return (nil, nil, nil) }

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
        return (body, meta, identity ? ShapeIdentity(shape: shape, graph: graph) : nil)
    }

    // MARK: - Edge / Vertex extraction helpers

    /// Flatten polyline-keyed edge indices into the per-segment array
    /// `ViewportBody.edgeIndices` expects.
    ///
    /// A polyline of N points contributes (N - 1) line segments, each tagged with the source
    /// edge's index.
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
    ///
    /// Fine enough for typical CAD edges; coarsen via `edgeDeflection` for
    /// dense curved geometry (e.g. helical threads); see issue #24.
    public static let defaultEdgeDeflection: Double = 0.005

    /// Default per-edge point cap for wireframe polyline extraction.
    public static let defaultMaxPointsPerEdge: Int = 1000

    private static func extractEdgePolylines(
        from shape: Shape,
        deflection: Double = defaultEdgeDeflection,
        maxPointsPerEdge: Int = defaultMaxPointsPerEdge
    ) -> [(edgeIndex: Int, points: [SIMD3<Float>])] {
        // One bulk bridge pass (OCCTSwift ≥1.10.0). Looping `edgePolyline(at:)` rebuilds
        // the shape's full edge map per call: O(edges²), 20s at 12k edges and the reason
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
    /// vertex-pick pass.
    ///
    /// Indexing matches `shape.vertices()` so consumers can round-trip a picked
    /// `primitiveIndex` back to a `TopoDS_Vertex` via `shape.vertex(at: primitiveIndex)`.
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
