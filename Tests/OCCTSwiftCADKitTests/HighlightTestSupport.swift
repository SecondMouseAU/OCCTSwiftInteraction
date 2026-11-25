import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftCADKit

/// Geometry shared by the suites that check a selection highlight against the model bodies as
/// drawn (OCCTSwiftInteraction#72, #73, #78, #79).
///
/// Every point is in world space: a body's local position under its own `transform`. A check
/// written that way holds whether a body is placed by its transform or by its vertex data.
enum HighlightGeometry {
    /// `local` placed by `transform`.
    static func world(_ local: SIMD3<Float>, under transform: simd_float4x4) -> SIMD3<Double> {
        let placed = transform * SIMD4<Float>(local, 1)
        return SIMD3(Double(placed.x), Double(placed.y), Double(placed.z))
    }

    /// The centroid of `triangle` in the frame of `body`.
    static func localCentroid(of triangle: Int, in body: _ViewportBody) -> SIMD3<Float> {
        let (positions, stride) =
            body.usesDirectMesh ? (body.meshPositions, 3) : (body.vertexData, 6)
        let corners = (0..<3).map { corner -> SIMD3<Float> in
            let vertex = Int(body.indices[triangle * 3 + corner])
            return SIMD3(
                positions[vertex * stride], positions[vertex * stride + 1],
                positions[vertex * stride + 2])
        }
        return (corners[0] + corners[1] + corners[2]) / 3
    }

    /// The world centroid of each triangle `body` draws.
    static func worldCentroids(of body: _ViewportBody) -> [SIMD3<Double>] {
        (0..<(body.indices.count / 3)).map {
            world(localCentroid(of: $0, in: body), under: body.transform)
        }
    }

    /// The world centroid of each triangle `body` draws on the face `shape`.
    ///
    /// A triangle is on the face when its local centroid is inside the face's bounding box, which
    /// is exact for a box: its faces are axis-aligned squares, so no other face's triangle
    /// centroid falls inside one.
    static func worldCentroids(onFace shape: Shape, of body: _ViewportBody) -> [SIMD3<Double>] {
        guard let bounds = Face(shape)?.bounds else { return [] }
        let tolerance = 1e-4
        return (0..<(body.indices.count / 3)).compactMap { triangle in
            let local = localCentroid(of: triangle, in: body)
            let point = SIMD3<Double>(Double(local.x), Double(local.y), Double(local.z))
            guard all(point .>= bounds.min - tolerance), all(point .<= bounds.max + tolerance)
            else { return nil }
            return world(local, under: body.transform)
        }
    }

    /// The world position of each end of each segment `body` draws for `edgeIndex`.
    static func worldEndpoints(ofEdge edgeIndex: Int, in body: _ViewportBody) -> [SIMD3<Double>] {
        var points: [SIMD3<Double>] = []
        var segment = 0
        for polyline in body.edges {
            for start in polyline.indices.dropLast() {
                defer { segment += 1 }
                guard segment < body.edgeIndices.count,
                    body.edgeIndices[segment] == Int32(edgeIndex)
                else { continue }
                points.append(world(polyline[start], under: body.transform))
                points.append(world(polyline[start + 1], under: body.transform))
            }
        }
        return points
    }

    /// The world position of each point `body` draws at the vertex `shape`.
    ///
    /// Found by position, not by ordinal: a box draws each of its vertices once, at the vertex's
    /// own point, and no two of them coincide.
    static func worldPoints(atVertex shape: Shape, of body: _ViewportBody) -> [SIMD3<Double>] {
        guard let position = shape.vertices().first else { return [] }
        let tolerance = 1e-4
        return body.vertices.compactMap { local in
            let point = SIMD3<Double>(Double(local.x), Double(local.y), Double(local.z))
            guard simd_distance(point, position) <= tolerance else { return nil }
            return world(local, under: body.transform)
        }
    }

    /// The world position of each point a highlight body draws, empty for `nil`.
    ///
    /// The points are its polylines' points, or its point sprites.
    static func worldPoints(of highlight: _ViewportBody?) -> [SIMD3<Double>] {
        guard let highlight else { return [] }
        let local = highlight.edges.flatMap { $0 } + highlight.vertices
        return local.map { world($0, under: highlight.transform) }
    }

    /// The points of `expected` with no partner in `actual`, and the points of `actual` left
    /// over, pairing each point at most once and within `tolerance`.
    static func unpaired(
        _ expected: [SIMD3<Double>], _ actual: [SIMD3<Double>], tolerance: Double = 1e-4
    ) -> (missing: [SIMD3<Double>], extra: [SIMD3<Double>]) {
        var extra = actual
        var missing: [SIMD3<Double>] = []
        for point in expected {
            if let partner = extra.firstIndex(where: { simd_distance($0, point) <= tolerance }) {
                extra.remove(at: partner)
            } else {
                missing.append(point)
            }
        }
        return (missing, extra)
    }
}

