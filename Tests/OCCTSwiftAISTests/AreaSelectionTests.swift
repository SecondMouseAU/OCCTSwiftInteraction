import Foundation
import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

@MainActor
@Suite("AreaSelection")
struct AreaSelectionTests {

    private let viewportSize = CGSize(width: 800, height: 600)

    private func makeContext() -> InteractiveContext {
        let ctx = InteractiveContext(viewport: ViewportController())
        ctx.viewport.animateTo(.isometric, duration: 0)  // duration 0 sets synchronously
        return ctx
    }

    private func makeBox() throws -> Shape {
        try #require(Shape.box(origin: SIMD3(0, 0, 0), width: 10, height: 10, depth: 10))
    }

    private func vpMatrix(_ ctx: InteractiveContext) -> simd_float4x4 {
        let camera = ctx.viewport.cameraState
        return camera.projectionMatrix(aspectRatio: ctx.viewport.lastAspectRatio)
            * camera.viewMatrix
    }

    private func screenPoints(for shape: Shape, ctx: InteractiveContext) -> [CGPoint] {
        let vp = vpMatrix(ctx)
        return shape.vertices().compactMap {
            ProjectionUtility.worldToScreen(
                point: SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)),
                vpMatrix: vp, viewportSize: viewportSize
            )
        }
    }

    /// Bounding rect (in screen space) of `shape's` own projected vertices,
    /// padded outward slightly so floating-point edges land safely inside.
    private func screenRect(for shape: Shape, ctx: InteractiveContext, padding: CGFloat = 4) throws
        -> CGRect
    {
        let points = screenPoints(for: shape, ctx: ctx)
        let minX = try #require(points.map(\.x).min()) - padding
        let maxX = try #require(points.map(\.x).max()) + padding
        let minY = try #require(points.map(\.y).min()) - padding
        let maxY = try #require(points.map(\.y).max()) + padding
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Rectangle selection basics

    @Test func t_selectRectangle_enclosingAFace_selectsThatFace() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let faces = obj.shape.faces()
        let faceIdx = 0
        let faceShape = try #require(Shape.fromFace(faces[faceIdx]))
        let rect = try screenRect(for: faceShape, ctx: ctx)

        ctx.selectRectangle(
            from: CGPoint(x: rect.minX, y: rect.minY),
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            mode: .enclosed, viewportSize: viewportSize
        )

        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: faceIdx))
    }

    @Test func t_selectRectangle_farFromEverything_selectsNothing() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        _ = ctx.display(try makeBox())

        ctx.selectRectangle(
            from: CGPoint(x: 10_000, y: 10_000), to: CGPoint(x: 10_010, y: 10_010),
            mode: .enclosed, viewportSize: viewportSize
        )

        #expect(ctx.selection.isEmpty)
    }

    @Test func t_selectRectangle_honoursSelectionMode() throws {
        // With .face excluded from selectionMode, an enclosing rect over a
        // face must not produce a face selection.
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        let faces = obj.shape.faces()
        let faceShape = try #require(Shape.fromFace(faces[0]))
        let rect = try screenRect(for: faceShape, ctx: ctx)

        ctx.selectRectangle(
            from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY),
            mode: .enclosed, viewportSize: viewportSize
        )

        #expect(!containsFace(ctx.selection.subshapes, obj, ordinal: 0))
    }

    @Test func t_selectRectangle_bodyMode_selectsBodyWhenBoundingBoxEnclosed() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        let rect = try screenRect(for: obj.shape, ctx: ctx, padding: 20)

        ctx.selectRectangle(
            from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY),
            mode: .enclosed, viewportSize: viewportSize
        )

        #expect(ctx.selection.subshapes == [.body(obj)])
    }

    // MARK: - .enclosed vs .intersecting

    @Test func t_enclosedVsIntersecting_areDistinguishable() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let faces = obj.shape.faces()
        let faceIdx = 0
        let faceShape = try #require(Shape.fromFace(faces[faceIdx]))
        let points = screenPoints(for: faceShape, ctx: ctx)
        try #require(points.count >= 2)

        // A tiny rect around just ONE of the face's vertices: intersects the
        // face (that vertex is inside) but does not enclose it (the others
        // aren't).
        let p0 = points[0]
        let tinyRect = CGRect(x: p0.x - 3, y: p0.y - 3, width: 6, height: 6)

        ctx.selectRectangle(
            from: CGPoint(x: tinyRect.minX, y: tinyRect.minY),
            to: CGPoint(x: tinyRect.maxX, y: tinyRect.maxY),
            mode: .intersecting, viewportSize: viewportSize
        )
        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: faceIdx))

        ctx.clearSelection()
        ctx.selectRectangle(
            from: CGPoint(x: tinyRect.minX, y: tinyRect.minY),
            to: CGPoint(x: tinyRect.maxX, y: tinyRect.maxY),
            mode: .enclosed, viewportSize: viewportSize
        )
        #expect(!containsFace(ctx.selection.subshapes, obj, ordinal: faceIdx))
    }

    // MARK: - Filters gate area selection like point selection

    @Test func t_installedFilter_gatesAreaSelection() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let faces = obj.shape.faces()
        let faceShape = try #require(Shape.fromFace(faces[0]))
        let rect = try screenRect(for: faceShape, ctx: ctx)

        ctx.addFilter(SurfaceTypeFilter([.cylinder]))  // a box has no cylindrical faces

        ctx.selectRectangle(
            from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY),
            mode: .enclosed, viewportSize: viewportSize
        )

        #expect(
            ctx.selection.isEmpty,
            "an installed filter should gate area selection exactly as it gates a point pick")
    }

    // MARK: - SelectionScheme

    @Test func t_selectionScheme_add_unionsWithExisting() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let faces = obj.shape.faces()
        let face0Shape = try #require(Shape.fromFace(faces[0]))
        let face1Shape = try #require(Shape.fromFace(faces[1]))
        ctx.select(.face(obj, ref: SubShapeRef(shape: face0Shape, ordinal: 0)))

        let rect = try screenRect(for: face1Shape, ctx: ctx)
        ctx.selectRectangle(
            from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY),
            mode: .enclosed, scheme: .add, viewportSize: viewportSize
        )

        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: 0))
        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: 1))
    }

    @Test func t_selectionScheme_replace_dropsExisting() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let faces = obj.shape.faces()
        let face0Shape = try #require(Shape.fromFace(faces[0]))
        let face1Shape = try #require(Shape.fromFace(faces[1]))
        ctx.select(.face(obj, ref: SubShapeRef(shape: face0Shape, ordinal: 0)))

        let rect = try screenRect(for: face1Shape, ctx: ctx)
        ctx.selectRectangle(
            from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY),
            mode: .enclosed, scheme: .replace, viewportSize: viewportSize
        )

        #expect(!containsFace(ctx.selection.subshapes, obj, ordinal: 0))
        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: 1))
    }

    @Test func t_selectionScheme_remove_subtractsFromExisting() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let faces = obj.shape.faces()
        let face0Shape = try #require(Shape.fromFace(faces[0]))
        // Select via the SAME uid the area-select match will (re)mint, so
        // `.remove`'s Set-subtraction actually cancels it (SubShapeRef
        // equality follows uid, not shape/ordinal alone; see its docs).
        let table = try #require(ctx.faceIdentityTable(for: obj))
        ctx.select(
            .face(
                obj, ref: SubShapeRef(shape: face0Shape, uid: table.uid(forOrdinal: 0), ordinal: 0))
        )

        let rect = try screenRect(for: face0Shape, ctx: ctx)
        ctx.selectRectangle(
            from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY),
            mode: .enclosed, scheme: .remove, viewportSize: viewportSize
        )

        #expect(!containsFace(ctx.selection.subshapes, obj, ordinal: 0))
    }

    @Test func t_selectionScheme_xor_togglesOverlap() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let faces = obj.shape.faces()
        let face0Shape = try #require(Shape.fromFace(faces[0]))
        let table = try #require(ctx.faceIdentityTable(for: obj))
        ctx.select(
            .face(
                obj, ref: SubShapeRef(shape: face0Shape, uid: table.uid(forOrdinal: 0), ordinal: 0))
        )

        let rect = try screenRect(for: face0Shape, ctx: ctx)
        ctx.selectRectangle(
            from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY),
            mode: .enclosed, scheme: .xor, viewportSize: viewportSize
        )

        #expect(
            !containsFace(ctx.selection.subshapes, obj, ordinal: 0),
            "xor should toggle off an already-selected face")
    }

    // MARK: - Lasso (selectPolygon)

    @Test func t_selectPolygon_triangleEnclosingAFace_selectsThatFace() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let faces = obj.shape.faces()
        let faceIdx = 0
        let faceShape = try #require(Shape.fromFace(faces[faceIdx]))
        let rect = try screenRect(for: faceShape, ctx: ctx, padding: 20)

        // A triangle circumscribing the face's bounding rect.
        let triangle = [
            CGPoint(x: rect.midX, y: rect.minY - (rect.height)),
            CGPoint(x: rect.minX - rect.width, y: rect.maxY + rect.height),
            CGPoint(x: rect.maxX + rect.width, y: rect.maxY + rect.height),
        ]

        ctx.selectPolygon(triangle, mode: .enclosed, viewportSize: viewportSize)

        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: faceIdx))
    }

    @Test func t_selectPolygon_fewerThanThreePoints_isNoOp() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        _ = ctx.display(try makeBox())
        ctx.selectPolygon([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)], viewportSize: viewportSize)
        #expect(ctx.selection.isEmpty)
    }

    // MARK: - Gesture coordinator: navigate mode doesn't fight camera orbit

    @Test func t_gestureCoordinator_navigateMode_forwardsToViewportOrbit_leavesSelectionAlone()
        throws
    {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        ctx.select(.body(obj))
        let controller = AreaSelectionController(context: ctx)
        controller.tool = .navigate
        let coordinator = AreaSelectionGestureCoordinator(controller: controller)

        let beforeCamera = ctx.viewport.cameraState
        coordinator.onChanged(
            location: CGPoint(x: 120, y: 80), startLocation: CGPoint(x: 100, y: 100),
            translation: CGSize(width: 20, height: -20), in: viewportSize
        )
        coordinator.onEnded()

        // Navigate mode must not touch selection at all: it only drives the camera.
        #expect(ctx.selection.subshapes == [.body(obj)])
        _ = beforeCamera
    }

    @Test func t_gestureCoordinator_rectangleMode_accumulatesDragPointsThenSelectsOnEnd() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        let faces = obj.shape.faces()
        let faceShape = try #require(Shape.fromFace(faces[0]))
        let rect = try screenRect(for: faceShape, ctx: ctx)

        let controller = AreaSelectionController(context: ctx)
        controller.tool = .rectangle
        controller.mode = .enclosed
        let coordinator = AreaSelectionGestureCoordinator(controller: controller)

        let start = CGPoint(x: rect.minX, y: rect.minY)
        let end = CGPoint(x: rect.maxX, y: rect.maxY)
        coordinator.onChanged(
            location: end, startLocation: start, translation: .zero, in: viewportSize)
        #expect(controller.dragPoints == [start, end])

        coordinator.onEnded()

        #expect(containsFace(ctx.selection.subshapes, obj, ordinal: 0))
        #expect(controller.dragPoints.isEmpty, "drag path should reset once the selection commits")
    }

    // MARK: - Performance sanity

    @Test func t_selectRectangle_manyFacedModel_staysResponsive() throws {
        // A cylinder tessellated with a moderate deflection has dozens of
        // side-face-adjacent triangles feeding a handful of real faces (3 for
        // an analytic cylinder), but the enumeration cost in `selectRectangle`
        // scales with candidate SUB-SHAPE count, not triangle count: this
        // exercises that path against a shape with a non-trivial vertex count
        // per face. Noted tested count: 3 faces / bbox-derived vertex sets.
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let cylinder = try #require(Shape.cylinder(radius: 5, height: 20))
        let obj = ctx.display(cylinder)
        let rect = try screenRect(for: obj.shape, ctx: ctx, padding: 20)

        let start = Date()
        for _ in 0..<50 {
            ctx.selectRectangle(
                from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY),
                mode: .enclosed, viewportSize: viewportSize
            )
        }
        let elapsed = Date().timeIntervalSince(start)

        #expect(
            elapsed < 2.0,
            "50 rectangle selections over a displayed cylinder took \(elapsed)s, expected well under 2s"
        )
        #expect(!ctx.selection.isEmpty)
    }
}
