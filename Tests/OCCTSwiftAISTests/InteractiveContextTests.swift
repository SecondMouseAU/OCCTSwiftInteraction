import OCCTSwift
import OCCTSwiftViewport
import Testing

@testable import OCCTSwiftAIS

@MainActor
@Suite("InteractiveContext")
struct InteractiveContextTests {

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> Shape {
        try #require(Shape.box(width: 10, height: 5, depth: 3))
    }

    // MARK: - Display

    @Test func t_display_addsBodyAndReturnsObject() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        #expect(ctx.bodies.count == 1)
        #expect(ctx.bodies.first?.id == "ais.\(obj.id.uuidString)")
    }

    @Test func t_display_withCustomStyle_appliesColorAndVisibility() throws {
        let ctx = makeContext()
        var style = PresentationStyle.default
        style.color = SIMD3<Float>(1, 0, 0)
        style.transparency = 0.5
        style.visible = false
        _ = ctx.display(try makeBox(), style: style)
        let body = try #require(ctx.bodies.first)
        #expect(body.color.x == 1)
        #expect(abs(body.color.w - 0.5) < 0.001)
        #expect(body.isVisible == false)
    }

    @Test func t_remove_dropsBodyAndSelectionForThatObject() throws {
        let ctx = makeContext()
        let a = ctx.display(try makeBox())
        let b = ctx.display(try makeBox())
        ctx.select(.face(a, ref: SubShapeRef(shape: a.shape, ordinal: 0)))
        ctx.select(.face(b, ref: SubShapeRef(shape: b.shape, ordinal: 0)))
        #expect(ctx.selection.count == 2)

        ctx.remove(a)

        let sourceBodyIDs = ctx.bodies
            .filter { !$0.id.hasPrefix("ais.overlay.") }
            .map(\.id)
        #expect(sourceBodyIDs == ["ais.\(b.id.uuidString)"])
        #expect(ctx.selection.count == 1)
        #expect(ctx.selection.bodies == [b])
    }

    @Test func t_removeAll_clearsEverything() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        ctx.select(.body(obj))
        ctx.removeAll()
        #expect(ctx.bodies.isEmpty)
        #expect(ctx.selection.isEmpty)
        #expect(ctx.hover == nil)
    }

    // MARK: - Selection mutation

    @Test func t_select_isIdempotent() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let face = SubShape.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0))
        ctx.select(face)
        ctx.select(face)
        ctx.select(face)
        #expect(ctx.selection.count == 1)
    }

    @Test func t_deselect_removesEntry() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let face = SubShape.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0))
        ctx.select(face)
        ctx.deselect(face)
        #expect(ctx.selection.isEmpty)
    }

    @Test func t_clearSelection_emptiesSet() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0)))
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 1)))
        ctx.clearSelection()
        #expect(ctx.selection.isEmpty)
    }

    @Test func t_selectionModeChange_clearsSelection() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        ctx.selectionMode = [.face]
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0)))
        #expect(ctx.selection.count == 1)
        ctx.selectionMode = [.body]
        #expect(ctx.selection.isEmpty)
    }

    // MARK: - Pick handling

    @Test func t_handlePick_inFaceMode_resolvesToCorrectFace() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        try #require(!body.faceIndices.isEmpty)

        let triangleIdx = 0
        let expectedFaceIdx = Int(body.faceIndices[triangleIdx])
        let raw = UInt32(triangleIdx) << 16
        let pick = try #require(PickResult(rawValue: raw, indexMap: [0: body.id]))

        ctx.handlePick(pick)

        #expect(ctx.selection.count == 1)
        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: expectedFaceIdx))
    }

    @Test func t_handlePick_inBodyMode_resolvesToBody() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        let pick = try #require(PickResult(rawValue: 0, indexMap: [0: body.id]))

        ctx.handlePick(pick)

        #expect(ctx.selection.subshapes == [.body(obj)])
    }

    @Test func t_handlePick_replacesPreviousSelection() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)

        // Pre-populate via the additive API to confirm replacement, not addition.
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 99)))
        #expect(ctx.selection.count == 1)

        let triIdx = 0
        let raw = UInt32(triIdx) << 16
        let pick = try #require(PickResult(rawValue: raw, indexMap: [0: body.id]))
        ctx.handlePick(pick)

        #expect(ctx.selection.count == 1)
        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: 99) == false)
    }

    @Test func t_handlePick_unknownBody_isIgnored() throws {
        let ctx = makeContext()
        let pick = try #require(PickResult(rawValue: 0, indexMap: [0: "not-a-real-body"]))
        ctx.handlePick(pick)
        #expect(ctx.selection.isEmpty)
    }

    @Test func t_combineWiring_endToEnd() throws {
        // Verify the viewport.$pickResult subscription actually drives selection.
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        let pick = try #require(PickResult(rawValue: 0, indexMap: [0: body.id]))

        ctx.viewport.handlePick(result: pick)

        #expect(ctx.selection.subshapes == [.body(obj)])
    }

    // MARK: - Hover

    @Test func t_handleHover_inBodyMode_setsHoverToBody() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        ctx.handleHover(bodyID: body.id)
        #expect(ctx.hover == .body(obj))
    }

    @Test func t_handleHover_nilClearsHover() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let body = try #require(ctx.bodies.first)
        ctx.handleHover(bodyID: body.id)
        ctx.handleHover(bodyID: nil)
        #expect(ctx.hover == nil)
        _ = obj
    }
}
