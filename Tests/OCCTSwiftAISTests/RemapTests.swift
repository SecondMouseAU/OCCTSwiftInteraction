import OCCTSwift
import OCCTSwiftViewport
import Testing

@testable import OCCTSwiftAIS

@MainActor
@Suite("Remap")
struct RemapTests {

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> OCCTSwift.Shape {
        try #require(OCCTSwift.Shape.box(width: 4, height: 4, depth: 4))
    }

    // MARK: - Body remapping

    @Test func t_remap_body_alwaysRebindsToNewObject() throws {
        let ctx = makeContext()
        let oldObj = ctx.display(try makeBox())
        let newObj = ctx.display(try makeBox())
        let graph = try #require(BRepGraph(shape: newObj.shape))

        let old = Selection([.body(oldObj)])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)

        #expect(remapped.subshapes == [.body(newObj)])
    }

    // MARK: - No durable identity → dropped, not guessed

    @Test func t_remap_faceWithNoUID_isDropped() throws {
        // A ref with no uid (no graph was in hand at pick time) has nothing
        // durable to resolve by: remap drops it rather than falling back to
        // a stored ordinal, which is exactly the index-correlation path #31
        // removes.
        let ctx = makeContext()
        let oldObj = ctx.display(try makeBox())
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try #require(BRepGraph(shape: newShape))

        let old = Selection([.face(oldObj, ref: SubShapeRef(shape: oldObj.shape, ordinal: 0))])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)

        #expect(remapped.isEmpty)
    }

    @Test func t_remap_uidForeignToGraph_isDropped() throws {
        // A uid minted by a DIFFERENT graph instance is rejected by
        // `node(forUID:)` (BRepGraph's own foreign-uid guard, OCCTSwift#295)
        // rather than resolving to a coincidentally-matching node.
        let ctx = makeContext()
        let oldShape = try makeBox()
        let oldGraph = try #require(BRepGraph(shape: oldShape))
        let foreignUID = try #require(
            oldGraph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: 0)
        )
        let oldObj = ctx.display(oldShape)

        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try #require(BRepGraph(shape: newShape))  // a different instance

        let old = Selection([
            .face(oldObj, ref: SubShapeRef(shape: oldShape, uid: foreignUID, ordinal: 0))
        ])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)

        #expect(remapped.isEmpty)
    }

    @Test func t_remap_emptySelection_returnsEmpty() throws {
        let ctx = makeContext()
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try #require(BRepGraph(shape: newShape))
        let remapped = ctx.remap(Selection(), using: graph, rebindingTo: newObj)
        #expect(remapped.isEmpty)
    }

    // MARK: - Real absorbed-history mutation: 1 -> 1 (untouched)

    @Test func t_remap_faceUntouchedByOperation_resolvesToItself() throws {
        let base = try #require(
            OCCTSwift.Shape.box(origin: SIMD3(0, 0, 0), width: 10, height: 10, depth: 10))
        let graph = try #require(BRepGraph(shape: base))
        let rootNode = try #require(graph.findNode(for: base))
        let root = BRepGraph.NodeRef(kind: rootNode.kind, index: rootNode.index)

        // Pin the bottom face (min-z centroid): the channel cut below only
        // touches the top face, so the bottom face's node has no history
        // record and survives via `findDerivedOrSelf`'s untouched case.
        let faces = base.faces()
        let bottomIndex = try #require(
            facesWithCentroids(of: base).min { $0.centroid.z < $1.centroid.z }?.index)
        let bottomFace = try #require(Shape.fromFace(faces[bottomIndex]))
        let bottomNode = try #require(graph.findNode(for: bottomFace))
        let pinned = BRepGraph.NodeRef(kind: bottomNode.kind, index: bottomNode.index)
        let uid = try #require(
            graph.uid(ofNodeKind: Int(pinned.kind.rawValue), index: pinned.index))

        let tool = try #require(
            OCCTSwift.Shape.box(origin: SIMD3(-1, 4, 8), width: 12, height: 2, depth: 4))
        let (result, history) = try #require(base.subtractedWithFullHistory(tool))
        graph.add(result, absorbing: history, inputRoots: [root], operationName: "channel-cut")

        let ctx = makeContext()
        let oldObj = InteractiveObject(shape: base)
        let newObj = InteractiveObject(shape: result)
        let old = Selection([
            .face(oldObj, ref: SubShapeRef(shape: bottomFace, uid: uid, ordinal: bottomIndex))
        ])

        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)

        #expect(remapped.subshapes.count == 1)
        if case .face(let obj, let ref)? = remapped.subshapes.first {
            #expect(obj == newObj)
            #expect(ref.uid != nil)
        } else {
            Issue.record("expected exactly one .face sub-shape")
        }
        #expect(ctx.isDeleted(old.subshapes.first!, in: graph) == false)
    }

    // MARK: - Real absorbed-history mutation: 1 -> N (split)

    @Test func t_remap_faceSplitByChannelCut_expandsToBothStrips() throws {
        // The channel-cut recipe from OCCTSwift's durable-identity cookbook:
        // a tool box straddling the top face of a 10x10x10 box bisects it
        // into two strips.
        let base = try #require(
            OCCTSwift.Shape.box(origin: SIMD3(0, 0, 0), width: 10, height: 10, depth: 10))
        let graph = try #require(BRepGraph(shape: base))
        let rootNode = try #require(graph.findNode(for: base))
        let root = BRepGraph.NodeRef(kind: rootNode.kind, index: rootNode.index)

        let faces = base.faces()
        let topIndex = try #require(
            facesWithCentroids(of: base).max { $0.centroid.z < $1.centroid.z }?.index)
        let topFace = try #require(Shape.fromFace(faces[topIndex]))
        let topNode = try #require(graph.findNode(for: topFace))
        let pinned = BRepGraph.NodeRef(kind: topNode.kind, index: topNode.index)
        let uid = try #require(
            graph.uid(ofNodeKind: Int(pinned.kind.rawValue), index: pinned.index))

        let tool = try #require(
            OCCTSwift.Shape.box(origin: SIMD3(-1, 4, 8), width: 12, height: 2, depth: 4))
        let (result, history) = try #require(base.subtractedWithFullHistory(tool))
        graph.add(result, absorbing: history, inputRoots: [root], operationName: "channel-cut")

        // Sanity per the cookbook: currentForms mixes kinds (adds the cut's new
        // section edges); filtering by .face should isolate exactly 2 strips.
        let strips = graph.currentForms(of: pinned).filter { $0.kind == .face }
        #expect(strips.count == 2)

        let ctx = makeContext()
        let oldObj = InteractiveObject(shape: base)
        let newObj = InteractiveObject(shape: result)
        let old = Selection([
            .face(oldObj, ref: SubShapeRef(shape: topFace, uid: uid, ordinal: topIndex))
        ])

        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)

        #expect(
            remapped.subshapes.count == 2,
            "one selected face split into two strips should yield both")
        #expect(
            remapped.subshapes.allSatisfy { subshape in
                guard case .face(let obj, let ref) = subshape else { return false }
                return obj == newObj && ref.uid != nil
            })
    }

    // MARK: - Real absorbed-history mutation: 1 -> 0 (deleted)

    @Test func t_remap_faceEntirelyRemoved_isDroppedAndReportedDeleted() throws {
        // A tool that fully encloses one side face removes it from the result
        // entirely: `historyIsDeleted` distinguishes this from "untouched".
        let base = try #require(
            OCCTSwift.Shape.box(origin: SIMD3(0, 0, 0), width: 10, height: 10, depth: 10))
        let graph = try #require(BRepGraph(shape: base))
        let rootNode = try #require(graph.findNode(for: base))
        let root = BRepGraph.NodeRef(kind: rootNode.kind, index: rootNode.index)

        let faces = base.faces()
        let topIndex = try #require(
            facesWithCentroids(of: base).max { $0.centroid.z < $1.centroid.z }?.index)
        let topFace = try #require(Shape.fromFace(faces[topIndex]))
        let topNode = try #require(graph.findNode(for: topFace))
        let pinned = BRepGraph.NodeRef(kind: topNode.kind, index: topNode.index)
        let uid = try #require(
            graph.uid(ofNodeKind: Int(pinned.kind.rawValue), index: pinned.index))

        // A tool that engulfs the entire top face (oversized in X/Y, thin
        // sliver in Z) removes it completely rather than merely splitting it.
        let tool = try #require(
            OCCTSwift.Shape.box(origin: SIMD3(-5, -5, 8), width: 20, height: 20, depth: 4))
        let (result, history) = try #require(base.subtractedWithFullHistory(tool))
        graph.add(
            result, absorbing: history, inputRoots: [root], operationName: "full-face-removal")

        #expect(
            graph.historyIsDeleted(pinned), "the fully-consumed face should be reported as deleted")

        let ctx = makeContext()
        let oldObj = InteractiveObject(shape: base)
        let newObj = InteractiveObject(shape: result)
        let oldSub = SubShape.face(
            oldObj, ref: SubShapeRef(shape: topFace, uid: uid, ordinal: topIndex))
        let old = Selection([oldSub])

        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)

        #expect(remapped.isEmpty, "a deleted face contributes nothing to the remapped selection")
        #expect(ctx.isDeleted(oldSub, in: graph), "isDeleted must report the deletion explicitly")
    }

    @Test func t_isDeleted_falseForBodySubshape() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let graph = try #require(BRepGraph(shape: obj.shape))
        #expect(ctx.isDeleted(.body(obj), in: graph) == false)
    }

    // MARK: - Mixed-kind selection

    @Test func t_remap_mixedSelection_bodyAndFace_remapEachIndependently() throws {
        let base = try #require(
            OCCTSwift.Shape.box(origin: SIMD3(0, 0, 0), width: 10, height: 10, depth: 10))
        let graph = try #require(BRepGraph(shape: base))
        let rootNode = try #require(graph.findNode(for: base))
        let root = BRepGraph.NodeRef(kind: rootNode.kind, index: rootNode.index)

        let faces = base.faces()
        let bottomIndex = try #require(
            facesWithCentroids(of: base).min { $0.centroid.z < $1.centroid.z }?.index)
        let bottomFace = try #require(Shape.fromFace(faces[bottomIndex]))
        let bottomNode = try #require(graph.findNode(for: bottomFace))
        let pinned = BRepGraph.NodeRef(kind: bottomNode.kind, index: bottomNode.index)
        let uid = try #require(
            graph.uid(ofNodeKind: Int(pinned.kind.rawValue), index: pinned.index))

        let tool = try #require(
            OCCTSwift.Shape.box(origin: SIMD3(-1, 4, 8), width: 12, height: 2, depth: 4))
        let (result, history) = try #require(base.subtractedWithFullHistory(tool))
        graph.add(result, absorbing: history, inputRoots: [root], operationName: "channel-cut")

        let ctx = makeContext()
        let oldObj = InteractiveObject(shape: base)
        let newObj = InteractiveObject(shape: result)
        let old = Selection([
            .body(oldObj),
            .face(oldObj, ref: SubShapeRef(shape: bottomFace, uid: uid, ordinal: bottomIndex)),
        ])

        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)

        #expect(remapped.subshapes.count == 2)
        #expect(remapped.subshapes.contains(.body(newObj)))
    }
}
