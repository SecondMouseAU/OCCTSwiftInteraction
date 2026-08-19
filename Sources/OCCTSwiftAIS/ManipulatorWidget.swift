import Foundation
import OCCTSwift
import OCCTSwiftViewport
import simd

/// Three-axis manipulator gizmo for translating (`v0.2`) or rotating (`v0.2.2`)
/// a target `InteractiveObject`.
///
/// Scaling is reserved for a future release.
///
/// ## Wiring
///
/// 1. Build the widget for a target `InteractiveObject` and pick a `mode`.
/// 2. Call `install(in:)` with the `InteractiveContext` displaying the target:
///    three axis-arrow bodies (`.translate`) or three ring bodies (`.rotate`)
///    appear in the scene, tagged `ais.widget.<UUID>.<x|y|z>`.
/// 3. From your gesture handler, call `hitTest(ndc:camera:aspect:)` to see which
///    axis (if any) the user grabbed, then `beginDrag` / `updateDrag` / `endDrag`
///    as the pointer moves and releases. NDC is `[-1, 1]` with +Y up.
/// 4. Observe `transform`, `onChange`, `onCommit` to react.
///
/// Widget bodies render on the viewport's overlay layer (always on top) and
/// their picks route to `viewport.widgetPickResult` rather than the user pick
/// stream; see `ViewportBody.renderLayer` / `pickLayer`.
///
/// During drag, the target body's `ViewportBody.transform` is updated live
/// (`preInstallTransform * widget.transform`) so the user sees their input on
/// the geometry. `uninstall()` restores the pre-install transform.
@MainActor
public final class ManipulatorWidget: ObservableObject {

    public enum Mode: Sendable {
        case translate
        case rotate
        case scale  // reserved
    }

    public enum Axis: Hashable, Sendable, CaseIterable {
        case x, y, z

        public var direction: SIMD3<Float> {
            switch self {
            case .x: return SIMD3<Float>(1, 0, 0)
            case .y: return SIMD3<Float>(0, 1, 0)
            case .z: return SIMD3<Float>(0, 0, 1)
            }
        }

        public var color: SIMD4<Float> {
            switch self {
            case .x: return SIMD4<Float>(1.00, 0.25, 0.25, 1.0)
            case .y: return SIMD4<Float>(0.25, 0.90, 0.25, 1.0)
            case .z: return SIMD4<Float>(0.30, 0.45, 1.00, 1.0)
            }
        }

        fileprivate var suffix: String {
            switch self {
            case .x: return "x"
            case .y: return "y"
            case .z: return "z"
            }
        }
    }

    // MARK: - Inputs

    public let target: InteractiveObject
    public let mode: Mode

    /// Length of each arrow / radius reference for rings.
    ///
    /// Pick relative to your target's bounding box. Defaults to `1.0`.
    public var size: Float = 1.0

    /// Arrow shaft radius in world units (translate mode).
    public var shaftRadius: Float = 0.025

    /// Rotation ring tube radius in world units (rotate mode).
    ///
    /// Defaults to `shaftRadius * 1.2` if left at `nil`.
    public var rotateTubeRadius: Float?

    /// Rotation ring major radius in world units (rotate mode).
    ///
    /// Defaults to `size * 0.85` if left at `nil`.
    public var rotateRingRadius: Float?

    /// Hit-test threshold in NDC units (translate mode).
    ///
    /// Default `0.04`.
    public var hitNDCTolerance: Float = 0.04

    /// Hit-test threshold for ring radius (rotate mode), in world units.
    ///
    /// Defaults to `2.5 × rotateTubeRadius`.
    public var rotateHitTolerance: Float?

    /// Minimum |cos(angle)| between view direction and a ring's normal for the
    /// ring to be hit-testable.
    ///
    /// Below this the plane intersection becomes numerically unstable; the
    /// axis is skipped. Default `0.05`.
    public var rotateAxisDotMin: Float = 0.05

    public var snapTranslate: Float?
    public var snapRotateDeg: Float?

    public var onChange: ((simd_float4x4) -> Void)?
    public var onCommit: ((simd_float4x4) -> Void)?

    // MARK: - Observable

    @Published public private(set) var transform: simd_float4x4 = matrix_identity_float4x4
    @Published public private(set) var isInstalled: Bool = false
    @Published public private(set) var activeAxis: Axis? = nil

    public var isDragging: Bool { activeAxis != nil }

    /// The `InteractiveContext` this widget is currently installed in, or
    /// `nil` before `install(in:)` and after `uninstall()`.
    ///
    /// Public read so the `.attachManipulator(_:)` view modifier can route
    /// camera-fallback drags through the same context's `viewport`.
    public weak private(set) var context: InteractiveContext?

    // MARK: - Internal state

