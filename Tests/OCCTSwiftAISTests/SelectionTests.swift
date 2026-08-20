import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
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
        let obj = OCCTSwiftTools.InteractiveObject(shape: shape)
        let faceShape = try #require(shape.subShape(type: .face, index: 0))
        let face = OCCTSwiftTools.SubShape.face(
            obj, ref: OCCTSwiftTools.SubShapeRef(shape: faceShape, ordinal: 0))
        let s = Selection([face, face, face])
        #expect(s.count == 1)
    }

    @Test func t_bodies_derivesFromSubshapes() throws {
        let shapeA = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let shapeB = try #require(Shape.box(width: 2, height: 2, depth: 2))
        let a = OCCTSwiftTools.InteractiveObject(shape: shapeA)
        let b = OCCTSwiftTools.InteractiveObject(shape: shapeB)
        let faceA0 = try #require(shapeA.subShape(type: .face, index: 0))
        let faceA1 = try #require(shapeA.subShape(type: .face, index: 1))
        let s = Selection([
            .face(a, ref: OCCTSwiftTools.SubShapeRef(shape: faceA0, ordinal: 0)),
            .face(a, ref: OCCTSwiftTools.SubShapeRef(shape: faceA1, ordinal: 1)),
            .body(b),
        ])
        #expect(s.bodies == [a, b])
    }

    @Test func t_faces_resolveToFaceHandles() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = OCCTSwiftTools.InteractiveObject(shape: shape)
        let face0 = try #require(shape.subShape(type: .face, index: 0))
        let face1 = try #require(shape.subShape(type: .face, index: 1))
        let s = Selection([
            .face(obj, ref: OCCTSwiftTools.SubShapeRef(shape: face0, ordinal: 0)),
            .face(obj, ref: OCCTSwiftTools.SubShapeRef(shape: face1, ordinal: 1)),
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
        let obj = OCCTSwiftTools.InteractiveObject(shape: shape)
        let face0 = try #require(shape.subShape(type: .face, index: 0))
        let s = Selection([
            .face(obj, ref: OCCTSwiftTools.SubShapeRef(shape: face0, ordinal: 0)),
            // whole solid, not a face
            .face(obj, ref: OCCTSwiftTools.SubShapeRef(shape: shape, ordinal: 9999)),
        ])
        #expect(s.faces.count == 1)
    }
}

/// The scheme parameter added to `InteractiveContext.select` in
/// OCCTSwiftInteraction#3 (phase 3 of ecosystem#43), when `OCCTSwiftCADKit` stopped keeping a
/// parallel selection and its four-scheme `select(_:scheme:)` merged into this one.
@Suite("Selection schemes on InteractiveContext")
@MainActor
struct InteractiveContextSchemeTests {

    private func makeFixture() throws -> (
        InteractiveContext, OCCTSwiftTools.SubShape, OCCTSwiftTools.SubShape
    ) {
        let ctx = InteractiveContext(viewport: ViewportController())
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let object = OCCTSwiftTools.InteractiveObject(shape: shape)
        let a = OCCTSwiftTools.SubShape.face(object, ref: try faceRef(object, 0))
        let b = OCCTSwiftTools.SubShape.face(object, ref: try faceRef(object, 1))
        return (ctx, a, b)
    }

    @Test("select(_:scheme:) implements replace/add/remove/xor")
    func t_selectScheme_implementsAllFour() throws {
        let (ctx, a, b) = try makeFixture()

        ctx.select(a, scheme: .replace)
        #expect(ctx.selection.subshapes == [a])

        ctx.select(b, scheme: .add)
        #expect(ctx.selection.subshapes == [a, b])

        ctx.select(a, scheme: .add)
        #expect(ctx.selection.count == 2, "add is idempotent")

        ctx.select(a, scheme: .remove)
        #expect(ctx.selection.subshapes == [b])

        ctx.select(a, scheme: .xor)
        #expect(ctx.selection.subshapes == [a, b])

        ctx.select(a, scheme: .xor)
        #expect(ctx.selection.subshapes == [b])

        ctx.select(a, scheme: .replace)
        #expect(ctx.selection.subshapes == [a], "replace discards the rest")
    }

    /// The reason `select(_:scheme:)` has no default value for `scheme`: giving the existing
    /// one-argument `select` a defaulted `.replace` would have retuned every existing call
    /// site from add to replace, silently.
    @Test("select(_:) still means add, not replace")
    func t_selectWithoutScheme_stillMeansAdd() throws {
        let (ctx, a, b) = try makeFixture()

        ctx.select(a)
        ctx.select(b)
        #expect(ctx.selection.subshapes == [a, b])

        ctx.deselect(a)
        #expect(ctx.selection.subshapes == [b])
    }

    @Test("displaysBody(withID:) reports only objects this context displays")
    func t_displaysBody_reportsDisplayedObjectsOnly() throws {
        let ctx = InteractiveContext(viewport: ViewportController())
        let shape = try #require(Shape.box(width: 4, height: 4, depth: 4))
        let object = ctx.display(shape)

        let bodyID = try #require(ctx.bodyID(for: object))
        #expect(ctx.displaysBody(withID: bodyID))
        #expect(!ctx.displaysBody(withID: "some.other.body"))

        ctx.remove(object)
        #expect(!ctx.displaysBody(withID: bodyID))
    }
}
