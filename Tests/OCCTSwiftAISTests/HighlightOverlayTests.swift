import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

@MainActor
@Suite("FaceHighlight")
struct HighlightOverlayTests {

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> OCCTSwift.Shape {
        try #require(OCCTSwift.Shape.box(width: 10, height: 5, depth: 3))
    }

    /// Source body for the given object. v0.6.1 highlight overlay writes into
    /// this body's `triangleStyles` rather than spawning a separate overlay body.
    private func sourceBody(_ ctx: InteractiveContext, target: InteractiveObject) -> ViewportBody? {
        ctx.sourceBody(for: target)
    }

    // MARK: - Per-triangle highlight styles

    @Test func t_faceSelection_writesNonZeroAlphaForMatchingTriangles() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())

        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0)))

        let body = try #require(sourceBody(ctx, target: obj))
        let triangleCount = body.indices.count / 3
        #expect(
            body.triangleStyles.count == triangleCount,
            "triangleStyles should be sized to the triangle count once a face is selected")
        // At least one triangle must be highlighted (a box face is two triangles).
        let highlighted = body.triangleStyles.filter { $0.color.w > 0 }.count
        #expect(highlighted >= 2)
        // Every highlighted triangle should map back to face index 0.
        for (idx, style) in body.triangleStyles.enumerated() where style.color.w > 0 {
            #expect(
                Int(body.faceIndices[idx]) == 0,
                "highlighted triangle \(idx) should belong to face 0, got \(body.faceIndices[idx])")
        }
    }

    @Test func t_faceSelection_doesNotProduceSeparateOverlayBody() throws {
        // The renderer-backed path replaces the cheap-route overlay; v0.6.1
        // should never spawn `ais.overlay.sel.*` bodies anymore.
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0)))
        #expect(ctx.bodies.count == 1)
        #expect(ctx.bodies.contains { $0.id.hasPrefix("ais.overlay.") } == false)
    }

    @Test func t_highlightColor_isSelectionColorWithFullAlpha() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.setHighlightStyle(
            HighlightStyle(
                selectionColor: SIMD3<Float>(0.2, 0.4, 0.6),
                hoverColor: .zero,
                outlineWidth: 1
            ))
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0)))

        let body = try #require(sourceBody(ctx, target: obj))
        let firstHighlight = body.triangleStyles.first { $0.color.w > 0 }
        let style = try #require(firstHighlight)
        #expect(abs(style.color.x - 0.2) < 1e-5)
        #expect(abs(style.color.y - 0.4) < 1e-5)
        #expect(abs(style.color.z - 0.6) < 1e-5)
        #expect(abs(style.color.w - 1.0) < 1e-5)
    }

    @Test func t_setHighlightStyle_updatesLiveStyles() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0)))
        ctx.setHighlightStyle(
            HighlightStyle(
                selectionColor: SIMD3<Float>(0, 1, 0),
                hoverColor: .zero,
                outlineWidth: 1
            ))
        let body = try #require(sourceBody(ctx, target: obj))
        let firstHighlight = body.triangleStyles.first { $0.color.w > 0 }
        let style = try #require(firstHighlight)
        #expect(abs(style.color.y - 1) < 1e-5)
        #expect(abs(style.color.x) < 1e-5)
    }

    @Test func t_clearSelection_clearsTriangleStyles() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0)))
        let preBody = try #require(sourceBody(ctx, target: obj))
        #expect(!preBody.triangleStyles.isEmpty)
        ctx.clearSelection()
        let postBody = try #require(sourceBody(ctx, target: obj))
        #expect(postBody.triangleStyles.isEmpty)
    }

    @Test func t_multiFaceSelection_unionsTrianglesOnSameBody() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0)))
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 1)))

        let body = try #require(sourceBody(ctx, target: obj))
        let highlightedFaces = Set(
            body.triangleStyles.indices.compactMap { idx in
                body.triangleStyles[idx].color.w > 0 ? Int(body.faceIndices[idx]) : nil
            }
        )
        #expect(highlightedFaces == [0, 1])
        #expect(ctx.bodies.count == 1)
    }

    @Test func t_facesAcrossTwoBodies_writeStylesOnEach() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let a = ctx.display(try makeBox())
        let b = ctx.display(try makeBox())
        ctx.select(.face(a, ref: SubShapeRef(shape: a.shape, ordinal: 0)))
        ctx.select(.face(b, ref: SubShapeRef(shape: b.shape, ordinal: 0)))

        let bodyA = try #require(sourceBody(ctx, target: a))
        let bodyB = try #require(sourceBody(ctx, target: b))
        #expect(bodyA.triangleStyles.contains { $0.color.w > 0 })
        #expect(bodyB.triangleStyles.contains { $0.color.w > 0 })
        // No overlay bodies leaked from the cheap-route era.
        #expect(ctx.bodies.contains { $0.id.hasPrefix("ais.overlay.") } == false)
    }

    @Test func t_remove_clearsHighlightForRemovedBody() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, ref: SubShapeRef(shape: obj.shape, ordinal: 0)))
        ctx.remove(obj)
        #expect(ctx.bodies.isEmpty)
        #expect(ctx.selection.isEmpty)
    }

    @Test func t_displayAfterSelection_doesNotResurrectOverlayBodies() throws {
        // In the cheap-route era we appended overlay bodies and had to keep
        // them trailing in `bodies`. v0.6.1 has no such bodies, so adding a
        // new shape after a selection just appends one more source body.
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let a = ctx.display(try makeBox())
        ctx.select(.face(a, ref: SubShapeRef(shape: a.shape, ordinal: 0)))
        _ = ctx.display(try makeBox())
        #expect(ctx.bodies.count == 2)
        #expect(ctx.bodies.contains { $0.id.hasPrefix("ais.overlay.") } == false)
    }

    // MARK: - Body-level highlight (unchanged path)

    @Test func t_bodySelection_pushesIDToViewport() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        ctx.select(.body(obj))
        let id = try #require(ctx.bodies.first?.id)
        #expect(ctx.viewport.selectedBodyIDs == [id])
    }

    @Test func t_clearSelection_clearsViewportBodyIDs() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        ctx.select(.body(obj))
        ctx.clearSelection()
        #expect(ctx.viewport.selectedBodyIDs.isEmpty)
    }

    @Test func t_bodySelection_doesNotPopulateTriangleStyles() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        ctx.select(.body(obj))
        let body = try #require(sourceBody(ctx, target: obj))
        #expect(
            body.triangleStyles.isEmpty,
            "body-level selection routes through viewport.selectedBodyIDs only")
    }
}