    private var pivot: SIMD3<Float> = .zero
    private var preInstallTargetTransform: simd_float4x4 = matrix_identity_float4x4

    private enum DragState {
        case translate(axis: Axis, initialAxisParam: Float, initialTransform: simd_float4x4)
        case rotate(axis: Axis, initialAngle: Float, initialTransform: simd_float4x4)

        var axis: Axis {
            switch self {
            case .translate(let a, _, _): return a
            case .rotate(let a, _, _): return a
            }
        }
    }
    private var dragState: DragState?

    // MARK: - Init

    public init(target: InteractiveObject, mode: Mode = .translate) {
        self.target = target
        self.mode = mode
    }

    // MARK: - Install

    public func install(in context: InteractiveContext) {
        guard !isInstalled else { return }
        self.context = context
        self.pivot = computePivot(in: context) ?? .zero
        self.preInstallTargetTransform =
            context.sourceBody(for: target)?.transform
            ?? matrix_identity_float4x4
        buildHandleBodies()
        applyHandleTransforms()
        applyTargetTransform()
        isInstalled = true
    }

    public func uninstall() {
        guard isInstalled, let context else {
            isInstalled = false
            self.context = nil
            return
        }
        let prefix = bodyIDPrefix
        context.removeInternalBodies { $0.hasPrefix(prefix) }
        if let targetID = context.bodyID(for: target),
            let i = context.bodies.firstIndex(where: { $0.id == targetID })
        {
            context.bodies[i].transform = preInstallTargetTransform
        }
        self.context = nil
        isInstalled = false
        activeAxis = nil
        dragState = nil
    }

    // MARK: - Hit test

    public func hitTest(ndc: SIMD2<Float>, camera: CameraState, aspect: Float) -> Axis? {
        switch mode {
        case .translate: return hitTestTranslate(ndc: ndc, camera: camera, aspect: aspect)
        case .rotate: return hitTestRotate(ndc: ndc, camera: camera, aspect: aspect)
        case .scale: return nil
        }
    }

    // MARK: - Drag

    public func beginDrag(axis: Axis, ndc: SIMD2<Float>, camera: CameraState, aspect: Float) {
        switch mode {
        case .translate:
            beginTranslateDrag(axis: axis, ndc: ndc, camera: camera, aspect: aspect)
        case .rotate:
            beginRotateDrag(axis: axis, ndc: ndc, camera: camera, aspect: aspect)
        case .scale:
            return
        }
    }

    public func updateDrag(ndc: SIMD2<Float>, camera: CameraState, aspect: Float) {
        guard let state = dragState else { return }
        switch state {
        case .translate(let axis, let initialParam, let initialTransform):
            updateTranslateDrag(
                axis: axis, initialParam: initialParam, initialTransform: initialTransform,
                ndc: ndc, camera: camera, aspect: aspect)
        case .rotate(let axis, let initialAngle, let initialTransform):
            updateRotateDrag(
                axis: axis, initialAngle: initialAngle, initialTransform: initialTransform,
                ndc: ndc, camera: camera, aspect: aspect)
        }
    }

    public func endDrag(commit: Bool = true) {
        guard dragState != nil else { return }
        if commit {
            onCommit?(transform)
        }
        dragState = nil
        activeAxis = nil
    }

    public func reset() {
        transform = matrix_identity_float4x4
        if isInstalled {
            applyHandleTransforms()
            applyTargetTransform()
        }
    }

    // MARK: - Translate paths

    private func hitTestTranslate(ndc: SIMD2<Float>, camera: CameraState, aspect: Float) -> Axis? {
        let viewProj = camera.projectionMatrix(aspectRatio: aspect) * camera.viewMatrix
        let originWS = pivot + currentTranslation()

        var best: (axis: Axis, distance: Float, depth: Float)? = nil
        for axis in Axis.allCases {
            let endWS = originWS + axis.direction * size
            guard let p0 = ProjectionUtility.worldToNDC(point: originWS, vpMatrix: viewProj),
                let p1 = ProjectionUtility.worldToNDC(point: endWS, vpMatrix: viewProj)
            else {
                continue
            }
            let p0xy = SIMD2<Float>(p0.x, p0.y)
            let p1xy = SIMD2<Float>(p1.x, p1.y)
            let dist = pointToSegmentDistance(point: ndc, a: p0xy, b: p1xy)
            guard dist <= hitNDCTolerance else { continue }
            let depth = min(p0.z, p1.z)
            if let current = best {
                if depth < current.depth { best = (axis, dist, depth) }
            } else {
                best = (axis, dist, depth)
            }
        }
        return best?.axis
    }

