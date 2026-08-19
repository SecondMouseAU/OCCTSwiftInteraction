import OCCTSwift
import OCCTSwiftViewport
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftAIS

@MainActor
@Suite("ManipulatorGestureCoordinator")
struct ManipulatorGestureTests {

    private static let viewSize = CGSize(width: 1920, height: 1080)

    private func makeContext() -> InteractiveContext {
        // The default ViewportController state (rotation = identity, distance = 10)
        // looks straight down -Z at the origin: fine for X-axis hit-tests.
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> OCCTSwift.Shape {
        try #require(OCCTSwift.Shape.box(width: 2, height: 2, depth: 2))
    }

    private func point(forNDC ndc: SIMD2<Float>) -> CGPoint {
        let x = (CGFloat(ndc.x) + 1) * 0.5 * Self.viewSize.width
        let y = (1 - (CGFloat(ndc.y) + 1) * 0.5) * Self.viewSize.height
        return CGPoint(x: x, y: y)
    }

    /// NDC of `worldPoint` under the context's *current* camera + aspect: the
    /// coordinator reads these from the same source at gesture time.
    private func ndc(of worldPoint: SIMD3<Float>, in ctx: InteractiveContext) throws -> SIMD2<Float>
    {
        let cam = ctx.viewport.cameraState
        let aspect = ctx.viewport.lastAspectRatio
        let vp = cam.projectionMatrix(aspectRatio: aspect) * cam.viewMatrix
        let n = try #require(ProjectionUtility.worldToNDC(point: worldPoint, vpMatrix: vp))
        return SIMD2<Float>(n.x, n.y)
    }

    // MARK: - ndcFromPoint helper

    @Test func t_ndcFromPoint_centerIsZero() {
        let center = CGPoint(x: 960, y: 540)
        let n = ndcFromPoint(center, in: Self.viewSize)
        #expect(abs(n.x) < 1e-5)
        #expect(abs(n.y) < 1e-5)
    }

    @Test func t_ndcFromPoint_topLeftIsMinusOnePlusOne() {
        let n = ndcFromPoint(CGPoint(x: 0, y: 0), in: Self.viewSize)
        #expect(abs(n.x - (-1)) < 1e-5)
        #expect(abs(n.y - 1) < 1e-5)
    }

    @Test func t_ndcFromPoint_bottomRightIsPlusOneMinusOne() {
        let n = ndcFromPoint(CGPoint(x: 1920, y: 1080), in: Self.viewSize)
        #expect(abs(n.x - 1) < 1e-5)
        #expect(abs(n.y - (-1)) < 1e-5)
    }

    @Test func t_ndcFromPoint_zeroSize_returnsZero() {
        let n = ndcFromPoint(CGPoint(x: 100, y: 100), in: .zero)
        #expect(n == .zero)
    }

    // MARK: - Coordinator dispatch

    @Test func t_touchOnHandle_entersWidgetMode() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)
        let coord = ManipulatorGestureCoordinator(widget: widget)

        // A NDC point on the X-axis arrow (midpoint of the shaft).
        // The arrow length is 2.0, so its midpoint is at world (1, 0, 0).
        let n = try ndc(of: SIMD3<Float>(1, 0, 0), in: ctx)
        let p = point(forNDC: n)
        coord.onChanged(location: p, translation: CGSize.zero, in: Self.viewSize)

