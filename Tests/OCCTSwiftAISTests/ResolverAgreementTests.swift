// ResolverAgreementTests.swift
// OCCTSwiftAISTests
//
// Verifies by execution what OCCTSwiftInteraction#2 established by construction: there is exactly
// one implementation of ordinal-to-topology resolution, and `InteractiveContext`'s wrappers add
// selection-mode gating and the whole-body fallback on top of it without changing what it resolves.
//
// #12's duplication audit was a static read of the call graph. That confirms AIS *calls*
// `SubShapePickResolver`, which is not the same as confirming the two agree: a wrapper can call a
// resolver and still hand back something different, by passing different inputs. These drive a real
// pick through `handlePick` and independently resolve the same pick from the same shape, then
// compare.

import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing

@testable import OCCTSwiftAIS

@MainActor
@Suite("Resolver agreement: InteractiveContext against SubShapePickResolver")
struct ResolverAgreementTests {

    /// Rebuilds the resolver inputs the way `InteractiveContext.display(_:style:)` does, so the
    /// comparison is against an independent resolution rather than against the context's own
    /// cached tables.
    private func independentIdentity(for shape: OCCTSwift.Shape, bodyID: String) -> (
        body: ViewportBody?, metadata: CADBodyMetadata?,
        face: FaceIdentityTable?, edge: EdgeIdentityTable?, vertex: VertexIdentityTable?
    ) {
        let graph = BRepGraph(shape: shape)
        graph?.isHistoryEnabled = true
        let (body, metadata, face, edge, vertex) = CADFileLoader.shapeToBodyMetadataAndIdentities(
            shape, id: bodyID, color: SIMD4<Float>(0.7, 0.7, 0.75, 1.0), graph: graph)
        return (body, metadata, face, edge, vertex)
    }

    private func pick(primitive: Int, kind: PrimitiveKind, bodyID: String) -> PickResult? {
        let raw =
            UInt32(0) | (UInt32(primitive & 0x3FFF) << 16) | (UInt32(kind.rawValue) << 30)
        return PickResult(rawValue: raw, indexMap: [0: bodyID])
    }

    @Test("A face pick resolves to the same ordinal the resolver reaches independently")
    func facePickAgreesWithResolver() throws {
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let ctx = InteractiveContext(viewport: ViewportController())
        ctx.selectionMode = [.face]
        let object = ctx.display(shape)
        let body = try #require(ctx.sourceBody(for: object))
        try #require(!body.faceIndices.isEmpty)
        let independent = independentIdentity(for: shape, bodyID: body.id)
        let faceIndices = independent.metadata?.faceIndices ?? []
        try #require(!faceIndices.isEmpty)

        // Every triangle, not just triangle 0. A box puts two triangles on each face, so
        // comparing a single pick cannot see an off-by-one in the triangle index: it lands on
        // the same face either way. Verified by injecting `triangleIndex + 1` into the wrapper,
        // which this catches and a single-pick version did not.
        var compared = 0
        for triangle in faceIndices.indices {
            guard
                let expected = SubShapePickResolver.resolveFace(
                    triangleIndex: triangle, faceIndices: faceIndices,
                    identity: independent.face, shape: shape)
            else { continue }
            ctx.clearSelection()
            ctx.handlePick(try #require(pick(primitive: triangle, kind: .face, bodyID: body.id)))
            #expect(
                containsFace(ctx.selection.subshapes, object, ordinal: expected.ordinal),
                "triangle \(triangle): the context resolved a different face than the resolver")
            compared += 1
        }
        #expect(compared > 1, "the sweep must compare more than one pick to be meaningful")
    }

