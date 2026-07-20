import Testing
import simd
import OCCTSwift
import OCCTSwiftViewport
@testable import OCCTSwiftTools

@Suite("CADFileLoader.shapeToBodyMetadataAndIdentities / EdgeIdentityTable")
struct EdgeIdentityTableTests {

    @Test func t_boxTableMapsEveryOrdinalToAnEdge() {
        guard let box = Shape.box(width: 10, height: 5, depth: 3) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let (body, meta, _, edgeTable, _) = CADFileLoader.shapeToBodyMetadataAndIdentities(
            box, id: "box", color: SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
        )
        guard let body, let meta, let edgeTable else {
            Issue.record("shapeToBodyMetadataAndIdentities returned nil for a closed box")
            return
        }
        #expect(edgeTable.shapes.count == box.edgeCount)
        #expect(edgeTable.uids == nil, "no TopologyGraph was supplied")
        #expect(meta.faceIndices == body.faceIndices)

        for ordinal in Set(body.edgeIndices.map(Int.init)) {
            guard let edgeShape = edgeTable.shape(forOrdinal: ordinal) else {
                Issue.record("no shape recorded for ordinal \(ordinal)")
                continue
            }
            #expect(edgeShape.shapeType == .edge)
        }
    }

    @Test func t_outOfRangeOrdinalReturnsNil() {
        guard let box = Shape.box(width: 2, height: 2, depth: 2) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let (_, _, _, edgeTable, _) = CADFileLoader.shapeToBodyMetadataAndIdentities(
            box, id: "box", color: SIMD4<Float>(1, 1, 1, 1)
        )
        guard let edgeTable else {
            Issue.record("expected an edge table for a closed box")
            return
        }
        #expect(edgeTable.shape(forOrdinal: -1) == nil)
        #expect(edgeTable.shape(forOrdinal: edgeTable.shapes.count) == nil)
        #expect(edgeTable.uid(forOrdinal: 0) == nil, "no graph supplied, so no UIDs at all")
    }

