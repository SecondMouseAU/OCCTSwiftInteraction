import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftTools

/// Covers the consolidated pick resolver (OCCTSwiftInteraction#2), which replaced the copies in
/// the `OCCTSwiftAIS` and `OCCTSwiftCADKit` targets.
@Suite("SubShapePickResolver")
struct SubShapePickResolverTests {

    private func box() throws -> Shape {
        try #require(Shape.box(width: 10, height: 5, depth: 3))
    }

    private typealias Loaded = (
        body: ViewportBody, meta: CADBodyMetadata, faces: FaceIdentityTable,
        edges: EdgeIdentityTable, vertices: VertexIdentityTable
    )

    /// A real tessellation of `shape`, with a graph so the tables carry uids.
    private func load(_ shape: Shape) throws -> Loaded {
        let graph = try #require(BRepGraph(shape: shape))
        let (body, meta, faces, edges, vertices) =
            CADFileLoader.shapeToBodyMetadataAndIdentities(
                shape, id: "box", color: SIMD4<Float>(1, 1, 1, 1), graph: graph)
        return (
            try #require(body), try #require(meta), try #require(faces), try #require(edges),
            try #require(vertices)
        )
    }

    // MARK: - Faces

    @Test func t_face_resolvesThroughTheIndirectionAndCarriesTheTablesUID() throws {
        let shape = try box()
        let loaded = try load(shape)
        try #require(!loaded.meta.faceIndices.isEmpty)

        let expectedOrdinal = Int(loaded.meta.faceIndices[0])
        let ref = try #require(
            SubShapePickResolver.resolveFace(
                triangleIndex: 0, faceIndices: loaded.meta.faceIndices,
                identity: loaded.faces, shape: shape))