        #expect(coord.mode == ManipulatorGestureCoordinator.Mode.widget(.x))
        #expect(widget.activeAxis == ManipulatorWidget.Axis.x)
    }

    @Test func t_touchOffHandle_entersCameraMode() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)
        let coord = ManipulatorGestureCoordinator(widget: widget)

        // Far corner of NDC, well clear of any arrow.
        let p = point(forNDC: SIMD2<Float>(0.95, -0.95))
        coord.onChanged(location: p, translation: CGSize.zero, in: Self.viewSize)

        #expect(coord.mode == ManipulatorGestureCoordinator.Mode.camera)
        #expect(widget.activeAxis == nil)
    }

    @Test func t_widgetMode_continuingDragForwardsToWidget() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)
        let coord = ManipulatorGestureCoordinator(widget: widget)

        // Start unambiguously on the X arrow shaft: at the origin all three
        // arrows overlap in NDC and depth-ordering picks the closest-to-camera.
        let startPoint = point(forNDC: try ndc(of: SIMD3<Float>(1, 0, 0), in: ctx))
        let endPoint = point(forNDC: try ndc(of: SIMD3<Float>(1.5, 0, 0), in: ctx))

        // First call decides .widget(.x); second forwards updateDrag.
        coord.onChanged(location: startPoint, translation: CGSize.zero, in: Self.viewSize)
        coord.onChanged(
            location: endPoint, translation: CGSize(width: 50, height: 0), in: Self.viewSize)

        #expect(coord.mode == ManipulatorGestureCoordinator.Mode.widget(.x))
        #expect(widget.transform.columns.3.x > 0.1, "X translation should grow as drag progresses")
    }

    @Test func t_cameraMode_forwardsOrbitToController() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)
        let coord = ManipulatorGestureCoordinator(widget: widget)

        let initialState = ctx.viewport.cameraState

        // Drag starts off-handle, then continues: coordinator should call orbit.
        let p0 = point(forNDC: SIMD2<Float>(0.95, -0.95))
        coord.onChanged(location: p0, translation: CGSize.zero, in: Self.viewSize)
        coord.onChanged(
            location: CGPoint(x: 1900, y: 100), translation: CGSize(width: 100, height: -50),
            in: Self.viewSize)
        coord.onChanged(
            location: CGPoint(x: 1880, y: 120), translation: CGSize(width: 80, height: -30),
            in: Self.viewSize)

        // Camera state should have shifted (orbit was forwarded).
        #expect(
            ctx.viewport.cameraState.rotation != initialState.rotation,
            "controller.handleOrbit should have rotated the camera")
    }

    @Test func t_endDrag_widgetMode_firesCommitAndResetsToIdle() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)
        var commits = 0
        widget.onCommit = { (_: simd_float4x4) in commits += 1 }

        let coord = ManipulatorGestureCoordinator(widget: widget)
        let p = point(forNDC: try ndc(of: SIMD3<Float>(1, 0, 0), in: ctx))
        coord.onChanged(location: p, translation: CGSize.zero, in: Self.viewSize)
        coord.onEnded()

        #expect(commits == 1)
        #expect(coord.mode == ManipulatorGestureCoordinator.Mode.idle)
        #expect(widget.activeAxis == nil)
    }

    @Test func t_endDrag_cameraMode_resetsToIdleWithoutCommit() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)
        var commits = 0
        widget.onCommit = { (_: simd_float4x4) in commits += 1 }

        let coord = ManipulatorGestureCoordinator(widget: widget)
        let p = point(forNDC: SIMD2<Float>(0.95, -0.95))
        coord.onChanged(location: p, translation: CGSize.zero, in: Self.viewSize)
        coord.onEnded()

        #expect(commits == 0)
        #expect(coord.mode == ManipulatorGestureCoordinator.Mode.idle)
    }

    @Test func t_widgetWithoutContext_isHandledGracefully() {
        // A widget that was never installed has nil context: the coordinator
        // should bail without crashing.
        let shape = OCCTSwift.Shape.box(width: 1, height: 1, depth: 1)!
        let obj = InteractiveObject(shape: shape)
        let widget = ManipulatorWidget(target: obj)
        let coord = ManipulatorGestureCoordinator(widget: widget)
        coord.onChanged(location: CGPoint(x: 0, y: 0), translation: CGSize.zero, in: Self.viewSize)
        coord.onEnded()
        #expect(coord.mode == ManipulatorGestureCoordinator.Mode.idle)
    }
}
