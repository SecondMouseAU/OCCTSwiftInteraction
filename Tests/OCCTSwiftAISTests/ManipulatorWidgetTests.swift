import OCCTSwift
import OCCTSwiftViewport
import Testing
import simd

@testable import OCCTSwiftAIS

@MainActor
@Suite("ManipulatorWidget")
struct ManipulatorWidgetTests {

    private static let aspect: Float = 16.0 / 9.0
    private static let camera: CameraState = .isometric

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> Shape {
        try #require(Shape.box(width: 2, height: 2, depth: 2))
    }

    private func vpMatrix() -> simd_float4x4 {
        Self.camera.projectionMatrix(aspectRatio: Self.aspect) * Self.camera.viewMatrix
    }

    /// Project a world point to NDC xy using the suite's camera.
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

    // MARK: - Install / uninstall

    @Test func t_install_addsThreeAxisBodies() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.install(in: ctx)

        let arrows = widgetBodies(ctx, target: obj)
        #expect(arrows.count == 3)
        let suffixes = Set(arrows.map { String($0.id.split(separator: ".").last!) })
        #expect(suffixes == ["x", "y", "z"])
        #expect(widget.isInstalled)
    }

    @Test func t_install_isIdempotent() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.install(in: ctx)
        widget.install(in: ctx)
        #expect(widgetBodies(ctx, target: obj).count == 3)
    }

    @Test func t_uninstall_removesAllArrowBodies() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.install(in: ctx)
        widget.uninstall()
        #expect(widgetBodies(ctx, target: obj).isEmpty)
        #expect(widget.isInstalled == false)
    }

    @Test func t_widgetBodies_doNotPolluteUserSelectionStream() throws {
        // A pick that lands on a widget body must not produce any selection.
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.install(in: ctx)

        let widgetBodyID = widget.bodyID(for: .x)
        let pick = try #require(PickResult(rawValue: 0, indexMap: [0: widgetBodyID]))
        ctx.handlePick(pick)

        #expect(ctx.selection.isEmpty)
    }

    // MARK: - Hit test

    @Test func t_hitTest_onAxisShaft_returnsThatAxis() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)

        // Sample the middle of each arrow's centerline.
        for axis in ManipulatorWidget.Axis.allCases {
            let midpoint = axis.direction * widget.size * 0.5
            let p = try ndc(of: midpoint)
            let hit = widget.hitTest(ndc: p, camera: Self.camera, aspect: Self.aspect)
            #expect(hit == axis, "axis \(axis) expected to hit, got \(String(describing: hit))")
        }
    }

    @Test func t_hitTest_farFromAnyHandle_returnsNil() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 1.0
        widget.install(in: ctx)
        let hit = widget.hitTest(
            ndc: SIMD2<Float>(0.95, -0.95), camera: Self.camera, aspect: Self.aspect)
        #expect(hit == nil)
    }

    @Test func t_hitTest_beforeInstall_stillWorksAtIdentityPivot() throws {
        // hitTest should not require install: it operates on the running pivot+transform.
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        let p = try ndc(of: SIMD3<Float>(1.0, 0, 0))
        let hit = widget.hitTest(ndc: p, camera: Self.camera, aspect: Self.aspect)
        #expect(hit == .x)
        _ = ctx
    }

    // MARK: - Drag

    @Test func t_drag_alongXAxis_producesXTranslation() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)

        // Round-trip: pick at origin (axis-line through origin), drag pick to where
        // world (0.5, 0, 0) projects → expected x translation ≈ 0.5.
        let startNDC = try ndc(of: .zero)
        let endNDC = try ndc(of: SIMD3<Float>(0.5, 0, 0))

        widget.beginDrag(axis: .x, ndc: startNDC, camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(ndc: endNDC, camera: Self.camera, aspect: Self.aspect)

        let dx = widget.transform.columns.3.x
        let dy = widget.transform.columns.3.y
        let dz = widget.transform.columns.3.z
        #expect(abs(dx - 0.5) < 1e-3, "expected ~0.5 along X, got \(dx)")
        #expect(abs(dy) < 1e-3)
        #expect(abs(dz) < 1e-3)
    }

    @Test func t_drag_arrowFollowsTransform() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)

        let initialT = arrowTransform(in: ctx, target: obj, axis: .x)
        let startNDC = try ndc(of: .zero)
        let endNDC = try ndc(of: SIMD3<Float>(1, 0, 0))
        widget.beginDrag(axis: .x, ndc: startNDC, camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(ndc: endNDC, camera: Self.camera, aspect: Self.aspect)

        let movedT = arrowTransform(in: ctx, target: obj, axis: .x)
        let initialTx = initialT?.columns.3.x ?? 0
        let movedTx = movedT?.columns.3.x ?? 0
        #expect(
            movedTx > initialTx + 0.5,
            "expected the X arrow's body.transform to translate by ~drag delta on +X")
    }

    @Test func t_snapTranslate_roundsDeltaToStep() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.snapTranslate = 0.25
        widget.install(in: ctx)

        let startNDC = try ndc(of: .zero)
        let endNDC = try ndc(of: SIMD3<Float>(0.7, 0, 0))  // closer to 0.75 than 0.5 with step 0.25

        widget.beginDrag(axis: .x, ndc: startNDC, camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(ndc: endNDC, camera: Self.camera, aspect: Self.aspect)

        let dx = widget.transform.columns.3.x
        let snapped = (dx / 0.25).rounded() * 0.25
        #expect(abs(dx - snapped) < 1e-4, "snap should land on a multiple of 0.25, got \(dx)")
        #expect([0.5, 0.75].contains { abs(dx - $0) < 1e-3 })
    }

    @Test func t_onChange_firesDuringDrag() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)

        var changeCount = 0
        widget.onChange = { _ in changeCount += 1 }

        let startNDC = try ndc(of: .zero)
        widget.beginDrag(axis: .x, ndc: startNDC, camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ndc(of: SIMD3<Float>(0.3, 0, 0)), camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ndc(of: SIMD3<Float>(0.6, 0, 0)), camera: Self.camera, aspect: Self.aspect)
        #expect(changeCount == 2)
    }

    @Test func t_onCommit_firesOnEndDragCommit() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)

        var commits: [simd_float4x4] = []
        widget.onCommit = { commits.append($0) }

        widget.beginDrag(
            axis: .y, ndc: try ndc(of: .zero), camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ndc(of: SIMD3<Float>(0, 0.4, 0)), camera: Self.camera, aspect: Self.aspect)
        widget.endDrag(commit: true)

        #expect(commits.count == 1)
        if let last = commits.last {
            #expect(abs(last.columns.3.y - 0.4) < 1e-3)
        }
    }

    @Test func t_endDragWithoutCommit_doesNotFireCommit() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)

        var commitCount = 0
        widget.onCommit = { _ in commitCount += 1 }

        widget.beginDrag(
            axis: .x, ndc: try ndc(of: .zero), camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ndc(of: SIMD3<Float>(0.4, 0, 0)), camera: Self.camera, aspect: Self.aspect)
        widget.endDrag(commit: false)

        #expect(commitCount == 0)
    }

    @Test func t_reset_zeroesTransform() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)
        widget.beginDrag(
            axis: .x, ndc: try ndc(of: .zero), camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ndc(of: SIMD3<Float>(0.4, 0, 0)), camera: Self.camera, aspect: Self.aspect)
        widget.endDrag()
        widget.reset()
        #expect(widget.transform == matrix_identity_float4x4)
    }

    // MARK: - Render / pick layers (v0.2.1)

    @Test func t_arrowsAreOverlayLayer() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.install(in: ctx)
        let arrows = widgetBodies(ctx, target: obj)
        #expect(arrows.allSatisfy { $0.renderLayer == .overlay })
    }

    @Test func t_arrowsAreWidgetPickLayer() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.install(in: ctx)
        let arrows = widgetBodies(ctx, target: obj)
        #expect(arrows.allSatisfy { $0.pickLayer == .widget })
    }

    // MARK: - Live target body transform during drag (v0.2.1)

    @Test func t_dragUpdatesTargetBodyTransformLive() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)

        let beforeT = ctx.sourceBody(for: obj)?.transform ?? matrix_identity_float4x4
        #expect(beforeT == matrix_identity_float4x4)

        widget.beginDrag(
            axis: .x, ndc: try ndc(of: .zero), camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ndc(of: SIMD3<Float>(0.5, 0, 0)), camera: Self.camera, aspect: Self.aspect)

        let liveT = ctx.sourceBody(for: obj)?.transform ?? matrix_identity_float4x4
        #expect(
            abs(liveT.columns.3.x - 0.5) < 1e-3,
            "target body transform should reflect running drag along +X")
    }

    @Test func t_uninstall_restoresTargetBodyTransform() throws {
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)

        widget.beginDrag(
            axis: .x, ndc: try ndc(of: .zero), camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ndc(of: SIMD3<Float>(0.5, 0, 0)), camera: Self.camera, aspect: Self.aspect)
        widget.endDrag(commit: true)
        widget.uninstall()

        let restored = ctx.sourceBody(for: obj)?.transform ?? .init()
        #expect(
            restored == matrix_identity_float4x4,
            "uninstall must restore target body's pre-install transform")
    }

    @Test func t_install_capturesPreExistingTargetTransform() throws {
        // If the target body already has a non-identity transform, the widget
        // should layer onto it, and uninstall should restore it.
        let ctx = makeContext()
        let obj = ctx.display(try makeBox())
        let preInstall = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(7, 0, 0, 1))
        if let i = ctx.bodies.firstIndex(where: { $0.id == "ais.\(obj.id.uuidString)" }) {
            ctx.bodies[i].transform = preInstall
        }

        let widget = ManipulatorWidget(target: obj)
        widget.size = 2.0
        widget.install(in: ctx)

        widget.beginDrag(
            axis: .x, ndc: try ndc(of: .zero), camera: Self.camera, aspect: Self.aspect)
        widget.updateDrag(
            ndc: try ndc(of: SIMD3<Float>(0.5, 0, 0)), camera: Self.camera, aspect: Self.aspect)
        widget.endDrag(commit: true)

        let live = ctx.sourceBody(for: obj)?.transform ?? .init()
        #expect(
            abs(live.columns.3.x - 7.5) < 1e-3,
            "running drag should compose with the pre-install transform")

        widget.uninstall()
        let restored = ctx.sourceBody(for: obj)?.transform ?? .init()
        #expect(
            abs(restored.columns.3.x - 7.0) < 1e-3,
            "uninstall must restore exactly the pre-install transform")
    }

    // MARK: - Helpers

    private func arrowTransform(
        in ctx: InteractiveContext, target: InteractiveObject, axis: ManipulatorWidget.Axis
    ) -> simd_float4x4? {
        let id = "ais.widget.\(target.id.uuidString).\(suffix(for: axis))"
        return ctx.bodies.first(where: { $0.id == id })?.transform
    }

    private func suffix(for axis: ManipulatorWidget.Axis) -> String {
        switch axis {
        case .x: return "x"
        case .y: return "y"
        case .z: return "z"
        }
    }
}
