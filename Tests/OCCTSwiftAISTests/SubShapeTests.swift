import OCCTSwift
import Testing

@testable import OCCTSwiftAIS

@Suite("SubShape")
struct SubShapeTests {

    @Test func t_sameObjectAndIndex_isEqual() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = InteractiveObject(shape: shape)
        let a = SubShape.face(obj, ref: SubShapeRef(shape: shape, ordinal: 2))
        let b = SubShape.face(obj, ref: SubShapeRef(shape: shape, ordinal: 2))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func t_differentIndex_notEqual() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = InteractiveObject(shape: shape)
        #expect(
            SubShape.face(obj, ref: SubShapeRef(shape: shape, ordinal: 0))
                != SubShape.face(obj, ref: SubShapeRef(shape: shape, ordinal: 1))
        )
    }

    @Test func t_differentCases_notEqual() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = InteractiveObject(shape: shape)
        #expect(
            SubShape.body(obj) != SubShape.face(obj, ref: SubShapeRef(shape: shape, ordinal: 0)))
        #expect(
            SubShape.face(obj, ref: SubShapeRef(shape: shape, ordinal: 0))
                != SubShape.edge(obj, ref: SubShapeRef(shape: shape, ordinal: 0))
        )
    }

    @Test func t_differentObjects_notEqual() throws {
        let shapeA = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let shapeB = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let a = InteractiveObject(shape: shapeA)
        let b = InteractiveObject(shape: shapeB)
        #expect(SubShape.body(a) != SubShape.body(b))
    }

    @Test func t_object_extracts_underlyingObject() throws {
        let shape = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let obj = InteractiveObject(shape: shape)
        #expect(SubShape.face(obj, ref: SubShapeRef(shape: shape, ordinal: 3)).object == obj)
        #expect(SubShape.body(obj).object == obj)
    }

    @Test func t_uidTakesPrecedenceOverOrdinal_whenBothPresent() throws {
        // Two refs with the same uid but different ordinals are equal: the
        // durable handle is the identity, not the render-path index.
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let graph = try #require(BRepGraph(shape: shape))
        let uid = try #require(
            graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: 0))
        let a = SubShapeRef(shape: shape, uid: uid, ordinal: 0)
        let b = SubShapeRef(shape: shape, uid: uid, ordinal: 99)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func t_refWithUID_notEqualToRefWithoutUID_evenAtSameOrdinal() throws {
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let graph = try #require(BRepGraph(shape: shape))
        let uid = try #require(
            graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: 0))
        let withUID = SubShapeRef(shape: shape, uid: uid, ordinal: 0)
        let withoutUID = SubShapeRef(shape: shape, ordinal: 0)
        #expect(withUID != withoutUID)
    }
}