    private func beginTranslateDrag(
        axis: Axis, ndc: SIMD2<Float>, camera: CameraState, aspect: Float
    ) {
        let pickRay = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: aspect)
        let originWS = pivot + currentTranslation()
        guard
            let initial = closestParam(onAxisLine: originWS, axisDir: axis.direction, ray: pickRay)
        else {
            return
        }
        dragState = .translate(axis: axis, initialAxisParam: initial, initialTransform: transform)
        activeAxis = axis
    }

    private func updateTranslateDrag(
        axis: Axis,
        initialParam: Float,
        initialTransform: simd_float4x4,
        ndc: SIMD2<Float>,
        camera: CameraState,
        aspect: Float
    ) {
        let pickRay = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: aspect)
        let originWS = pivot + extractTranslation(from: initialTransform)
        guard let now = closestParam(onAxisLine: originWS, axisDir: axis.direction, ray: pickRay)
        else {
            return
        }
        var delta = now - initialParam
        if let step = snapTranslate, step > 0 {
            delta = (delta / step).rounded() * step
        }
        var newTransform = initialTransform
        let translation = axis.direction * delta
        newTransform.columns.3.x += translation.x
        newTransform.columns.3.y += translation.y
        newTransform.columns.3.z += translation.z
        transform = newTransform
        applyHandleTransforms()
        applyTargetTransform()
        onChange?(transform)
    }

    // MARK: - Rotate paths

    private func hitTestRotate(ndc: SIMD2<Float>, camera: CameraState, aspect: Float) -> Axis? {
        let pickRay = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: aspect)
        let radius = effectiveRotateRingRadius
        let tolerance = rotateHitTolerance ?? max(effectiveRotateTubeRadius * 2.5, 1e-4)
        var best: (axis: Axis, distance: Float)? = nil
        for axis in Axis.allCases {
            guard let intersect = ringPlaneIntersection(axis: axis, ray: pickRay) else { continue }
            let radial = abs(simd_length(intersect - pivot) - radius)
            guard radial <= tolerance else { continue }
            if let current = best {
                if radial < current.distance { best = (axis, radial) }
            } else {
                best = (axis, radial)
            }
        }
        return best?.axis
    }

    private func beginRotateDrag(axis: Axis, ndc: SIMD2<Float>, camera: CameraState, aspect: Float)
    {
        let pickRay = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: aspect)
        guard let intersect = ringPlaneIntersection(axis: axis, ray: pickRay) else { return }
        let initialAngle = ringPlaneAngle(point: intersect, axis: axis)
        dragState = .rotate(axis: axis, initialAngle: initialAngle, initialTransform: transform)
        activeAxis = axis
    }

    private func updateRotateDrag(
        axis: Axis,
        initialAngle: Float,
        initialTransform: simd_float4x4,
        ndc: SIMD2<Float>,
        camera: CameraState,
        aspect: Float
    ) {
        let pickRay = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: aspect)
        guard let intersect = ringPlaneIntersection(axis: axis, ray: pickRay) else { return }
        let now = ringPlaneAngle(point: intersect, axis: axis)
        var delta = wrapAngle(now - initialAngle)
        if let stepDeg = snapRotateDeg, stepDeg > 0 {
            let step = stepDeg * .pi / 180
            delta = (delta / step).rounded() * step
        }
        let q = simd_quatf(angle: delta, axis: simd_normalize(axis.direction))
        let rotation = simd_float4x4(q)
        let rotateAboutPivot = translationMatrix(pivot) * rotation * translationMatrix(-pivot)
        transform = initialTransform * rotateAboutPivot
        applyHandleTransforms()
        applyTargetTransform()
        onChange?(transform)
    }

    /// Where the ray crosses the ring plane (perpendicular to `axis` through
    /// the pivot).
    ///
    /// Nil if the ray is too parallel to the plane to be useful.
    private func ringPlaneIntersection(axis: Axis, ray: Ray) -> SIMD3<Float>? {
        let n = simd_normalize(axis.direction)
        let denom = simd_dot(ray.direction, n)
        guard abs(denom) > rotateAxisDotMin else { return nil }
        let t = simd_dot(pivot - ray.origin, n) / denom
        guard t > 0 else { return nil }
        return ray.origin + ray.direction * t
    }

    /// Angle of a point in the ring plane relative to the in-plane basis.
    ///
    /// Stable across calls for the same axis.
    private func ringPlaneAngle(point: SIMD3<Float>, axis: Axis) -> Float {
        let (u, v) = ringPlaneBasis(for: axis)
        let r = point - pivot
        return atan2(simd_dot(r, v), simd_dot(r, u))
    }

    private func ringPlaneBasis(for axis: Axis) -> (SIMD3<Float>, SIMD3<Float>) {
        // Stable per-axis basis so initialAngle and updatedAngle agree.
        switch axis {
        case .x: return (SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1))
        case .y: return (SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0))
        case .z: return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
        }
    }

    // MARK: - Handle bodies

    private func buildHandleBodies() {
        guard let context else { return }
        let prefix = bodyIDPrefix
        context.removeInternalBodies { $0.hasPrefix(prefix) }
        switch mode {
        case .translate:
            for axis in Axis.allCases {
                let body = ManipulatorGeometry.makeAxisArrow(
                    id: bodyID(for: axis),
                    origin: .zero,
                    direction: axis.direction,
                    length: size,
                    radius: shaftRadius,
                    color: axis.color
                )
                context.appendInternalBody(body)
            }
        case .rotate:
            let r = effectiveRotateRingRadius
            let tr = effectiveRotateTubeRadius
            for axis in Axis.allCases {
                let body = ManipulatorGeometry.makeRotationRing(
                    id: bodyID(for: axis),
                    pivot: .zero,
                    axis: axis.direction,
                    radius: r,
                    tubeRadius: tr,
                    color: axis.color
                )
                context.appendInternalBody(body)
            }
        case .scale:
            return
        }
    }

    /// Translate handles to the pivot and (in translate mode) by the running
    /// translation.
    ///
    /// Rings stay anchored at the pivot: they don't rotate to avoid losing
    /// the visual reference of the rotation axes.
    private func applyHandleTransforms() {
        guard let context else { return }
        let m: simd_float4x4
        switch mode {
        case .translate:
            m = translationMatrix(pivot + currentTranslation())
        case .rotate:
            m = translationMatrix(pivot)
        case .scale:
            m = matrix_identity_float4x4
        }
        for axis in Axis.allCases {
            let id = bodyID(for: axis)
            if let i = context.bodies.firstIndex(where: { $0.id == id }) {
                context.bodies[i].transform = m
            }
        }
    }

    private func applyTargetTransform() {
        guard let context, let id = context.bodyID(for: target) else { return }
        if let i = context.bodies.firstIndex(where: { $0.id == id }) {
            context.bodies[i].transform = preInstallTargetTransform * transform
        }
    }

    // MARK: - Internals

    var bodyIDPrefix: String { "ais.widget.\(target.id.uuidString)." }

    func bodyID(for axis: Axis) -> String { bodyIDPrefix + axis.suffix }

    private var effectiveRotateRingRadius: Float { rotateRingRadius ?? (size * 0.85) }
    private var effectiveRotateTubeRadius: Float { rotateTubeRadius ?? (shaftRadius * 1.2) }

    private func computePivot(in context: InteractiveContext) -> SIMD3<Float>? {
        guard let body = context.sourceBody(for: target) else { return nil }
        return centerOfVertexData(body.vertexData, stride: 6)
    }

    private func currentTranslation() -> SIMD3<Float> {
        extractTranslation(from: transform)
    }
}

