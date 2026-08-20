// CADViewportService+Selection.swift
// OCCTSwiftCADKit
//
// Split out of CADViewportService.swift for OCCTSwiftInteraction#13 (code-structure policy).
// The service's stored state stays in the core file; this is the selection surface of the same
// type. A move, not a rewrite: the bodies below are unchanged.

import Combine
import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import SwiftUI
import simd

@MainActor
extension CADViewportService {

    // MARK: - Selection

    /// Clear the current selection (and any highlight bodies).
    ///
    /// Clears the interactive context's selection, which is the one selection there is, so
    /// this also drops any whole-body or AIS-side entries, not just this service's sub-shape
    /// projection.
    public func clearSelection() {
        interactiveContext.clearSelection()
        // Emptying `selection` itself is the `$selection` sink's job, and it has already run
        // (synchronously) if anything changed. What is left here is the part this method has
        // always done unconditionally, including when the selection was already empty: drop
        // the highlight bodies and rebuild the viewport.
        selectionBodies = []
        rebuildBodies()
    }

    /// Adds, removes, or replaces `entity` in the selection per `scheme`.
    ///
    /// Delegates to `interactiveContext.select(_:scheme:)`, which holds the selection.
    /// `SelectionScheme`'s semantics are the interactive context's own, the same ones
    /// `selectRectangle`/`selectPolygon` area selection uses: `.replace` assigns, `.add`
    /// inserts if absent, `.remove` drops it, `.xor` toggles it.
    ///
    /// Membership is `SubShapeRef`'s rule (the durable `uid` when both sides have one, else
    /// the render-path ordinal), which is what `PickedEntity`'s own `Equatable` has always
    /// mirrored, so the same durable face/edge/vertex is recognized as already-selected
    /// regardless of which ephemeral ordinal it was picked at.
    ///
    /// An entity naming a body this service has not loaded still selects: it gets its own
    /// `InteractiveObject` like any other body id, so a caller staging a pick by hand
    /// (an escalation request, a test) behaves the same as a real one.
    public func select(_ entity: PickedEntity, scheme: SelectionScheme = .replace) {
        let subShape = subShape(for: entity)
        // Before delegating, so the `$selection` sink finds the enrichment already cached and
        // does not have to rebuild it from the bare ref.
        selectionInfo[subShape] = entity
        interactiveContext.select(subShape, scheme: scheme)
    }

    /// The interactive context's name for `entity`: its `SubShapeRef` plus the
    /// `InteractiveObject` standing for the body it was picked on.
    private func subShape(for entity: PickedEntity) -> OCCTSwiftTools.SubShape {
        let object = object(forBody: entity.bodyID, fallbackShape: entity.ref.shape)
        switch entity {
        case .face(let info): return .face(object, ref: info.ref)
        case .edge(let info): return .edge(object, ref: info.ref)
        case .vertex(let info): return .vertex(object, ref: info.ref)
        }
    }

    /// The `InteractiveObject` standing for `bodyID`, minted on first use and stable
    /// thereafter.
    ///
    /// `fallbackShape` is only used for a body id this service has never loaded, where there
    /// is no body shape to point at. It never affects identity: `InteractiveObject` compares
    /// and hashes by `id` alone.
    private func object(forBody bodyID: String, fallbackShape: OCCTSwift.Shape)
        -> OCCTSwiftTools.InteractiveObject
    {
        let id: UUID
        if let existing = bodyObjectIDs[bodyID] {
            id = existing
        } else {
            id = UUID()
            bodyObjectIDs[bodyID] = id
            objectBodyIDs[id] = bodyID
        }
        return OCCTSwiftTools.InteractiveObject(id: id, shape: bodyShapes[bodyID] ?? fallbackShape)
    }

    /// Re-projects the interactive context's selection into `selection` and rebuilds the
    /// highlight bodies.
    ///
    /// Takes the new selection as an argument rather than reading `interactiveContext`,
    /// because the `$selection` sink that drives it fires during `willSet`, when the context
    /// still reports the previous value.
    func syncSelection(with newSelection: Selection) {
        let subShapes = newSelection.subshapes
        let projected =
            subShapes
            .compactMap { pickedEntity(for: $0) }
            .sorted(by: Self.selectionOrder)
        selectionInfo = selectionInfo.filter { subShapes.contains($0.key) }
        guard projected != selection else { return }
        selection = projected
        rebuildSelectionHighlights()  // also calls rebuildBodies()
    }

