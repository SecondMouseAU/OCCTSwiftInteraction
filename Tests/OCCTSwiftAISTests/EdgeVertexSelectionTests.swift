import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

@MainActor
@Suite("EdgeVertexSelection")
struct EdgeVertexSelectionTests {

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> OCCTSwift.Shape {
        try #require(OCCTSwift.Shape.box(width: 10, height: 5, depth: 3))
    }

    /// Synthesise a `PickResult` with a specific kind + primitive index for a
    /// given body.
    ///
    /// Mirrors the renderer's bit-packing:
    /// `objectIndex | (primitiveID << 16) | (kind << 30)`.
    private func makePick(
        bodyID: String,
        bodyIndex: Int = 0,
        primitiveIndex: Int,
        kind: PrimitiveKind
    ) throws -> PickResult {
        let raw =
            UInt32(bodyIndex & 0xFFFF)
            | (UInt32(primitiveIndex & 0x3FFF) << 16)
            | (UInt32(kind.rawValue) << 30)
        return try #require(PickResult(rawValue: raw, indexMap: [bodyIndex: bodyID]))
    }

    // MARK: - display() populates pick arrays

    @Test func t_display_populatesEdgeIndices() throws {
        let ctx = makeContext()
        _ = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        #expect(
            !body.edgeIndices.isEmpty, "display() must populate edgeIndices for v0.55.0+ pick pass")
        // Length should equal flattened line-segment count: sum of (poly.points - 1).
        #expect(body.edgeIndices.count == body.edges.reduce(0) { $0 + max($1.count - 1, 0) })
    }

    @Test func t_display_populatesVertices() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        #expect(!body.vertices.isEmpty, "display() must populate vertices for v0.55.0+ pick pass")
        #expect(body.vertexIndices.count == body.vertices.count)
        // A box has 8 corners: Shape.vertices() should report exactly 8.
        #expect(body.vertices.count == 8, "expected 8 corners, got \(body.vertices.count)")
        _ = obj
    }

    @Test func t_display_vertexIndicesArePositional() throws {
        let ctx = makeContext()
        _ = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        // Identity mapping so PickResult.triangleIndex round-trips to source index.
        for (i, vi) in body.vertexIndices.enumerated() {
            #expect(Int(vi) == i)
        }
    }

    // MARK: - handlePick: face/edge/vertex dispatch

    @Test func t_handlePick_kindFace_resolvesToFaceSubShape() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        let pick = try makePick(bodyID: body.id, primitiveIndex: 0, kind: .face)
        ctx.handlePick(pick)
        let expectedFaceIdx = Int(body.faceIndices[0])
        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: expectedFaceIdx))
    }

    @Test func t_handlePick_kindEdge_resolvesToEdgeSubShape() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.edge]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        try #require(!body.edgeIndices.isEmpty)
        let segIdx = 0
        let expectedEdgeIdx = Int(body.edgeIndices[segIdx])
        let pick = try makePick(bodyID: body.id, primitiveIndex: segIdx, kind: .edge)

        ctx.handlePick(pick)

        #expect(ctx.selection.count == 1)
        #expect(containsEdge(ctx.selection.subshapes, obj, ordinal: expectedEdgeIdx))
    }

    @Test func t_handlePick_kindVertex_resolvesToVertexSubShape() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.vertex]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        try #require(!body.vertexIndices.isEmpty)
        let primIdx = 3
        let expectedVIdx = Int(body.vertexIndices[primIdx])
        let pick = try makePick(bodyID: body.id, primitiveIndex: primIdx, kind: .vertex)

        ctx.handlePick(pick)

        #expect(ctx.selection.count == 1)
        #expect(containsVertex(ctx.selection.subshapes, obj, ordinal: expectedVIdx))
    }

    @Test func t_handlePick_kindEdge_modeNotEdge_isIgnored() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        let pick = try makePick(bodyID: body.id, primitiveIndex: 0, kind: .edge)
        ctx.handlePick(pick)
        #expect(ctx.selection.isEmpty)
        _ = obj
    }

    @Test func t_handlePick_kindVertex_modeNotVertex_isIgnored() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        let pick = try makePick(bodyID: body.id, primitiveIndex: 0, kind: .vertex)
        ctx.handlePick(pick)
        #expect(ctx.selection.isEmpty)
        _ = obj
    }

    @Test func t_handlePick_outOfRangeEdgePrimitive_isIgnored() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.edge]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        let pick = try makePick(
            bodyID: body.id, primitiveIndex: body.edgeIndices.count + 100, kind: .edge)
        ctx.handlePick(pick)
        #expect(ctx.selection.isEmpty)
        _ = obj
    }

    // MARK: - Selection.vertices accessor

    @Test func t_selectionVertices_resolvesToWorldPositions() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.vertex]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        let primIdx = 0
        let expectedVIdx = Int(body.vertexIndices[primIdx])
        let pick = try makePick(bodyID: body.id, primitiveIndex: primIdx, kind: .vertex)
        ctx.handlePick(pick)

        let positions = ctx.selection.vertices
        #expect(positions.count == 1)
        if let p = positions.first {
            // Box at origin, width 10, height 5, depth 3 → corners are within
            // the half-extents; magnitude bounded.
            #expect(abs(p.x) <= 5.001)
            #expect(abs(p.y) <= 2.501)
            #expect(abs(p.z) <= 1.501)
            // Sanity: must match shape.vertex(at: expectedVIdx)
            let expected = obj.shape.vertex(at: expectedVIdx)
            if let expected {
                #expect(simd_distance(p, expected) < 1e-5)
            }
        }
    }

    @Test func t_selectionVertices_filtersOnlyVertexCases() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let vertex0 = try #require(obj.shape.subShape(type: .vertex, index: 0))
        let vertex1 = try #require(obj.shape.subShape(type: .vertex, index: 1))
        let s = Selection([
            .body(obj),
            .face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0)),
            .vertex(obj, ref: SubShapeRef(shape: vertex0, ordinal: 0)),
            .vertex(obj, ref: SubShapeRef(shape: vertex1, ordinal: 1)),
        ])
        #expect(s.vertices.count == 2)
    }

    // MARK: - Multi-mode selection

    @Test func t_selectionMode_supportsMultipleKindsTogether() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face, .edge, .vertex]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)

        // Pick a face → .face entry.
        ctx.handlePick(try makePick(bodyID: body.id, primitiveIndex: 0, kind: .face))
        #expect(
            ctx.selection.subshapes.allSatisfy {
                if case .face = $0 { return true } else { return false }
            })

        // Pick an edge → replaces with .edge entry.
        ctx.handlePick(try makePick(bodyID: body.id, primitiveIndex: 0, kind: .edge))
        #expect(
            ctx.selection.subshapes.allSatisfy {
                if case .edge = $0 { return true } else { return false }
            })

        // Pick a vertex → replaces with .vertex entry.
        ctx.handlePick(try makePick(bodyID: body.id, primitiveIndex: 0, kind: .vertex))
        #expect(
            ctx.selection.subshapes.allSatisfy {
                if case .vertex = $0 { return true } else { return false }
            })
        _ = obj
    }
}