        #expect(ref.ordinal == expectedOrdinal, "the triangle index is not the face ordinal")
        #expect(ref.uid == loaded.faces.uid(forOrdinal: expectedOrdinal))
        let expectedShape = try #require(loaded.faces.shape(forOrdinal: expectedOrdinal))
        #expect(ref.shape.isSame(as: expectedShape))
        #expect(ref.shape.shapeType == .face)
    }

    @Test func t_face_outOfRangeTriangleResolvesNothing() throws {
        let shape = try box()
        let loaded = try load(shape)
        let indices = loaded.meta.faceIndices

        #expect(
            SubShapePickResolver.resolveFace(
                triangleIndex: -1, faceIndices: indices, identity: loaded.faces, shape: shape)
                == nil)
        #expect(
            SubShapePickResolver.resolveFace(
                triangleIndex: indices.count, faceIndices: indices, identity: loaded.faces,
                shape: shape) == nil)
    }

    /// Empty `faceIndices` means "not face-pickable" per `ViewportBody`.
    ///
    /// That is the opposite of what empty `vertexIndices` means, so the resolver must not
    /// identity-map it.
    @Test func t_face_emptyFaceIndicesIsNotPickable() throws {
        let shape = try box()
        #expect(
            SubShapePickResolver.resolveFace(
                triangleIndex: 0, faceIndices: [], identity: nil, shape: shape) == nil)
    }

    @Test func t_face_negativeOrdinalResolvesNothing() throws {
        let shape = try box()
        #expect(
            SubShapePickResolver.resolveFace(
                triangleIndex: 0, faceIndices: [-1], identity: nil, shape: shape) == nil)
    }

    /// The re-derivation fallback, for a body that has no identity table.
    ///
    /// Equivalent to the `faces()[i]` spelling the CADKit copy used: both route through the same
    /// `TopTools_IndexedMapOfShape`.
    @Test func t_face_fallsBackToTheSourceShapeWhenThereIsNoTable() throws {
        let shape = try box()
        let ref = try #require(
            SubShapePickResolver.resolveFace(
                triangleIndex: 0, faceIndices: [2], identity: nil, shape: shape))

        #expect(ref.ordinal == 2)
        #expect(ref.uid == nil, "no table means no durable uid")
        let expected = try #require(shape.subShape(type: .face, index: 2))
        #expect(ref.shape.isSame(as: expected))
    }

    @Test func t_face_withNeitherTableNorShapeResolvesNothing() {
        #expect(
            SubShapePickResolver.resolveFace(
                triangleIndex: 0, faceIndices: [0], identity: nil, shape: nil) == nil)
    }

    /// Rule 3: the table's captured `Shape` beats re-deriving from the source shape.
    ///
    /// Proven by handing the resolver a table that deliberately disagrees with the shape's own
    /// enumeration, and checking which one comes back.
    @Test func t_face_prefersTheIdentityTableOverReDerivation() throws {
        let shape = try box()
        let reDerived = try #require(shape.subShape(type: .face, index: 0))
        let tabled = try #require(shape.subShape(type: .face, index: 4))
        try #require(!reDerived.isSame(as: tabled))

        let table = FaceIdentityTable(shapes: [tabled])
        let ref = try #require(
            SubShapePickResolver.resolveFace(
                triangleIndex: 0, faceIndices: [0], identity: table, shape: shape))

        #expect(ref.shape.isSame(as: tabled))
        #expect(!ref.shape.isSame(as: reDerived))
    }

    // MARK: - Edges

    @Test func t_edge_resolvesThroughTheIndirectionAndCarriesTheTablesUID() throws {
        let shape = try box()
        let loaded = try load(shape)
        try #require(!loaded.body.edgeIndices.isEmpty)

        let expectedOrdinal = Int(loaded.body.edgeIndices[0])
        let ref = try #require(
            SubShapePickResolver.resolveEdge(
                segmentIndex: 0, edgeIndices: loaded.body.edgeIndices, identity: loaded.edges,
                shape: shape))

        #expect(ref.ordinal == expectedOrdinal)
        #expect(ref.uid == loaded.edges.uid(forOrdinal: expectedOrdinal))
        #expect(ref.shape.shapeType == .edge)
    }

    @Test func t_edge_emptyOrOutOfRangeResolvesNothing() throws {
        let shape = try box()
        let loaded = try load(shape)

        #expect(
            SubShapePickResolver.resolveEdge(
                segmentIndex: 0, edgeIndices: [], identity: loaded.edges, shape: shape) == nil,
            "an empty edgeIndices means the body is not edge-pickable")
        #expect(
            SubShapePickResolver.resolveEdge(
                segmentIndex: loaded.body.edgeIndices.count,
                edgeIndices: loaded.body.edgeIndices, identity: loaded.edges, shape: shape) == nil)
        #expect(
            SubShapePickResolver.resolveEdge(
                segmentIndex: -1, edgeIndices: loaded.body.edgeIndices, identity: loaded.edges,
                shape: shape) == nil)
    }

    // MARK: - Vertices

    @Test func t_vertex_resolvesThroughVertexIndicesWhenTheyArePopulated() throws {
        let shape = try box()
        let loaded = try load(shape)
        try #require(loaded.body.vertexIndices.count == loaded.body.vertices.count)

        let expectedOrdinal = Int(loaded.body.vertexIndices[3])
        let ref = try #require(
            SubShapePickResolver.resolveVertex(
                pointIndex: 3, pointCount: loaded.body.vertices.count,
                vertexIndices: loaded.body.vertexIndices, identity: loaded.vertices, shape: shape))

        #expect(ref.ordinal == expectedOrdinal)
        #expect(ref.uid == loaded.vertices.uid(forOrdinal: expectedOrdinal))
        #expect(ref.shape.shapeType == .vertex)
    }

    /// The bug this consolidation fixes.
    ///
    /// `ViewportBody` documents an empty `vertexIndices` as identity mapping, where the point
    /// index *is* the ordinal. The `OCCTSwiftAIS` copy bounds-checked against
    /// `vertexIndices.count` and so never resolved a vertex pick on such a body; the
    /// `OCCTSwiftCADKit` copy handled it. This is the merged behaviour.
    @Test func t_vertex_emptyVertexIndicesMeansIdentityMapping() throws {
        let shape = try box()
        let loaded = try load(shape)
        let pointCount = loaded.body.vertices.count
        try #require(pointCount == 8, "a box has 8 corners")

        for pointIndex in 0..<pointCount {
            let ref = try #require(
                SubShapePickResolver.resolveVertex(
                    pointIndex: pointIndex, pointCount: pointCount, vertexIndices: [],
                    identity: loaded.vertices, shape: shape),
                "point \(pointIndex) should resolve with vertexIndices empty")
            #expect(ref.ordinal == pointIndex, "the point index is the ordinal itself")
            #expect(ref.shape.shapeType == .vertex)
            #expect(ref.uid == loaded.vertices.uid(forOrdinal: pointIndex))
        }
    }

    /// The corollary: a vertex pick is bounded by how many points the body renders, not by the
    /// length of `vertexIndices`.
    @Test func t_vertex_isBoundedByPointCountNotByVertexIndicesCount() throws {
        let shape = try box()
        let loaded = try load(shape)
        let pointCount = loaded.body.vertices.count

        #expect(
            SubShapePickResolver.resolveVertex(
                pointIndex: pointCount, pointCount: pointCount, vertexIndices: [],
                identity: loaded.vertices, shape: shape) == nil)
        #expect(
            SubShapePickResolver.resolveVertex(
                pointIndex: -1, pointCount: pointCount, vertexIndices: [],
                identity: loaded.vertices, shape: shape) == nil)
    }

    @Test func t_vertex_zeroPointCountIsNotPickable() throws {
        let shape = try box()
        let loaded = try load(shape)
        #expect(
            SubShapePickResolver.resolveVertex(
                pointIndex: 0, pointCount: 0, vertexIndices: loaded.body.vertexIndices,
                identity: loaded.vertices, shape: shape) == nil,
            "a body rendering no pick points is not vertex-pickable")
    }
}