    /// Deterministic ordering for `selection`: body id, then kind, then render-path ordinal.
    ///
    /// The underlying state is a `Set<SubShape>`, so there is no insertion order left to
    /// preserve; an unordered projection would make `selection` differ run to run.
    private static func selectionOrder(_ lhs: PickedEntity, _ rhs: PickedEntity) -> Bool {
        func rank(_ entity: PickedEntity) -> Int {
            switch entity {
            case .face: return 0
            case .edge: return 1
            case .vertex: return 2
            }
        }
        return (lhs.bodyID, rank(lhs), lhs.ref.ordinal)
            < (rhs.bodyID, rank(rhs), rhs.ref.ordinal)
    }

    /// The enrichment for one selected sub-shape: the value cached when this service resolved
    /// or was handed the pick, else built on demand.
    ///
    /// `nil` for a `.body` sub-shape (no whole-body `PickedEntity` case), for a body this
    /// service does not have geometry for, and for anything whose enrichment fails.
    private func pickedEntity(for subShape: OCCTSwiftTools.SubShape) -> PickedEntity? {
        if let cached = selectionInfo[subShape] { return cached }
        guard let bodyID = objectBodyIDs[subShape.object.id] else { return nil }
        switch subShape {
        case .body:
            return nil
        case .face(_, let ref):
            return enrichFace(ref: ref, bodyID: bodyID, triangleIndex: nil).map(PickedEntity.face)
        case .edge(_, let ref):
            return enrichEdge(ref: ref, bodyID: bodyID).map(PickedEntity.edge)
        case .vertex(_, let ref):
            return enrichVertex(ref: ref, bodyID: bodyID, renderPosition: nil).map(
                PickedEntity.vertex)
        }
    }

    /// Aggregate measures over `selection`: count by kind, total face area, total edge
    /// length, and combined bounds.
    ///
    /// `nil` when nothing is selected. Whole-body selections do not contribute, for the same
    /// reason they do not appear in `selection`.
    public var selectionMeasurements: SelectionMeasurements? {
        guard !selection.isEmpty else { return nil }

        var faceCount = 0
        var edgeCount = 0
        var vertexCount = 0
        var totalArea = 0.0
        var totalLength = 0.0
        var minPt = SIMD3<Double>(repeating: .infinity)
        var maxPt = SIMD3<Double>(repeating: -.infinity)

        func absorb(_ bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) {
            minPt = SIMD3(
                min(minPt.x, bounds.min.x), min(minPt.y, bounds.min.y), min(minPt.z, bounds.min.z))
            maxPt = SIMD3(
                max(maxPt.x, bounds.max.x), max(maxPt.y, bounds.max.y), max(maxPt.z, bounds.max.z))
        }

        for entity in selection {
            switch entity {
            case .face(let info):
                faceCount += 1
                totalArea += info.area
                // Re-derives the face's own 3D bounding box rather than reading `info.bounds`,
                // which is deliberate and not a missed reuse: `FaceBounds` is XY only and
                // `Float`, while this aggregate is 3D and `Double`. The edge and vertex
                // branches below read their cached values because those already are 3D.
                if let face = Face(info.shape), let faceBounds = face.bounds {
                    absorb(faceBounds)
                }
            case .edge(let info):
                edgeCount += 1
                totalLength += info.length
                // Uses the endpoints already captured on PickedEdgeInfo at pick time,
                // rather than re-deriving via Edge(info.shape): cheaper, and immune to
                // that conversion failing for a straight line (bounds is exact either way;
                // a curved edge's true bounds can bow slightly outside its endpoints, but
                // this is a selection-level aggregate, not a precision measurement).
                absorb(
                    (
                        min: SIMD3(
                            min(info.startPoint.x, info.endPoint.x),
                            min(info.startPoint.y, info.endPoint.y),
                            min(info.startPoint.z, info.endPoint.z)),
                        max: SIMD3(
                            max(info.startPoint.x, info.endPoint.x),
                            max(info.startPoint.y, info.endPoint.y),
                            max(info.startPoint.z, info.endPoint.z))
                    ))
            case .vertex(let info):
                vertexCount += 1
                absorb((min: info.position, max: info.position))
            }
        }

        let bounds: ShapeBounds? =
            minPt.x.isFinite
            ? ShapeBounds(
                minX: minPt.x, minY: minPt.y, minZ: minPt.z,
                maxX: maxPt.x, maxY: maxPt.y, maxZ: maxPt.z
            ) : nil

        return SelectionMeasurements(
            faceCount: faceCount,
            edgeCount: edgeCount,
            vertexCount: vertexCount,
            totalArea: totalArea,
            totalLength: totalLength,
            bounds: bounds
        )
    }