// MARK: - Free helpers

private func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    return m
}

private func extractTranslation(from m: simd_float4x4) -> SIMD3<Float> {
    SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
}

private func centerOfVertexData(_ data: [Float], stride: Int) -> SIMD3<Float>? {
    guard data.count >= stride else { return nil }
    var minP = SIMD3<Float>(repeating: .infinity)
    var maxP = SIMD3<Float>(repeating: -.infinity)
    var i = 0
    while i + 2 < data.count {
        let p = SIMD3<Float>(data[i], data[i + 1], data[i + 2])
        minP = simd_min(minP, p)
        maxP = simd_max(maxP, p)
        i += stride
    }
    return (minP + maxP) * 0.5
}

private func pointToSegmentDistance(point: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float
{
    let ab = b - a
    let denom = simd_dot(ab, ab)
    if denom < 1e-9 { return simd_distance(point, a) }
    var t = simd_dot(point - a, ab) / denom
    t = max(0, min(1, t))
    let closest = a + ab * t
    return simd_distance(point, closest)
}

private func closestParam(
    onAxisLine axisOrigin: SIMD3<Float>,
    axisDir: SIMD3<Float>,
    ray: Ray
) -> Float? {
    let d1 = simd_normalize(ray.direction)
    let d2 = simd_normalize(axisDir)
    let w0 = ray.origin - axisOrigin
    let b = simd_dot(d1, d2)
    let denom = 1.0 - b * b
    if denom < 1e-6 { return nil }
    let d = simd_dot(d1, w0)
    let e = simd_dot(d2, w0)
    return (e - b * d) / denom
}

/// Wrap to (-π, π] so a drag that crosses the ±π seam doesn't jump 2π.
private func wrapAngle(_ a: Float) -> Float {
    var x = a
    while x > .pi { x -= 2 * .pi }
    while x <= -.pi { x += 2 * .pi }
    return x
}
