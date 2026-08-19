import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftTools

/// Coverage for the one identity-table builder, added in OCCTSwiftInteraction#7.
///
/// It replaced three near-copies: `CADFileLoader`'s private helpers, `OCCTSwiftCADKit`'s statics,
/// and `OCCTSwiftUX`'s `ShapeIdentity`.
///
/// The bakeoff on #7 found the three agreed on every success path and differed only on failure
/// paths, so the failure cases carry most of the weight here: they had no shared coverage at all
/// before, which is exactly how the three drifted.
@Suite("ShapeIdentity")
struct ShapeIdentityTests {

    // MARK: - Success path

    @Test func t_boxPopulatesAllThreeTablesWithDurableUIDs() {
        guard let box = Shape.box(width: 10, height: 5, depth: 3) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let identity = ShapeIdentity(shape: box)

        #expect(identity.graph != nil, "a closed box builds a graph")
        #expect(identity.faces.shapes.count == 6)
        #expect(identity.edges.shapes.count == 12)
        #expect(identity.vertices.shapes.count == 8)

        // Every ordinal resolves to a shape and to a durable uid.
        for ordinal in identity.faces.shapes.indices {
            #expect(identity.faces.shape(forOrdinal: ordinal) != nil)
            #expect(identity.faces.uid(forOrdinal: ordinal) != nil, "face \(ordinal) has no uid")
        }
        for ordinal in identity.edges.shapes.indices {
            #expect(identity.edges.uid(forOrdinal: ordinal) != nil, "edge \(ordinal) has no uid")
        }
        for ordinal in identity.vertices.shapes.indices {
            #expect(
                identity.vertices.uid(forOrdinal: ordinal) != nil, "vertex \(ordinal) has no uid")
        }
    }

    /// Each table must be built from the enumeration the render path assigns its ordinals from.
    ///
    /// That is the whole contract. Checked against the shape directly rather than against a
    /// hardcoded count, so an upstream enumeration change surfaces here.
    @Test func t_tableLengthsMatchTheShapeEnumerationsTheyIndex() {
        guard let cyl = Shape.cylinder(radius: 5, height: 10) else {
            Issue.record("Shape.cylinder returned nil")
            return
        }
        let identity = ShapeIdentity(shape: cyl)
        #expect(identity.faces.shapes.count == cyl.faces().count)
        #expect(identity.edges.shapes.count == cyl.edges().count)
        #expect(identity.vertices.shapes.count == cyl.subShapes(ofType: .vertex).count)
    }

    /// `ShapeIdentity` and the bridge's own overload must produce the same tables.
    ///
    /// Since #7 they are the same code. If they ever diverge again, this is the tripwire.
    @Test func t_matchesWhatTheBridgeOverloadReturns() {
        guard let box = Shape.box(width: 8, height: 4, depth: 2) else {
            Issue.record("Shape.box returned nil")
            return
        }
        guard let graph = BRepGraph(shape: box) else {
            Issue.record("BRepGraph returned nil for a box")
            return
        }
        let direct = ShapeIdentity(shape: box, graph: graph)
        let (_, _, faceTable, edgeTable, vertexTable) =
            CADFileLoader.shapeToBodyMetadataAndIdentities(
                box, id: "box", color: SIMD4<Float>(1, 1, 1, 1), graph: graph)

        #expect(faceTable?.shapes.count == direct.faces.shapes.count)
        #expect(edgeTable?.shapes.count == direct.edges.shapes.count)
        #expect(vertexTable?.shapes.count == direct.vertices.shapes.count)
        for ordinal in direct.faces.shapes.indices {
            #expect(faceTable?.uid(forOrdinal: ordinal) == direct.faces.uid(forOrdinal: ordinal))
        }
        for ordinal in direct.edges.shapes.indices {
            #expect(edgeTable?.uid(forOrdinal: ordinal) == direct.edges.uid(forOrdinal: ordinal))
        }
        for ordinal in direct.vertices.shapes.indices {
            #expect(
                vertexTable?.uid(forOrdinal: ordinal) == direct.vertices.uid(forOrdinal: ordinal))
        }
    }

    /// A face shared between two shells is one entry, not two.
    ///
    /// Face identity keys on `IsSame` (OCCTSwiftInteraction#1). All three copies encoded this, so
    /// the survivor must too.
    @Test func t_sharedFaceBetweenShellsIsOneEntryWithOneUID() {
        guard let box = Shape.box(width: 10, height: 10, depth: 10) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let faces = box.subShapes(ofType: .face)
        guard let shellA = Shape.shellFromFaces([faces[0], faces[1], faces[2]]),
            let shellB = Shape.shellFromFaces([faces[0], faces[3], faces[4], faces[5]]),
            let compound = Shape.compound([shellA, shellB])
        else {
            Issue.record("failed to build the shared-face compound fixture")
            return
        }

        let identity = ShapeIdentity(shape: compound)
        // 6 distinct faces, 7 occurrences: the shared one is deduplicated by `faces()`.
        #expect(identity.faces.shapes.count == compound.faces().count)
        #expect(compound.orientedFaces().count > compound.faces().count, "fixture shares a face")

        let uids = identity.faces.shapes.indices.compactMap { identity.faces.uid(forOrdinal: $0) }
        #expect(uids.count == identity.faces.shapes.count, "every face resolved in the graph")
        #expect(Set(uids).count == uids.count, "no two ordinals share a uid")
    }

    // MARK: - Failure paths

    /// The `graph: nil` mode gives tables without uids, rather than no tables.
    ///
    /// Every ordinal still resolves to a shape. Preserved from `CADFileLoader`'s helpers, where it
    /// was the meaning of the `graph:` parameter being optional, and it had no direct coverage.
    @Test func t_nilGraphGivesShapesWithoutUIDsRatherThanNoTables() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let identity = ShapeIdentity(shape: box, graph: nil)

        #expect(identity.graph == nil)
        #expect(identity.faces.shapes.count == 6)
        #expect(identity.edges.shapes.count == 12)
        #expect(identity.vertices.shapes.count == 8)
        // `uids` absent entirely, not an array of nils: a caller can tell "no graph was supplied"
        // from "this ordinal did not resolve".
        #expect(identity.faces.uids == nil)
        #expect(identity.edges.uids == nil)
        #expect(identity.vertices.uids == nil)
        #expect(identity.faces.shape(forOrdinal: 0) != nil)
        #expect(identity.faces.uid(forOrdinal: 0) == nil)
    }

    /// A shape with no faces gets an empty face table rather than an absent one.
    ///
    /// With a graph its `uids` is an empty array rather than nil, so "no faces" stays
    /// distinguishable from "no graph". All three copies behaved this way (measured), so this pins
    /// it for the survivor.
    @Test func t_shapeWithNoFacesGivesAnEmptyFaceTableNotAnAbsentOne() {
        guard let box = Shape.box(width: 10, height: 10, depth: 10) else {
            Issue.record("Shape.box returned nil")
            return
        }
        guard let edgeShape = Shape.fromEdge(box.edges()[0]) else {
            Issue.record("Shape.fromEdge returned nil")
            return
        }

        let identity = ShapeIdentity(shape: edgeShape)
        #expect(edgeShape.faces().isEmpty, "fixture really has no faces")
        #expect(identity.faces.shapes.isEmpty)
        #expect(identity.faces.uids?.isEmpty == true, "graph present, so uids is [] not nil")
        #expect(identity.faces.shape(forOrdinal: 0) == nil)

        // The kinds it does have are still populated, so an unpickable kind does not take the
        // others down with it.
        #expect(identity.edges.shapes.count == 1)
        #expect(identity.vertices.shapes.count == 2)
        #expect(identity.edges.uid(forOrdinal: 0) != nil)
    }

    /// A lone vertex: only the vertex table has anything in it, and the other two are empty
    /// rather than the builder failing.
    @Test func t_loneVertexPopulatesOnlyTheVertexTable() {
        guard let box = Shape.box(width: 10, height: 10, depth: 10) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let vertexShape = box.subShapes(ofType: .vertex)[0]
        let identity = ShapeIdentity(shape: vertexShape)

        #expect(identity.faces.shapes.isEmpty)
        #expect(identity.edges.shapes.isEmpty)
        #expect(identity.vertices.shapes.count == 1)
    }

    // MARK: - Ordinal alignment when a sub-shape conversion fails

    /// A failed face conversion costs that one ordinal its identity and moves no other ordinal.
    ///
    /// The regression for OCCTSwiftInteraction#9. The tables used to be built with `compactMap`,
    /// so a failed conversion was dropped rather than held as a hole: every later face moved down
    /// one, `shapes[ordinal]` returned the face *after* the one the pick hit, and
    /// `uid(forOrdinal:)` minted a durable identity for it. Silent, with no error and no assertion
    /// on the way through.
    ///
    /// Driven through the internal conversion seam, because a genuine failure cannot be provoked
    /// through the public API: every `Face` that `faces()` returns already holds a live handle, so
    /// `Shape.fromFace` does not fail for one. Same treatment, and same reason, as
    /// `edgePolylineOnlyBridge` below.
    @Test func t_failedFaceConversionHolesOneOrdinalAndShiftsNoOther() throws {
        let box = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let graph = try #require(BRepGraph(shape: box))
        let faces = box.faces()
        let holed = 2
        let holedFace = try #require(Shape.fromFace(faces[holed]))

        // The reference is the same shape with every conversion succeeding.
        let intact = ShapeIdentity(shape: box, graph: graph)
        let withHole = ShapeIdentity(
            shape: box, graph: graph,
            faceToShape: { face in
                guard let converted = Shape.fromFace(face) else { return nil }
                return converted.isSame(as: holedFace) ? nil : converted
            },
            edgeToShape: Shape.fromEdge)

        // Non-vacuous: the six faces are six distinct identities, so "still names the same face"
        // below is a real claim rather than one any two faces of a box would satisfy.
        let intactUIDs = intact.faces.shapes.indices.compactMap { intact.faces.uid(forOrdinal: $0) }
        #expect(intactUIDs.count == faces.count)
        #expect(Set(intactUIDs).count == intactUIDs.count)

        // The ordinal space is the enumeration's, whatever became of an individual conversion.
        #expect(withHole.faces.shapes.count == faces.count)
        #expect(withHole.faces.uids?.count == faces.count)
        #expect(withHole.faces.shape(forOrdinal: holed) == nil, "the failed face has no identity")
        #expect(withHole.faces.uid(forOrdinal: holed) == nil, "and no durable uid either")

        // Every other ordinal names exactly what it named before, shape and uid.
        for ordinal in intact.faces.shapes.indices where ordinal != holed {
            let expected = try #require(intact.faces.shape(forOrdinal: ordinal))
            let actual = try #require(
                withHole.faces.shape(forOrdinal: ordinal), "ordinal \(ordinal) lost its face")
            #expect(actual.isSame(as: expected), "ordinal \(ordinal) names a different face")
            #expect(
                withHole.faces.uid(forOrdinal: ordinal) == intact.faces.uid(forOrdinal: ordinal),
                "ordinal \(ordinal) minted a different uid")
        }

        // What the degradation buys, end to end: a pick landing on the holed ordinal still names
        // the face it hit, through the resolver's re-derivation fallback, and simply carries no
        // durable handle. Under `compactMap` it resolved confidently to the next face along.
        let ref = try #require(
            SubShapePickResolver.resolveFace(
                triangleIndex: 0, faceIndices: [Int32(holed)], identity: withHole.faces, shape: box)
        )
        #expect(ref.ordinal == holed)
        #expect(ref.shape.isSame(as: holedFace), "the pick still names the face it hit")
        #expect(ref.uid == nil, "the one thing it loses is durable identity")

        // Edges and vertices are built from their own enumerations and are unaffected.
        #expect(withHole.edges.shapes.count == intact.edges.shapes.count)
        #expect(withHole.vertices.shapes.count == intact.vertices.shapes.count)
    }

    /// The same for edges: `Shape.fromEdge` is failable too, and `EdgeIdentityTable` indexes
    /// `ViewportBody.edgeIndices` the same way.
    @Test func t_failedEdgeConversionHolesOneOrdinalAndShiftsNoOther() throws {
        let box = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let graph = try #require(BRepGraph(shape: box))
        let edges = box.edges()
        let holed = 5
        let holedEdge = try #require(Shape.fromEdge(edges[holed]))

        let intact = ShapeIdentity(shape: box, graph: graph)
        let withHole = ShapeIdentity(
            shape: box, graph: graph,
            faceToShape: Shape.fromFace,
            edgeToShape: { edge in
                guard let converted = Shape.fromEdge(edge) else { return nil }
                return converted.isSame(as: holedEdge) ? nil : converted
            })

        #expect(withHole.edges.shapes.count == edges.count)
        #expect(withHole.edges.uids?.count == edges.count)
        #expect(withHole.edges.shape(forOrdinal: holed) == nil)
        #expect(withHole.edges.uid(forOrdinal: holed) == nil)

        for ordinal in intact.edges.shapes.indices where ordinal != holed {
            let expected = try #require(intact.edges.shape(forOrdinal: ordinal))
            let actual = try #require(
                withHole.edges.shape(forOrdinal: ordinal), "ordinal \(ordinal) lost its edge")
            #expect(actual.isSame(as: expected), "ordinal \(ordinal) names a different edge")
            #expect(
                withHole.edges.uid(forOrdinal: ordinal) == intact.edges.uid(forOrdinal: ordinal),
                "ordinal \(ordinal) minted a different uid")
        }

        let ref = try #require(
            SubShapePickResolver.resolveEdge(
                segmentIndex: 0, edgeIndices: [Int32(holed)], identity: withHole.edges, shape: box)
        )
        #expect(ref.ordinal == holed)
        #expect(ref.shape.isSame(as: holedEdge))
        #expect(ref.uid == nil)

        #expect(withHole.faces.shapes.count == intact.faces.shapes.count)
    }

    /// Total conversion failure keeps the ordinal space and takes the vertex table down with it,
    /// which is the asymmetry worth pinning: the vertex path has no conversion to fail.
    ///
    /// `subShapes(ofType: .vertex)` returns `Shape` values directly, so its alignment holds for
    /// free and its table is the one that stays non-optional. If someone ever "harmonises" the
    /// three by putting a failable conversion in front of the vertex enumeration, or the other two
    /// back onto `compactMap`, this is where it shows up.
    @Test func t_everyConversionFailingKeepsTheOrdinalSpaceAndLeavesVerticesWhole() throws {
        let box = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let graph = try #require(BRepGraph(shape: box))
        let identity = ShapeIdentity(
            shape: box, graph: graph, faceToShape: { _ in nil }, edgeToShape: { _ in nil })

        #expect(identity.faces.shapes.count == box.faces().count, "6 ordinals, none with identity")
        #expect(identity.edges.shapes.count == box.edges().count)
        #expect(identity.faces.shapes.allSatisfy { $0 == nil })
        #expect(identity.edges.shapes.allSatisfy { $0 == nil })
        // `uids` stays the same length and the same index space, so a caller reading it by ordinal
        // reads nil rather than another ordinal's handle.
        #expect(identity.faces.uids?.count == box.faces().count)
        #expect(identity.faces.uids?.allSatisfy { $0 == nil } == true)

        // Untouched, because nothing failable stands between the traversal and the table.
        #expect(identity.vertices.shapes.count == box.subShapes(ofType: .vertex).count)
        for ordinal in identity.vertices.shapes.indices {
            #expect(identity.vertices.uid(forOrdinal: ordinal) != nil)
        }
    }

    // MARK: - The edge-polyline-only branch

    /// The one place the three copies varied a table's *content*: `CADFileLoader` substituted an
    /// empty `FaceIdentityTable` on the branch taken when `mesh(...)` returns nil, while
    /// `OCCTSwiftCADKit` and `OCCTSwiftUX` built the face table in full from the shape. #7 took
    /// the general builder, so the face table is now populated here too.
    ///
    /// The branch is unreachable from a synthetic shape (a wire, an edge and a lone vertex all
    /// mesh to an empty `Mesh` rather than to nil, measured), which is why it is driven through
    /// the internal `edgePolylineOnlyBridge` seam directly. Same treatment, and same reason, as
    /// `bodyEntries`. Using a box makes the change visible: it has 6 faces and no triangles here.
    @Test func t_edgePolylineOnlyBranchBuildsTheFaceTableInFull() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let graph = BRepGraph(shape: box)
        let (body, meta, identity) = CADFileLoader.edgePolylineOnlyBridge(
            box, id: "edge-only", color: SIMD4<Float>(1, 1, 1, 1),
            edgeDeflection: CADFileLoader.defaultEdgeDeflection,
            maxPointsPerEdge: CADFileLoader.defaultMaxPointsPerEdge,
            measurements: nil, identity: true, graph: graph)

        guard let body, let meta, let identity else {
            Issue.record("edgePolylineOnlyBridge returned nil for a box")
            return
        }
        // No triangles at all on this branch, which is why the face table used to be emptied.
        #expect(body.indices.isEmpty)
        #expect(meta.faceIndices.isEmpty)
        #expect(!body.edgeIndices.isEmpty)

        // The face table is now the ordinary one. It names faces no pick can reach through this
        // body, which is safe because `SubShapePickResolver.resolveFace` bounds-checks against
        // `faceIndices` before ever reading it.
        #expect(identity.faces.shapes.count == 6)
        #expect(identity.faces.uid(forOrdinal: 0) != nil)
        #expect(
            SubShapePickResolver.resolveFace(
                triangleIndex: 0, faceIndices: meta.faceIndices,
                identity: identity.faces, shape: box) == nil,
            "an empty faceIndices still means not face-pickable, table or no table")

        // Edge and vertex tables were always built in full on this branch, and still are.
        #expect(identity.edges.shapes.count == 12)
        #expect(identity.vertices.shapes.count == 8)
    }

    /// The same branch with identity switched off builds no tables at all, so a caller that only
    /// wants a body does not pay for three enumerations plus a graph walk.
    @Test func t_edgePolylineOnlyBranchSkipsIdentityWhenNotAsked() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let (body, _, identity) = CADFileLoader.edgePolylineOnlyBridge(
            box, id: "edge-only", color: SIMD4<Float>(1, 1, 1, 1),
            edgeDeflection: CADFileLoader.defaultEdgeDeflection,
            maxPointsPerEdge: CADFileLoader.defaultMaxPointsPerEdge,
            measurements: nil, identity: false, graph: nil)

        #expect(body != nil)
        #expect(identity == nil)
    }

    /// A shape with neither a mesh nor any edge to draw produces nothing at all, rather than an
    /// empty body a consumer would then have to recognise as unusable.
    @Test func t_edgePolylineOnlyBranchReturnsNothingWhenThereAreNoEdges() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let vertexShape = box.subShapes(ofType: .vertex)[0]
        let (body, meta, identity) = CADFileLoader.edgePolylineOnlyBridge(
            vertexShape, id: "no-edges", color: SIMD4<Float>(1, 1, 1, 1),
            edgeDeflection: CADFileLoader.defaultEdgeDeflection,
            maxPointsPerEdge: CADFileLoader.defaultMaxPointsPerEdge,
            measurements: nil, identity: true, graph: nil)

        #expect(body == nil)
        #expect(meta == nil)
        #expect(identity == nil)
    }
}
