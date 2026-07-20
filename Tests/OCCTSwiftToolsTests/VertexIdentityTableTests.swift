import Testing
import simd
import OCCTSwift
import OCCTSwiftViewport
@testable import OCCTSwiftTools

@Suite("CADFileLoader.shapeToBodyMetadataAndIdentities / VertexIdentityTable")
struct VertexIdentityTableTests {

    @Test func t_boxTableMapsEveryOrdinalToAVertex() {
        guard let box = Shape.box(width: 10, height: 5, depth: 3) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let (body, _, _, _, vertexTable) = CADFileLoader.shapeToBodyMetadataAndIdentities(
            box, id: "box", color: SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
        )
        guard let body, let vertexTable else {
            Issue.record("shapeToBodyMetadataAndIdentities returned nil for a closed box")
            return
        }
        #expect(vertexTable.shapes.count == box.vertexCount)
        #expect(vertexTable.uids == nil, "no TopologyGraph was supplied")

        for ordinal in Set(body.vertexIndices.map(Int.init)) {
            guard let vertexShape = vertexTable.shape(forOrdinal: ordinal) else {
                Issue.record("no shape recorded for ordinal \(ordinal)")
                continue
            }
            #expect(vertexShape.shapeType == .vertex)
        }
    }

    @Test func t_outOfRangeOrdinalReturnsNil() {
        guard let box = Shape.box(width: 2, height: 2, depth: 2) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let (_, _, _, _, vertexTable) = CADFileLoader.shapeToBodyMetadataAndIdentities(
            box, id: "box", color: SIMD4<Float>(1, 1, 1, 1)
        )
        guard let vertexTable else {
            Issue.record("expected a vertex table for a closed box")
            return
        }
        #expect(vertexTable.shape(forOrdinal: -1) == nil)
        #expect(vertexTable.shape(forOrdinal: vertexTable.shapes.count) == nil)
        #expect(vertexTable.uid(forOrdinal: 0) == nil, "no graph supplied, so no UIDs at all")
    }

    /// Regression for issue #43, the vertex counterpart of
    /// `EdgeIdentityTableTests.t_sharedFaceEdgesBetweenShellsCollapseToOneOrdinalEach`: a face
    /// shared between two shells also shares that face's corner vertices. `Shape.vertices()` /
    /// `Shape.subShapes(ofType: .vertex)` are both built from the same deduplicating
    /// `TopTools_IndexedMapOfShape` (confirmed against the OCCTBridge source:
    /// `OCCTShapeGetVertexCount` / `OCCTShapeGetVertexAt` / `OCCTShapeGetSubShapeByTypeIndex`),
    /// so the shared corners collapse to one ordinal each instead of appearing once per shell.
    @Test func t_sharedFaceVerticesBetweenShellsCollapseToOneOrdinalEach() {
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

        #expect(compound.faces().count == 7)
        #expect(compound.vertexCount == box.vertexCount)

        guard let graph = TopologyGraph(shape: compound) else {
            Issue.record("TopologyGraph(shape:) returned nil")
            return
        }

        let (body, meta, _, _, vertexTable) = CADFileLoader.shapeToBodyMetadataAndIdentities(
            compound, id: "shared", color: SIMD4<Float>(1, 1, 1, 1), graph: graph
        )
        guard let body, let meta, let vertexTable else {
            Issue.record("shapeToBodyMetadataAndIdentities returned nil for the shared-face compound")
            return
        }
        #expect(body.faceIndices.count == meta.faceIndices.count)
        #expect(vertexTable.shapes.count == box.vertexCount, "no double-counting despite the shared face")
        guard let uids = vertexTable.uids else {
            Issue.record("expected UIDs when a graph was supplied")
            return
        }
        #expect(uids.count == vertexTable.shapes.count)

        for ordinal in 0..<vertexTable.shapes.count {
            guard let vertexShape = vertexTable.shape(forOrdinal: ordinal) else {
                Issue.record("no shape recorded for ordinal \(ordinal)")
                continue
            }
            guard graph.findNode(for: vertexShape) != nil else {
                Issue.record("ordinal \(ordinal)'s shape did not resolve in the graph")
                continue
            }
        }

        // Every corner vertex of the shared face round-trips through the table to the same
        // GraphUID a direct graph lookup on that vertex gives.
        for sharedVertex in sharedFace.subShapes(ofType: .vertex) {
            guard let (kind, index) = graph.findNode(for: sharedVertex) else {
                Issue.record("shared face's corner vertex did not resolve in the graph")
                continue
            }
            let expectedUID = graph.uid(ofNodeKind: Int(kind.rawValue), index: index)
            guard let ordinal = (0..<vertexTable.shapes.count).first(where: {
                graph.findNode(for: vertexTable.shapes[$0]).map { $0.kind == kind && $0.index == index } ?? false
            }) else {
                Issue.record("no table ordinal resolves to the shared vertex's graph node")
                continue
            }
            #expect(vertexTable.uid(forOrdinal: ordinal) == expectedUID)
        }
    }
}