    @Test("An edge pick resolves to the same ordinal the resolver reaches independently")
    func edgePickAgreesWithResolver() throws {
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let ctx = InteractiveContext(viewport: ViewportController())
        ctx.selectionMode = [.edge]
        let object = ctx.display(shape)
        let body = try #require(ctx.sourceBody(for: object))
        let independent = independentIdentity(for: shape, bodyID: body.id)
        let edgeIndices = independent.body?.edgeIndices ?? []
        try #require(!edgeIndices.isEmpty)

        var compared = 0
        for segment in edgeIndices.indices {
            guard
                let expected = SubShapePickResolver.resolveEdge(
                    segmentIndex: segment, edgeIndices: edgeIndices,
                    identity: independent.edge, shape: shape)
            else { continue }
            ctx.clearSelection()
            ctx.handlePick(try #require(pick(primitive: segment, kind: .edge, bodyID: body.id)))
            #expect(
                containsEdge(ctx.selection.subshapes, object, ordinal: expected.ordinal),
                "segment \(segment): the context resolved a different edge than the resolver")
            compared += 1
        }
        #expect(compared > 1, "the sweep must compare more than one pick to be meaningful")
    }

    @Test("A vertex pick resolves to the same ordinal the resolver reaches independently")
    func vertexPickAgreesWithResolver() throws {
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let ctx = InteractiveContext(viewport: ViewportController())
        ctx.selectionMode = [.vertex]
        let object = ctx.display(shape)
        let body = try #require(ctx.sourceBody(for: object))
        let independent = independentIdentity(for: shape, bodyID: body.id)
        let vertexIndices = independent.body?.vertexIndices ?? []
        let pointCount = independent.body?.vertices.count ?? 0
        try #require(!vertexIndices.isEmpty)

        var compared = 0
        for point in vertexIndices.indices {
            guard
                let expected = SubShapePickResolver.resolveVertex(
                    pointIndex: point, pointCount: pointCount, vertexIndices: vertexIndices,
                    identity: independent.vertex, shape: shape)
            else { continue }
            ctx.clearSelection()
            ctx.handlePick(try #require(pick(primitive: point, kind: .vertex, bodyID: body.id)))
            #expect(
                containsVertex(ctx.selection.subshapes, object, ordinal: expected.ordinal),
                "point \(point): the context resolved a different vertex than the resolver")
            compared += 1
        }
        #expect(compared > 1, "the sweep must compare more than one pick to be meaningful")
    }

    /// The gating is the wrapper's own contribution, and it must gate rather than re-resolve.
    ///
    /// With `.face` off, a face pick must produce no face selection even though the resolver would
    /// happily resolve that same triangle. This is what keeps the mode check in AIS from drifting
    /// into a second resolution path.
    @Test("Selection-mode gating suppresses a pick the resolver would still resolve")
    func gatingSuppressesAPickTheResolverWouldResolve() throws {
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let ctx = InteractiveContext(viewport: ViewportController())
        ctx.selectionMode = [.edge]  // deliberately not .face, and not .body
        let object = ctx.display(shape)
        let body = try #require(ctx.sourceBody(for: object))

        let independent = independentIdentity(for: shape, bodyID: body.id)
        _ = try #require(
            SubShapePickResolver.resolveFace(
                triangleIndex: 0,
                faceIndices: independent.metadata?.faceIndices ?? [],
                identity: independent.face,
                shape: shape),
            "the resolver must resolve this face, or the suppression below proves nothing")

        ctx.handlePick(try #require(pick(primitive: 0, kind: .face, bodyID: body.id)))

        #expect(
            ctx.selection.faces.isEmpty,
            "a face pick must be gated out by selectionMode, not resolved anyway")
    }

    /// The whole-body fallback is the other thing AIS adds, and it belongs to AIS.
    ///
    /// "The pick names the object rather than one of its faces" is a selection decision, not an
    /// identity one. OCCT draws the same line at
    /// `SelectMgr_EntityOwner::ComesFromDecomposition()`.
    @Test("With .body on and .face off, a face pick falls back to the whole body")
    func faceFallsBackToWholeBodyWhenFaceModeIsOff() throws {
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let ctx = InteractiveContext(viewport: ViewportController())
        ctx.selectionMode = [.body]
        let object = ctx.display(shape)
        let body = try #require(ctx.sourceBody(for: object))

        ctx.handlePick(try #require(pick(primitive: 0, kind: .face, bodyID: body.id)))

        #expect(ctx.selection.faces.isEmpty, "no face should be selected with .face off")
        #expect(
            ctx.selection.subshapes.contains {
                if case .body(let o) = $0 { return o == object }
                return false
            },
            "the pick should name the whole body instead")
    }
}
