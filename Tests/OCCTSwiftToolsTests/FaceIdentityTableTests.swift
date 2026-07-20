import Testing
import simd
import OCCTSwift
import OCCTSwiftViewport
@testable import OCCTSwiftTools

@Suite("CADFileLoader.shapeToBodyMetadataAndIdentity / FaceIdentityTable")
struct FaceIdentityTableTests {

    @Test func t_boxTableMapsEveryOrdinalToAFace() {
        guard let box = Shape.box(width: 10, height: 5, depth: 3) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let (body, meta, table) = CADFileLoader.shapeToBodyMetadataAndIdentity(
            box, id: "box", color: SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
        )
        guard let body, let meta, let table else {
            Issue.record("shapeToBodyMetadataAndIdentity returned nil for a closed box")
            return
        }
        #expect(table.shapes.count == box.faces().count)
        #expect(table.uids == nil, "no BRepGraph was supplied")

        for ordinal in Set(body.faceIndices.map(Int.init)) {
            guard let faceShape = table.shape(forOrdinal: ordinal) else {
                Issue.record("no shape recorded for ordinal \(ordinal)")
                continue
            }
            #expect(faceShape.shapeType == .face)
        }
        #expect(meta.faceIndices == body.faceIndices)
    }

    @Test func t_outOfRangeOrdinalReturnsNil() {
        guard let box = Shape.box(width: 2, height: 2, depth: 2) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let (_, _, table) = CADFileLoader.shapeToBodyMetadataAndIdentity(
            box, id: "box", color: SIMD4<Float>(1, 1, 1, 1)
        )
        guard let table else {
            Issue.record("expected a table for a closed box")
            return
        }
        #expect(table.shape(forOrdinal: -1) == nil)
        #expect(table.shape(forOrdinal: table.shapes.count) == nil)
        #expect(table.uid(forOrdinal: 0) == nil, "no graph supplied, so no UIDs at all")
    }

    @Test func t_existingEntryPointUnchangedByOverload() {
        guard let box = Shape.box(width: 4, height: 4, depth: 4) else {
            Issue.record("Shape.box returned nil")
            return
        }
        let color = SIMD4<Float>(0.3, 0.6, 0.9, 1.0)
        let (body, meta) = CADFileLoader.shapeToBodyAndMetadata(box, id: "box", color: color)
        let (bodyViaOverload, metaViaOverload, _) = CADFileLoader.shapeToBodyMetadataAndIdentity(
            box, id: "box", color: color
        )
        guard let body, let meta, let bodyViaOverload, let metaViaOverload else {
            Issue.record("both entry points should succeed on a closed box")
            return
        }
        #expect(body.vertexData == bodyViaOverload.vertexData)
        #expect(body.indices == bodyViaOverload.indices)
        #expect(body.faceIndices == bodyViaOverload.faceIndices)
        #expect(meta.faceIndices == metaViaOverload.faceIndices)
    }

    /// Regression for issue #42: a face shared between two shells is one node in a
    /// `BRepGraph` but appears once *per shell* in the render-path traversal
    /// `Shape.faces()` uses — the very enumeration `FaceIdentityTable.shapes` is built from.
    /// Build two shells from a box's faces that both include the identical face `Shape`
    /// (same underlying `TopoDS_Face`, so `IsSame` holds), compound them, and verify:
    ///   - the raw per-shell traversal counts the shared face twice (unlike the deduplicated
    ///     `subShapes(ofType: .face)`, which is exactly the enumeration issue #42 says
    ///     consumers wrongly assumed agreed with the render path),
    ///   - both ordinals resolve, via the supplied graph, to the same node and the same
    ///     `GraphUID`,
    ///   - every ordinal's `table.shape(forOrdinal:)` resolves via `graph.findNode(for:)` to a
    ///     non-nil node.
    @Test func t_sharedFaceBetweenShellsResolvesToOneGraphUID() {
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

        // The render path's raw traversal visits the shared face once per shell (7 total),
        // diverging from the deduplicated `subShapes(ofType: .face)` (6) it's easy to
        // mistakenly assume it agrees with.
        #expect(compound.faces().count == 7)
        #expect(compound.subShapes(ofType: .face).count == 6)

        guard let graph = BRepGraph(shape: compound) else {
            Issue.record("BRepGraph(shape:) returned nil")
            return
        }

        let (body, meta, table) = CADFileLoader.shapeToBodyMetadataAndIdentity(
            compound, id: "shared", color: SIMD4<Float>(1, 1, 1, 1), graph: graph
        )
        guard let body, let meta, let table else {
            Issue.record("shapeToBodyMetadataAndIdentity returned nil for the shared-face compound")
            return
        }
        #expect(body.faceIndices.count == meta.faceIndices.count)
        #expect(table.shapes.count == 7, "shellA's 3 faces + shellB's 4 faces, shared face counted once per shell")
        guard let uids = table.uids else {
            Issue.record("expected UIDs when a graph was supplied")
            return
        }
        #expect(uids.count == table.shapes.count)

        // Every ordinal must resolve back through the supplied graph.
        var nodes: [(kind: BRepGraph.NodeKind, index: Int)] = []
        for ordinal in 0..<table.shapes.count {
            guard let faceShape = table.shape(forOrdinal: ordinal) else {
                Issue.record("no shape recorded for ordinal \(ordinal)")
                continue
            }
            guard let node = graph.findNode(for: faceShape) else {
                Issue.record("ordinal \(ordinal)'s shape did not resolve in the graph")
                continue
            }
            nodes.append(node)
        }
        #expect(nodes.count == 7)

        // Ordinal 0 (shellA's copy of the shared face) and ordinal 3 (shellB's copy,
        // immediately after shellA's 3 faces) must collapse to the same graph node...
        #expect(nodes[0].kind == nodes[3].kind)
        #expect(nodes[0].index == nodes[3].index)
        // ...and the same durable GraphUID.
        guard let uid0 = table.uid(forOrdinal: 0), let uid3 = table.uid(forOrdinal: 3) else {
            Issue.record("expected both shared-face ordinals to mint a GraphUID")
            return
        }
        #expect(uid0 == uid3)

        // A sanity check that the equality above isn't vacuous: an unshared face's ordinal
        // mints a different UID.
        guard let uid1 = table.uid(forOrdinal: 1) else {
            Issue.record("expected ordinal 1 to mint a GraphUID")
            return
        }
        #expect(uid1 != uid0)
    }
}
