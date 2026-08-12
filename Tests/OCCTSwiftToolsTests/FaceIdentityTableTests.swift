import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

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

    /// Regression for issue #42, updated for OCCTSwift v2.0.0 (issue #51). Originally, a face
    /// shared between two shells was one node in a `BRepGraph` but appeared once *per shell* in
    /// the render-path traversal `Shape.faces()` used, which is exactly why `FaceIdentityTable`
    /// exists: to capture the correspondence directly rather than let a consumer assume the
    /// render-path ordinal agrees with `subShapes(ofType: .face)`'s independently deduplicated
    /// one.
    ///
    /// OCCTSwift v2.0.0 (#541/#613) closed that specific divergence upstream: `Shape.faces()` is
    /// now itself the deduplicated enumeration, and `Mesh.Triangle.faceIndex` moved onto that
    /// same enumeration in the same release, so the shared face's two shell-local triangulations
    /// now carry one index, not two. `FaceIdentityTable` needed no source change for this (it
    /// already reads `shape.faces()` dynamically rather than hardcoding an enumeration), but this
    /// fixture's own expectations did. Build two shells from a box's faces that both include the
    /// identical face `Shape` (same underlying `TopoDS_Face`, so `IsSame` holds), compound them,
    /// and verify the new, collapsed contract end to end:
    ///   - `Shape.faces()` and `subShapes(ofType: .face)` now agree (6, not the old 7 vs 6);
    ///     `orientedFaces()` (#614) is the new spelling of the old occurrence count (7),
    ///   - the identity table has exactly one ordinal per distinct face, each resolving through
    ///     the supplied graph to a distinct node and a distinct `GraphUID` (there is nothing left
    ///     for a consumer to collapse),
    ///   - the render path collapsed the same way: the tessellated body's own `faceIndices`
    ///     carry the same number of distinct values as the table has ordinals, proving the
    ///     mesher's `Mesh.Triangle.faceIndex` and this table's `shape.faces()`-keyed ordinals
    ///     stayed in lockstep across the version bump rather than drifting apart.
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

        // Post-v2.0.0 (#541), Shape.faces() is itself the deduplicated enumeration, so it now
        // agrees with subShapes(ofType: .face) instead of double-counting the shared face.
        // orientedFaces() (#614) is the new spelling of the old occurrence-based count: shellA's
        // 3 faces plus shellB's 4, the shared face counted once per shell, is still 7.
        #expect(compound.faces().count == 6)
        #expect(compound.subShapes(ofType: .face).count == 6)
        #expect(compound.orientedFaces().count == 7)

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
        #expect(
            table.shapes.count == 6,
            "one ordinal per distinct face; the shared face no longer duplicates")
        guard let uids = table.uids else {
            Issue.record("expected UIDs when a graph was supplied")
            return
        }
        #expect(uids.count == table.shapes.count)

        // Every ordinal must resolve back through the supplied graph, to its own node.
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
        #expect(nodes.count == 6)

        // Unlike pre-2.0.0, no two ordinals should collapse onto the same GraphUID anymore:
        // there is only one ordinal per distinct face to begin with.
        let allUIDs = (0..<table.shapes.count).compactMap { table.uid(forOrdinal: $0) }
        #expect(allUIDs.count == table.shapes.count, "every ordinal must mint a GraphUID")
        #expect(
            Set(allUIDs).count == allUIDs.count, "every ordinal should mint a distinct GraphUID")

        // The render path collapsed the same way: the tessellated body's distinct face indices
        // match the table's ordinal count, proving the mesher's Mesh.Triangle.faceIndex and
        // FaceIdentityTable's shape.faces()-keyed ordinals stayed in lockstep across the bump.
        let distinctRenderFaceIndices = Set(body.faceIndices.map(Int.init))
        #expect(
            distinctRenderFaceIndices.count == table.shapes.count,
            "the shared face's two shell-local triangulations must carry the same faceIndex")
    }
}