    /// `internal` rather than `private`, for the same reason as `resolveFacePick` and its
    /// siblings: so a test can drive the whole pick path (mode gate, ownership check,
    /// resolution, selection) with a synthesised `PickResult` instead of only its middle.
    /// `controller.onPick` is the only production caller.
    func handlePick(_ result: _PickResult?) {
        guard let result else {
            // Empty space deselects, which is this service's contract and now applies to the
            // whole shared selection, including anything held for an object displayed
            // directly into the interactive context.
            clearSelection()
            return
        }

        // A pick on a body the interactive context displays itself belongs to that context,
        // which resolves it through its own `handlePick` into the same selection this service
        // now reads. Returning here rather than falling through to `clearSelection()` is what
        // stops this service from wiping a selection it never owned; before
        // OCCTSwiftInteraction#3 the two selections were independent and the question could
        // not arise.
        guard !interactiveContext.displaysBody(withID: result.bodyID) else { return }

        guard let entity = resolveEntityPick(result) else {
            clearSelection()
            return
        }

        // A real viewport pick always replaces, matching OCCTSwiftAIS's own point-pick
        // behavior. `select(_:scheme:)` is how a caller builds a multi-selection
        // programmatically (there's no modifier-key state in a GPU pick result to infer a
        // scheme from).
        select(entity, scheme: .replace)
    }

    /// Dispatches a GPU pick to the resolver for its kind, gated by `selectionModes`.
    private func resolveEntityPick(_ result: _PickResult) -> PickedEntity? {
        switch result.kind {
        case .face:
            return resolveFacePick(bodyID: result.bodyID, triangleIndex: result.triangleIndex).map(
                PickedEntity.face)
        case .edge:
            return resolveEdgePick(bodyID: result.bodyID, segmentIndex: result.triangleIndex).map(
                PickedEntity.edge)
        case .vertex:
            return resolveVertexPick(bodyID: result.bodyID, pointIndex: result.triangleIndex).map(
                PickedEntity.vertex)
        }
    }

    /// Resolves a triangle-level GPU pick to durable face identity via the picked body's
    /// `FaceIdentityTable`. `internal` rather than `private` so it can be exercised
    /// directly in tests without round-tripping through the viewport's async pick
    /// callback; `handlePick` is the only production caller.
    ///
    /// Identity resolution itself is `OCCTSwiftTools.SubShapePickResolver`'s, shared with
    /// `OCCTSwiftAIS` since OCCTSwiftInteraction#2. What stays here is what the resolver
    /// deliberately does not own: the mode gate, the clip-plane pre-filter (clip planes are this
    /// service's state, not the bridge layer's), and the geometry enrichment below, which is
    /// presentation.
    func resolveFacePick(bodyID: String, triangleIndex: Int) -> PickedFaceInfo? {
        guard selectionModes.contains(.face) else { return nil }
        if let centroid = triangleWorldCentroid(bodyID: bodyID, triangleIndex: triangleIndex),
            isPointClipped(centroid)
        {
            return nil
        }
        guard let meta = metadata[bodyID],
            let ref = SubShapePickResolver.resolveFace(
                triangleIndex: triangleIndex,
                faceIndices: meta.faceIndices,
                identity: faceIdentity[bodyID],
                shape: bodyShapes[bodyID])
        else {
            return nil
        }
        return enrichFace(ref: ref, bodyID: bodyID, triangleIndex: triangleIndex)
    }