/// Expects the face highlight to light exactly the triangles each listed body draws on its listed
/// face, compared by world-space centroid.
@MainActor
func expectFaceHighlight(
    _ service: CADViewportService, lights faces: [(bodyID: String, face: SubShapeRef)],
    _ step: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    var drawn: [SIMD3<Double>] = []
    for (bodyID, face) in faces {
        guard let body = service.modelBody(bodyID) else {
            Issue.record("no body \(bodyID)", sourceLocation: sourceLocation)
            return
        }
        drawn += HighlightGeometry.worldCentroids(onFace: face.shape, of: body)
    }
    let (missing, extra) = HighlightGeometry.unpaired(drawn, service.highlightedFaceCentroids)
    #expect(
        missing.isEmpty && extra.isEmpty,
        """
        \(step): the highlight should light the \(drawn.count) triangles drawn on the face, but \
        \(missing.count) of them are unlit and \(extra.count) lit triangles are not drawn there
        """,
        sourceLocation: sourceLocation)
}

@MainActor
extension CADViewportService {
    /// The model body `id`, or `nil` if there is none.
    func modelBody(_ id: String) -> _ViewportBody? {
        modelBodies.first { $0.id == id }
    }

    /// The ordinary selection's highlight body for `kind` (`"face"`, `"edge"` or `"vertex"`), or
    /// `nil` when nothing of that kind is lit.
    func selectionHighlight(_ kind: String) -> _ViewportBody? {
        selectionBodies.first { $0.id == "selection_highlight_\(kind)" }
    }

    /// The world centroid of each triangle the face highlight lights; empty when it lights none.
    var highlightedFaceCentroids: [SIMD3<Double>] {
        selectionHighlight("face").map(HighlightGeometry.worldCentroids(of:)) ?? []
    }

    /// The face of body `id` that lies flat at Y = 2, a box's +Y face, or `nil` if it has none.
    func plusYFace(ofBody id: String) -> SubShapeRef? {
        guard let table = faceIdentity[id] else { return nil }
        for ordinal in table.shapes.indices {
            guard let shape = table.shape(forOrdinal: ordinal),
                let bounds = Face(shape)?.bounds,
                abs(bounds.min.y - 2) < 1e-6, abs(bounds.max.y - 2) < 1e-6
            else { continue }
            return SubShapeRef(shape: shape, uid: table.uid(forOrdinal: ordinal), ordinal: ordinal)
        }
        return nil
    }

    /// What the model body of `entity` draws for it, in world space: the centroid of each
    /// triangle on a face, each end of each segment of an edge, or a vertex's point.
    ///
    /// Empty when the body draws none of it, or there is no such body.
    func drawnPoints(of entity: PickedEntity) -> [SIMD3<Double>] {
        guard let body = modelBody(entity.bodyID) else { return [] }
        switch entity {
        case .face(let info):
            return HighlightGeometry.worldCentroids(onFace: info.shape, of: body)
        case .edge(let info):
            return HighlightGeometry.worldEndpoints(ofEdge: info.edgeIndex, in: body)
        case .vertex(let info):
            return HighlightGeometry.worldPoints(atVertex: info.shape, of: body)
        }
    }

    /// What the highlight of the kind of `entity` lights, in world space.
    ///
    /// In the units `drawnPoints(of:)` uses for that kind.
    func litPoints(ofKindOf entity: PickedEntity) -> [SIMD3<Double>] {
        switch entity {
        case .face: highlightedFaceCentroids
        case .edge: HighlightGeometry.worldPoints(of: selectionHighlight("edge"))
        case .vertex: HighlightGeometry.worldPoints(of: selectionHighlight("vertex"))
        }
    }

    /// The first vertex of body `id` at X = `x`, enriched as a selection made without a pick, or
    /// `nil` if the body has no vertex there.
    func vertex(ofBody id: String, atX x: Double) -> PickedVertexInfo? {
        guard let table = vertexIdentity[id],
            let ordinal = table.shapes.indices.first(where: { ordinal in
                table.shapes[ordinal].vertices().first.map { abs($0.x - x) < 1e-6 } == true
            })
        else { return nil }
        let ref = SubShapeRef(
            shape: table.shapes[ordinal], uid: table.uid(forOrdinal: ordinal), ordinal: ordinal)
        return enrichVertex(ref: ref, bodyID: id, renderPosition: nil)
    }

    /// Selects the face `ref` of body `id` with `scheme`, as a selection made without a pick.
    func selectFace(_ ref: SubShapeRef, ofBody id: String, scheme: SelectionScheme = .replace) {
        guard let info = enrichFace(ref: ref, bodyID: id, triangleIndex: nil) else {
            Issue.record("face \(ref.ordinal) of \(id) did not enrich")
            return
        }
        select(.face(info), scheme: scheme)
    }
}