    /// The new three-table overload must not change what the two existing entry points return.
    @Test func t_existingEntryPointsUnchangedByNewOverload() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let color = SIMD4<Float>(0.3, 0.6, 0.9, 1.0)
        let (body, meta) = CADFileLoader.shapeToBodyAndMetadata(box, id: "box", color: color)
        let (bodyViaIdentity, metaViaIdentity, faceTableViaIdentity) =
            CADFileLoader.shapeToBodyMetadataAndIdentity(box, id: "box", color: color)
        let (bodyViaIdentities, metaViaIdentities, faceTableViaIdentities, edgeTable, vertexTable) =
            CADFileLoader.shapeToBodyMetadataAndIdentities(box, id: "box", color: color)
        guard let body, let meta, let bodyViaIdentity, let metaViaIdentity,
              let bodyViaIdentities, let metaViaIdentities, let faceTableViaIdentity,
              let faceTableViaIdentities, let edgeTable, let vertexTable
        else {
            Issue.record("all three entry points should succeed on a closed box")
            return
        }
        #expect(body.vertexData == bodyViaIdentities.vertexData)
        #expect(body.indices == bodyViaIdentities.indices)
        #expect(body.faceIndices == bodyViaIdentities.faceIndices)
        #expect(body.edgeIndices == bodyViaIdentities.edgeIndices)
        #expect(meta.faceIndices == metaViaIdentities.faceIndices)
        #expect(bodyViaIdentity.faceIndices == bodyViaIdentities.faceIndices)
        #expect(metaViaIdentity.faceIndices == metaViaIdentities.faceIndices)
        #expect(faceTableViaIdentity.shapes.count == faceTableViaIdentities.shapes.count)
        #expect(edgeTable.shapes.count == box.edgeCount)
        #expect(vertexTable.shapes.count == box.vertexCount)
    }

    /// Regression for issue #43: a face shared between two shells (as in
    /// `FaceIdentityTableTests.t_sharedFaceBetweenShellsResolvesToOneGraphUID`) also shares that
    /// face's boundary edges between the two shells. Unlike faces, `Shape.edges()` is already
    /// built from a deduplicating `TopTools_IndexedMapOfShape` (confirmed against the
    /// OCCTBridge source: `OCCTShapeGetTotalEdgeCount` / `OCCTShapeGetEdgeAtIndex` and the bulk
    /// edge-polyline extractor behind `ViewportBody.edgeIndices` all build that same map), so the
    /// shared edges collapse to one ordinal each rather than appearing once per shell the way the
    /// shared face's raw, non-deduplicated ordinal does. This locks that behaviour in: the
    /// compound's edge table stays at the original box's 12 edges, not 12 + 4 double-counted, and
    /// every one of the shared face's boundary edges resolves through the graph to a single
    /// consistent `GraphUID`.
    @Test func t_sharedFaceEdgesBetweenShellsCollapseToOneOrdinalEach() {
        guard let box = Shape.box(width: 10, height: 10, depth: 10) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let boxFaces = box.subShapes(ofType: .face)
        #expect(boxFaces.count == 6)
        let sharedFace = boxFaces[0]

        guard let shellA = Shape.shellFromFaces([sharedFace, boxFaces[1], boxFaces[2]]),
              let shellB = Shape.shellFromFaces([sharedFace, boxFaces[3], boxFaces[4], boxFaces[5]]),
              let compound = Shape.compound([shellA, shellB])
        else {
            Issue.record("failed to build the shared-face compound fixture")
            return
        }

        // Sanity check this is the same fixture shape as the face regression test: the raw face
        // traversal double-counts the shared face, but the shape's own dedup edge/vertex maps
        // must still agree with the original box.
        #expect(compound.faces().count == 7)
        #expect(compound.edgeCount == box.edgeCount)
        #expect(compound.vertexCount == box.vertexCount)

        guard let graph = TopologyGraph(shape: compound) else {
            Issue.record("TopologyGraph(shape:) returned nil")
            return
        }

        let (body, meta, _, edgeTable, _) = CADFileLoader.shapeToBodyMetadataAndIdentities(
            compound, id: "shared", color: SIMD4<Float>(1, 1, 1, 1), graph: graph
        )
        guard let body, let meta, let edgeTable else {
            Issue.record("shapeToBodyMetadataAndIdentities returned nil for the shared-face compound")
            return
        }
        #expect(body.faceIndices.count == meta.faceIndices.count)
        #expect(edgeTable.shapes.count == box.edgeCount, "no double-counting despite the shared face")
        guard let uids = edgeTable.uids else {
            Issue.record("expected UIDs when a graph was supplied")
            return
        }
        #expect(uids.count == edgeTable.shapes.count)

        // Every ordinal must resolve back through the supplied graph.
        for ordinal in 0..<edgeTable.shapes.count {
            guard let edgeShape = edgeTable.shape(forOrdinal: ordinal) else {
                Issue.record("no shape recorded for ordinal \(ordinal)")
                continue
            }
            guard graph.findNode(for: edgeShape) != nil else {
                Issue.record("ordinal \(ordinal)'s shape did not resolve in the graph")
                continue
            }
        }

        // Every boundary edge of the shared face round-trips through the table to the same
        // GraphUID a direct graph lookup on that edge gives, i.e. the table's dedup ordinal for
        // a shared edge names the correct, single edge rather than aliasing a shell-local copy.
        for sharedEdge in sharedFace.subShapes(ofType: .edge) {
            guard let (kind, index) = graph.findNode(for: sharedEdge) else {
                Issue.record("shared face's boundary edge did not resolve in the graph")
                continue
            }
            let expectedUID = graph.uid(ofNodeKind: Int(kind.rawValue), index: index)
            guard let ordinal = (0..<edgeTable.shapes.count).first(where: {
                graph.findNode(for: edgeTable.shapes[$0]).map { $0.kind == kind && $0.index == index } ?? false
            }) else {
                Issue.record("no table ordinal resolves to the shared edge's graph node")
                continue
            }
            #expect(edgeTable.uid(forOrdinal: ordinal) == expectedUID)
        }
    }
}
