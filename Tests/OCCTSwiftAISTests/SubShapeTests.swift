import OCCTSwift
import OCCTSwiftTools
import Testing

@testable import OCCTSwiftAIS

@Suite("OCCTSwiftTools.SubShape")
struct SubShapeTests {

    @Test func t_sameObjectAndIndex_isEqual() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = OCCTSwiftTools.InteractiveObject(shape: shape)
        let a = OCCTSwiftTools.SubShape.face(
            obj, ref: OCCTSwiftTools.SubShapeRef(shape: shape, ordinal: 2))
        let b = OCCTSwiftTools.SubShape.face(
            obj, ref: OCCTSwiftTools.SubShapeRef(shape: shape, ordinal: 2))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func t_differentIndex_notEqual() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = OCCTSwiftTools.InteractiveObject(shape: shape)
        #expect(
            OCCTSwiftTools.SubShape.face(
                obj, ref: OCCTSwiftTools.SubShapeRef(shape: shape, ordinal: 0))
                != OCCTSwiftTools.SubShape.face(
                    obj, ref: OCCTSwiftTools.SubShapeRef(shape: shape, ordinal: 1))
        )
    }

    @Test func t_differentCases_notEqual() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = OCCTSwiftTools.InteractiveObject(shape: shape)
        #expect(
            OCCTSwiftTools.SubShape.body(obj)
                != OCCTSwiftTools.SubShape.face(
                    obj, ref: OCCTSwiftTools.SubShapeRef(shape: shape, ordinal: 0)))
        #expect(
            OCCTSwiftTools.SubShape.face(
                obj, ref: OCCTSwiftTools.SubShapeRef(shape: shape, ordinal: 0))
                != OCCTSwiftTools.SubShape.edge(
                    obj, ref: OCCTSwiftTools.SubShapeRef(shape: shape, ordinal: 0))
        )
    }

    @Test func t_differentObjects_notEqual() throws {
        let shapeA = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let shapeB = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let a = OCCTSwiftTools.InteractiveObject(shape: shapeA)
        let b = OCCTSwiftTools.InteractiveObject(shape: shapeB)
        #expect(OCCTSwiftTools.SubShape.body(a) != OCCTSwiftTools.SubShape.body(b))
    }

    @Test func t_object_extracts_underlyingObject() throws {
        let shape = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let obj = OCCTSwiftTools.InteractiveObject(shape: shape)
        #expect(
            OCCTSwiftTools.SubShape.face(
                obj, ref: OCCTSwiftTools.SubShapeRef(shape: shape, ordinal: 3)
            ).object == obj)
        #expect(OCCTSwiftTools.SubShape.body(obj).object == obj)
    }

    @Test func t_uidTakesPrecedenceOverOrdinal_whenBothPresent() throws {
        // Two refs with the same uid but different ordinals are equal: the
        // durable handle is the identity, not the render-path index.
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let graph = try #require(BRepGraph(shape: shape))
        let uid = try #require(
            graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: 0))
        let a = OCCTSwiftTools.SubShapeRef(shape: shape, uid: uid, ordinal: 0)
        let b = OCCTSwiftTools.SubShapeRef(shape: shape, uid: uid, ordinal: 99)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func t_refWithUID_notEqualToRefWithoutUID_evenAtSameOrdinal() throws {
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let graph = try #require(BRepGraph(shape: shape))
        let uid = try #require(
            graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: 0))
        let withUID = OCCTSwiftTools.SubShapeRef(shape: shape, uid: uid, ordinal: 0)
        let withoutUID = OCCTSwiftTools.SubShapeRef(shape: shape, ordinal: 0)
        #expect(withUID != withoutUID)
    }
}
