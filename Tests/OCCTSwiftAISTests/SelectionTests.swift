import OCCTSwift
import Testing

@testable import OCCTSwiftAIS

@Suite("Selection")
struct SelectionTests {

    @Test func t_empty_byDefault() {
        let s = Selection()
        #expect(s.isEmpty)
        #expect(s.count == 0)
        #expect(s.bodies.isEmpty)
        #expect(s.faces.isEmpty)
    }

    @Test func t_insertSameSubshapeTwice_isIdempotent() throws {
        let shape = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let obj = InteractiveObject(shape: shape)
        let faceShape = try #require(shape.subShape(type: .face, index: 0))
        let face = SubShape.face(obj, ref: SubShapeRef(shape: faceShape, ordinal: 0))
        let s = Selection([face, face, face])
        #expect(s.count == 1)
    }

    @Test func t_bodies_derivesFromSubshapes() throws {
        let shapeA = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let shapeB = try #require(Shape.box(width: 2, height: 2, depth: 2))
        let a = InteractiveObject(shape: shapeA)
        let b = InteractiveObject(shape: shapeB)
        let faceA0 = try #require(shapeA.subShape(type: .face, index: 0))
        let faceA1 = try #require(shapeA.subShape(type: .face, index: 1))
        let s = Selection([
            .face(a, ref: SubShapeRef(shape: faceA0, ordinal: 0)),
            .face(a, ref: SubShapeRef(shape: faceA1, ordinal: 1)),
            .body(b),
        ])
        #expect(s.bodies == [a, b])
    }

    @Test func t_faces_resolveToFaceHandles() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = InteractiveObject(shape: shape)
        let face0 = try #require(shape.subShape(type: .face, index: 0))
        let face1 = try #require(shape.subShape(type: .face, index: 1))
        let s = Selection([
            .face(obj, ref: SubShapeRef(shape: face0, ordinal: 0)),
            .face(obj, ref: SubShapeRef(shape: face1, ordinal: 1)),
            .body(obj),  // should be excluded from .faces
        ])
        #expect(s.faces.count == 2)
    }

    @Test func t_faces_droppedWhenRefShapeIsNotActuallyAFace() throws {
        // `.faces` resolves directly from `ref.shape` (no ordinal round-trip;
        // see SubShapeRef's docs); a ref whose shape isn't a TopoDS_Face is
        // dropped by `Face(_:)`'s failable init, same end result as the old
        // out-of-range-index case but for the new reason.
        let shape = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let obj = InteractiveObject(shape: shape)
        let face0 = try #require(shape.subShape(type: .face, index: 0))
        let s = Selection([
            .face(obj, ref: SubShapeRef(shape: face0, ordinal: 0)),
            .face(obj, ref: SubShapeRef(shape: shape, ordinal: 9999)),  // whole solid, not a face
        ])
        #expect(s.faces.count == 1)
    }
}