    /// The presentation half of a face pick: everything `PickedFaceInfo` carries beyond the
    /// identity in `ref`.
    ///
    /// Split out of `resolveFacePick` so a sub-shape that reached the selection some other way
    /// (through `interactiveContext` directly, or by area selection) is enriched by the same
    /// code rather than a second copy of it. `triangleIndex` is `nil` for those, which only
    /// affects a `.perTriangle` scalar field: there is no triangle to sample.
    private func enrichFace(ref: OCCTSwiftTools.SubShapeRef, bodyID: String, triangleIndex: Int?)
        -> PickedFaceInfo?
    {
        guard let face = Face(ref.shape) else { return nil }

        let isHoriz = face.isHorizontal()
        let isVert = face.isVertical()
        // A face with no bounding box cannot have produced the rendered triangle this pick
        // came from, so the resolution went wrong somewhere: report no pick rather than
        // mint a `PickedFaceInfo` whose `bounds` and `description` are invented.
        guard let faceBounds = face.bounds else { return nil }
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
            ref: ref,
            bodyID: bodyID,
            isHorizontal: isHoriz,
            isVertical: isVert,
            bounds: bounds,
            zLevel: zLevel,
            area: faceArea,
            description: desc,
            scalarValue: scalarValue(
                forBody: bodyID, faceIndex: ref.ordinal, triangleIndex: triangleIndex)
        )
    }

    /// Resolves a line-segment-level GPU pick to durable edge identity via the picked
    /// body's `EdgeIdentityTable`.
    ///
    /// Reads `edgeIndices` off the `_ViewportBody` itself (unlike faces, `CADBodyMetadata`
    /// carries edge data as per-polyline groups, not a flat per-segment array); a body with
    /// no `edgeIndices` populated (not edge-pickable, per the documentation on
    /// `ViewportBody` itself) degrades to `nil` here rather than mis-picking. `internal` for
    /// the same testability reason as `resolveFacePick`, and split the same way against
    /// `SubShapePickResolver`.
    func resolveEdgePick(bodyID: String, segmentIndex: Int) -> PickedEdgeInfo? {
        guard selectionModes.contains(.edge) else { return nil }
        if let midpoint = edgeSegmentWorldMidpoint(bodyID: bodyID, segmentIndex: segmentIndex),
            isPointClipped(midpoint)
        {
            return nil
        }
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
            let ref = SubShapePickResolver.resolveEdge(
                segmentIndex: segmentIndex,
                edgeIndices: body.edgeIndices,
                identity: edgeIdentity[bodyID],
                shape: bodyShapes[bodyID])
        else {
            return nil
        }
        return enrichEdge(ref: ref, bodyID: bodyID)
    }

    /// The presentation half of an edge pick.
    ///
    /// See `enrichFace(ref:bodyID:triangleIndex:)`.
    private func enrichEdge(ref: OCCTSwiftTools.SubShapeRef, bodyID: String) -> PickedEdgeInfo? {
        guard let edge = Edge(ref.shape) else { return nil }

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
            ref: ref,
            bodyID: bodyID,
            curveType: edge.curveType,
            length: edge.length,
            startPoint: endpoints.start,
            endPoint: endpoints.end,
            description: desc
        )
    }

    /// Resolves a point-sprite-level GPU pick to durable vertex identity via the picked
    /// body's `VertexIdentityTable`.
    ///
    /// A body with no `vertices` populated (not vertex-pickable) degrades to `nil` here
    /// rather than mis-picking. `internal` for the same testability reason as
    /// `resolveFacePick`.
    ///
    /// The empty-`vertexIndices` identity mapping this copy used to implement alone is now
    /// `SubShapePickResolver.resolveVertex`'s, so `OCCTSwiftAIS` gets it too: that divergence
    /// (documented here as "deliberately more complete than OCCTSwiftAIS's own") is what
    /// OCCTSwiftInteraction#2 consolidated.
    func resolveVertexPick(bodyID: String, pointIndex: Int) -> PickedVertexInfo? {
        guard selectionModes.contains(.vertex) else { return nil }
        if let position = vertexWorldPosition(bodyID: bodyID, pointIndex: pointIndex),
            isPointClipped(position)
        {
            return nil
        }
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
            let ref = SubShapePickResolver.resolveVertex(
                pointIndex: pointIndex,
                pointCount: body.vertices.count,
                vertexIndices: body.vertexIndices,
                identity: vertexIdentity[bodyID],
                shape: bodyShapes[bodyID])
        else {
            return nil
        }
        // In range whenever the resolver returned a ref: it bounds `pointIndex` by the
        // `pointCount` passed above, which is this array's own count.
        return enrichVertex(ref: ref, bodyID: bodyID, renderPosition: body.vertices[pointIndex])
    }

    /// The presentation half of a vertex pick.
    ///
    /// See `enrichFace(ref:bodyID:triangleIndex:)`.
    ///
    /// `renderPosition` is the rendered point the pick landed on, used only when the resolved
    /// `Shape` yields no vertex of its own; `nil` for a vertex that did not come from a pick,
    /// which then simply has no fallback.
    private func enrichVertex(
        ref: OCCTSwiftTools.SubShapeRef, bodyID: String, renderPosition: SIMD3<Float>?
    )
        -> PickedVertexInfo?
    {
        let fallback = renderPosition.map {
            SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z))
        }
        guard let position = ref.shape.vertices().first ?? fallback else { return nil }
        let desc = String(
            format: "Vertex at (%.1f, %.1f, %.1f)mm", position.x, position.y, position.z)

        return PickedVertexInfo(
            ref: ref,
            bodyID: bodyID,
            position: position,
            description: desc
        )
    }

    /// Rebuilds the highlight bodies from the whole `selection` (not just the latest
    /// pick), grouped by kind: up to three bodies, a translucent yellow triangle patch
    /// aggregating every selected face's own triangles, a bright cyan polyline aggregating
    /// every selected edge's own segments, and a bright magenta point sprite body for every
    /// selected vertex's own position.
    ///
    /// Bodies loaded via `load(_:id:transform:)` are always in world-space already (the
    /// transform is baked into the shape before tessellation, not applied as a separate
    /// `_ViewportBody.transform`), so combining geometry gathered from different source
    /// bodies into one aggregate highlight body is safe.
    private func rebuildSelectionHighlights() {
        let stride = 6  // interleaved [px,py,pz,nx,ny,nz]
        var faceVerts: [Float] = []
        var faceIndices: [UInt32] = []
        var faceVertCount: UInt32 = 0
        var edgeSegments: [[SIMD3<Float>]] = []
        var vertexPoints: [SIMD3<Float>] = []

        for entity in selection {
            switch entity {
            case .face(let info):
                guard let body = modelBodies.first(where: { $0.id == info.bodyID }),
                    let meta = metadata[info.bodyID]
                else { continue }
                let faceIndex = Int32(info.faceIndex)
                let triCount = body.indices.count / 3
                for tri in 0..<triCount {
                    guard tri < meta.faceIndices.count, meta.faceIndices[tri] == faceIndex else {
                        continue
                    }
                    let i0 = Int(body.indices[tri * 3])
                    let i1 = Int(body.indices[tri * 3 + 1])
                    let i2 = Int(body.indices[tri * 3 + 2])
                    for idx in [i0, i1, i2] {
                        let base = idx * stride
                        guard base + stride <= body.vertexData.count else { continue }
                        faceVerts.append(contentsOf: body.vertexData[base..<(base + stride)])
                        faceIndices.append(faceVertCount)
                        faceVertCount += 1
                    }
                }

            case .edge(let info):
                guard let body = modelBodies.first(where: { $0.id == info.bodyID }) else {
                    continue
                }
                let edgeIndex = Int32(info.edgeIndex)
                var segmentCursor = 0
                for polyline in body.edges {
                    let segmentCount = max(polyline.count - 1, 0)
                    guard segmentCount > 0 else { continue }
                    for s in 0..<segmentCount {
                        defer { segmentCursor += 1 }
                        guard segmentCursor < body.edgeIndices.count,
                            body.edgeIndices[segmentCursor] == edgeIndex
                        else { continue }
                        edgeSegments.append([polyline[s], polyline[s + 1]])
                    }
                }

            case .vertex(let info):
                vertexPoints.append(
                    SIMD3<Float>(
                        Float(info.position.x), Float(info.position.y), Float(info.position.z)
                    ))
            }
        }

        var bodies: [_ViewportBody] = []
        if !faceIndices.isEmpty {
            bodies.append(
                _ViewportBody(
                    id: "selection_highlight_face",
                    vertexData: faceVerts,
                    indices: faceIndices,
                    edges: [],
                    color: SIMD4<Float>(1.0, 0.9, 0.0, 0.5)
                ))
        }
        if !edgeSegments.isEmpty {
            bodies.append(
                _ViewportBody(
                    id: "selection_highlight_edge",
                    vertexData: [],
                    indices: [],
                    edges: edgeSegments,
                    color: SIMD4<Float>(0.1, 0.9, 1.0, 1.0)
                ))
        }
        if !vertexPoints.isEmpty {
            bodies.append(
                _ViewportBody(
                    id: "selection_highlight_vertex",
                    vertexData: [],
                    indices: [],
                    edges: [],
                    vertices: vertexPoints,
                    vertexIndices: (0..<vertexPoints.count).map(Int32.init),
                    color: SIMD4<Float>(1.0, 0.15, 0.9, 1.0),
                    pointRadius: 6,
                    primitiveKind: .point
                ))
        }

        selectionBodies = bodies
        rebuildBodies()
    }
}
