import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

@MainActor
@Suite("ManipulatorWidget rotate")
struct ManipulatorRotateTests {

    private static let aspect: Float = 16.0 / 9.0
    /// A true (1,1,1)-direction isometric camera. `CameraState.isometric` looks
    /// from (0, +Y, +Z), which makes the X-ring's plane edge-on to the view,
    /// not useful for hit-test round-trips on the X axis.
    private static let camera: CameraState = {
        let q = simd_quaternion(SIMD3<Float>(0, 0, 1), simd_normalize(SIMD3<Float>(1, 1, 1)))
        return CameraState(rotation: q, distance: 10, pivot: .zero)
    }()

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> Shape {
        try #require(Shape.box(width: 2, height: 2, depth: 2))
    }

    private func vpMatrix() -> simd_float4x4 {
        Self.camera.projectionMatrix(aspectRatio: Self.aspect) * Self.camera.viewMatrix
    }

    private func ndc(of worldPoint: SIMD3<Float>) throws -> SIMD2<Float> {
        let ndc3 = try #require(
            ProjectionUtility.worldToNDC(point: worldPoint, vpMatrix: vpMatrix()))
        return SIMD2<Float>(ndc3.x, ndc3.y)
    }

    private func widgetBodies(_ ctx: InteractiveContext, target: InteractiveObject)
        -> [ViewportBody]
    {
        let prefix = "ais.widget.\(target.id.uuidString)."
        return ctx.bodies.filter { $0.id.hasPrefix(prefix) }
    }

    /// Build a target whose pivot is the world origin (centered box).
    private func makeRotateContext() throws -> (
        InteractiveContext, InteractiveObject, ManipulatorWidget
    ) {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj, mode: .rotate)
        widget.size = 2.0
        widget.rotateRingRadius = 1.0
        widget.rotateTubeRadius = 0.04
        widget.install(in: ctx)
        return (ctx, obj, widget)
    }

    /// Project a world point lying on the ring of the given axis (radius 1.0)
    /// at the given angle within the ring plane to NDC.
    private func ringPointNDC(axis: ManipulatorWidget.Axis, angle: Float) throws -> SIMD2<Float> {
        let (u, v): (SIMD3<Float>, SIMD3<Float>)
        switch axis {
        case .x:
            u = SIMD3<Float>(0, 1, 0)
            v = SIMD3<Float>(0, 0, 1)
        case .y:
            u = SIMD3<Float>(0, 0, 1)
            v = SIMD3<Float>(1, 0, 0)
        case .z:
            u = SIMD3<Float>(1, 0, 0)
            v = SIMD3<Float>(0, 1, 0)
        }
        let p = u * cos(angle) + v * sin(angle)
        return try ndc(of: p)
    }

    // MARK: - Geometry / install

    @Test func t_install_addsThreeRingBodies() throws {
        let (ctx, obj, widget) = try makeRotateContext()
        let arrows = widgetBodies(ctx, target: obj)
        #expect(arrows.count == 3)
        #expect(arrows.allSatisfy { $0.renderLayer == .overlay })
        #expect(arrows.allSatisfy { $0.pickLayer == .widget })
        #expect(widget.isInstalled)
    }

    @Test func t_ringBodies_haveTriangles() throws {
        let (ctx, obj, _) = try makeRotateContext()
        for body in widgetBodies(ctx, target: obj) {
            #expect(body.indices.count > 0, "ring \(body.id) should have triangles")
            #expect(body.indices.count % 3 == 0)
        }
    }

    @Test func t_uninstall_removesRings() throws {
        let (ctx, obj, widget) = try makeRotateContext()
        widget.uninstall()
        #expect(widgetBodies(ctx, target: obj).isEmpty)
    }

    // MARK: - Hit test

    @Test func t_hitTest_onRingPoint_returnsThatAxis() throws {
        let (_, _, widget) = try makeRotateContext()
        // Sample a point on each ring at a non-degenerate angle
        // (avoid points where the ring projects orthogonally to the view).
        for axis in ManipulatorWidget.Axis.allCases {
            let p = try ringPointNDC(axis: axis, angle: .pi / 4)
            let hit = widget.hitTest(ndc: p, camera: Self.camera, aspect: Self.aspect)
            #expect(
                hit == axis, "axis \(axis) ring expected to hit, got \(String(describing: hit))")
        }
    }

    @Test func t_hitTest_atPivot_isNotARingHit() throws {
        let (_, _, widget) = try makeRotateContext()
        // Pivot projects to the center of the gizmo; far inside any ring, no hit.
        let p = try ndc(of: .zero)
        #expect(widget.hitTest(ndc: p, camera: Self.camera, aspect: Self.aspect) == nil)
    }

    @Test func t_hitTest_offRing_returnsNil() throws {
        let (_, _, widget) = try makeRotateContext()
        // A point well outside any ring, in screen-corner space.
        let hit = widget.hitTest(
            ndc: SIMD2<Float>(0.95, -0.95), camera: Self.camera, aspect: Self.aspect)
        #expect(hit == nil)
    }

    // MARK: - Drag

    @Test func t_drag_aroundZ_rotatesTargetAroundPivot() throws {
        let (ctx, obj, widget) = try makeRotateContext()

        let startNDC = try ringPointNDC(axis: .z, angle: 0)  // (1, 0, 0)
        // (0, 1, 0): quarter turn ccw about +Z.
        let endNDC = try ringPointNDC(axis: .z, angle: .pi / 2)

        widget.beginDrag(axis: .z, ndc: startNDC, camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(ndc: endNDC, camera: Self.camera, aspect: Self.aspect)

        // Rotation matrix should be approximately R_z(π/2):
        // [[0,-1,0,0],[1,0,0,0],[0,0,1,0],[0,0,0,1]] (column-major: col0=(0,1,0,0), col1=(-1,0,0,0))
        let m = widget.transform
        #expect(abs(m.columns.0.x - 0) < 1e-3, "col0.x ≈ 0, got \(m.columns.0.x)")
        #expect(abs(m.columns.0.y - 1) < 1e-3, "col0.y ≈ 1, got \(m.columns.0.y)")
        #expect(abs(m.columns.1.x + 1) < 1e-3, "col1.x ≈ -1, got \(m.columns.1.x)")
        #expect(abs(m.columns.1.y - 0) < 1e-3, "col1.y ≈ 0, got \(m.columns.1.y)")
        #expect(abs(m.columns.2.z - 1) < 1e-3)

        // Live target body transform composed with pre-install (identity) should match.
        let live = ctx.sourceBody(for: obj)?.transform ?? .init()
        #expect(abs(live.columns.0.y - 1) < 1e-3)
    }

    @Test func t_snapRotateDeg_roundsAngleToStep() throws {
        let (_, _, widget) = try makeRotateContext()
        widget.snapRotateDeg = 15

        let startNDC = try ringPointNDC(axis: .z, angle: 0)
        // 22° between snap steps 15° and 30°: should round to 30° (closer than 15°).
        let endNDC = try ringPointNDC(axis: .z, angle: 22 * .pi / 180)

        widget.beginDrag(axis: .z, ndc: startNDC, camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(ndc: endNDC, camera: Self.camera, aspect: Self.aspect)

        // Recover the angle from R_z: angle = atan2(R[1,0], R[0,0]).
        let m = widget.transform
        let angle = atan2(m.columns.0.y, m.columns.0.x)
        let snapped = (angle / (15 * .pi / 180)).rounded() * (15 * .pi / 180)
        #expect(
            abs(angle - snapped) < 1e-4,
            "snapped rotation should land on a 15° multiple, got \(angle * 180 / .pi)°")
    }

    @Test func t_rotate_translatedPivot_keepsTargetCenteredAtPivot() throws {
        // Build a context where the target box is offset so its pivot ≠ origin.
        // Shape.box(origin:width:height:depth:) is corner-based, so a box at
        // origin (4, -1, -1) with extents (2, 2, 2) has centroid (5, 0, 0).
        let ctx = makeContext()
        let shape = try #require(
            Shape.box(origin: SIMD3<Double>(4, -1, -1), width: 2, height: 2, depth: 2))
        let obj = ctx.display(shape)
        let widget = ManipulatorWidget(target: obj, mode: .rotate)
        widget.size = 2.0
        widget.rotateRingRadius = 1.0
        widget.install(in: ctx)

        // Sample the +Z ring around the actual pivot at (5, 0, 0).
        let pivot = SIMD3<Float>(5, 0, 0)
        let startWorld = pivot + SIMD3<Float>(1, 0, 0)
        let endWorld = pivot + SIMD3<Float>(0, 1, 0)
        let startNDC = try ndc(of: startWorld)
        let endNDC = try ndc(of: endWorld)

        widget.beginDrag(axis: .z, ndc: startNDC, camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(ndc: endNDC, camera: Self.camera, aspect: Self.aspect)

        // After R(Z, π/2) about pivot (5, 0, 0), the pivot itself stays at (5, 0, 0).
        // Verify by applying widget.transform to (5, 0, 0, 1).
        let p4 = SIMD4<Float>(5, 0, 0, 1)
        let result = widget.transform * p4
        #expect(abs(result.x - 5) < 1e-3, "pivot x preserved, got \(result.x)")
        #expect(abs(result.y - 0) < 1e-3, "pivot y preserved, got \(result.y)")
        #expect(abs(result.z - 0) < 1e-3, "pivot z preserved, got \(result.z)")
    }

    @Test func t_onChange_firesDuringRotateDrag() throws {
        let (_, _, widget) = try makeRotateContext()
        var count = 0
        widget.onChange = { _ in count += 1 }
        widget.beginDrag(
            axis: .z, ndc: try ringPointNDC(axis: .z, angle: 0), camera: Self.camera,
            aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ringPointNDC(axis: .z, angle: .pi / 6), camera: Self.camera,
            aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ringPointNDC(axis: .z, angle: .pi / 3), camera: Self.camera,
            aspect: Self.aspect)
        #expect(count == 2)
    }

    @Test func t_onCommit_firesOnEndRotateDragCommit() throws {
        let (_, _, widget) = try makeRotateContext()
        var commits: [simd_float4x4] = []
        widget.onCommit = { commits.append($0) }
        widget.beginDrag(
            axis: .x, ndc: try ringPointNDC(axis: .x, angle: 0), camera: Self.camera,
            aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ringPointNDC(axis: .x, angle: .pi / 4), camera: Self.camera,
            aspect: Self.aspect)
        widget.endDrag(commit: true)
        #expect(commits.count == 1)
    }

    @Test func t_uninstall_restoresTargetBodyTransformAfterRotation() throws {
        let (ctx, obj, widget) = try makeRotateContext()
        widget.beginDrag(
            axis: .z, ndc: try ringPointNDC(axis: .z, angle: 0), camera: Self.camera,
            aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ringPointNDC(axis: .z, angle: .pi / 2), camera: Self.camera,
            aspect: Self.aspect)
        widget.endDrag(commit: true)
        widget.uninstall()
        let restored = ctx.sourceBody(for: obj)?.transform ?? .init()
        #expect(
            restored == matrix_identity_float4x4,
            "uninstall must restore pre-install target transform")
    }

    @Test func t_widgetPicks_doNotPolluteUserSelectionStream() throws {
        let (ctx, obj, widget) = try makeRotateContext()
        ctx.selectionMode = [.body]
        let ringID = widget.bodyID(for: .x)
        let pick = try #require(PickResult(rawValue: 0, indexMap: [0: ringID]))
        ctx.handlePick(pick)
        #expect(ctx.selection.isEmpty, "rotate handle pick must not produce user selection")
        _ = obj
    }
}
