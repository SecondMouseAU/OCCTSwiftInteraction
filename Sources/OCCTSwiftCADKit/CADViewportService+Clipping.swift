// CADViewportService+Clipping.swift
// OCCTSwiftCADKit
//
// Split out of CADViewportService.swift for OCCTSwiftInteraction#13 (code-structure policy).
// The service's stored state stays in the core file; this is the clipping, capping and clip-aware picking surface of the same
// type. A move, not a rewrite: the bodies below are unchanged.

import Combine
import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import SwiftUI
import simd

@MainActor
extension CADViewportService {

    // MARK: - Clipping

    /// Every currently configured clipping plane.
    ///
    /// Setting replaces the whole array (a plane dropped from the new value is implicitly
    /// removed; add via `addClippingPlane`/`sectionSweep` to get an auto-generated `id`
    /// instead of inventing your own). `ViewportController.clipPlanes` in `OCCTSwiftViewport`
    /// only honors the first 4 *enabled* planes per frame; this property can hold more, but
    /// only the first 4 enabled ones actually clip.
    public var clippingPlanes: [ClippingPlane] {
        get { clippingPlaneStorage }
        set {
            clippingPlaneStorage = newValue
            syncClippingPlanes()
        }
    }

    /// Adds a clipping plane and returns its `id` (pass to `removeClippingPlane(id:)` or look
    /// up in `clippingPlanes` to adjust it later).
    @discardableResult
    public func addClippingPlane(
        origin: SIMD3<Double>, normal: SIMD3<Double>, showCapSurface: Bool = true
    ) -> String {
        let id = UUID().uuidString
        clippingPlaneStorage.append(
            ClippingPlane(id: id, origin: origin, normal: normal, showCapSurface: showCapSurface))
        syncClippingPlanes()
        return id
    }

    /// Removes a clipping plane.
    ///
    /// No-op if `id` isn't currently configured.
    public func removeClippingPlane(id: String) {
        guard clippingPlaneStorage.contains(where: { $0.id == id }) else { return }
        clippingPlaneStorage.removeAll { $0.id == id }
        if sectionSweepPlaneID == id {
            sectionSweepPlaneID = nil
        }
        syncClippingPlanes()
    }

    /// Convenience for the prismatic-axis inspection case: steps a single, dedicated plane
    /// along `axis` (need not be pre-normalized) to world coordinate `position`.
    ///
    /// The first call creates the plane (capping on by default); later calls move that SAME
    /// plane (preserving whatever `isEnabled`/`showCapSurface` it's since been set to) rather
    /// than accumulating a new one per call. Call `removeClippingPlane` with the id this
    /// method first returned via `clippingPlanes` if you need to stop sweeping and remove it.
    public func sectionSweep(axis: SIMD3<Double>, position: Double) {
        let unitAxis = simd_length(axis) > 0 ? simd_normalize(axis) : SIMD3<Double>(0, 0, 1)
        let origin = unitAxis * position
        if let id = sectionSweepPlaneID,
            let index = clippingPlaneStorage.firstIndex(where: { $0.id == id })
        {
            clippingPlaneStorage[index].origin = origin
            clippingPlaneStorage[index].normal = unitAxis
        } else {
            let id = UUID().uuidString
            clippingPlaneStorage.append(ClippingPlane(id: id, origin: origin, normal: unitAxis))
            sectionSweepPlaneID = id
        }
        syncClippingPlanes()
    }

    /// Pushes `clippingPlaneStorage` to the viewport's global, GPU-only clip mechanism
    /// (`controller.clipPlanes`: hides geometry on one side, interactively, with no
    /// per-body scoping; confirmed via `ViewportRenderer` in `OCCTSwiftViewport`, which
    /// applies the first 4 *enabled* planes uniformly to every body in the scene every
    /// frame) and recomputes capping.
    private func syncClippingPlanes() {
        if let id = sectionSweepPlaneID, !clippingPlaneStorage.contains(where: { $0.id == id }) {
            sectionSweepPlaneID = nil
        }
        controller.clipPlanes = clippingPlaneStorage.map { plane in
            let unitNormal = safeUnitNormal(plane.normal)
            let distance = Float(-simd_dot(unitNormal, plane.origin))
            return ClipPlane(
                normal: SIMD3<Float>(unitNormal), distance: distance, isEnabled: plane.isEnabled)
        }
        updateCapSurfaces()
    }

    /// A plane's normal normalized to unit length, falling back to a sensible default
    /// direction for a degenerate (zero-length) normal rather than propagating NaN through
    /// `simd_normalize`, which would otherwise make every bounds-center test in
    /// `cappedShape`/`isPointClipped` silently evaluate to false, treating the whole body as
    /// clipped away. Mirrors `sectionSweep`'s own guard on its `axis` parameter.
    private func safeUnitNormal(_ normal: SIMD3<Double>) -> SIMD3<Double> {
        simd_length(normal) > 0 ? simd_normalize(normal) : SIMD3<Double>(0, 0, 1)
    }

    /// What a single body's cap recomputation determined, from `cappedShape`.
    private enum CapOutcome {
        /// No cap-enabled plane actually intersects this body: leave `modelBodies`/
        /// `bodyShapes`/identity tables untouched entirely, rather than needlessly
        /// retessellating (and, via `replaceBody`'s fresh `BRepGraph`, invalidating every
        /// durable `GraphUID` this body's pristine geometry had ever minted) a body no
        /// enabled plane comes anywhere near.
        case unchanged
        case capped(OCCTSwift.Shape)
        case fullyClipped
    }

    /// Whether an active `ComparisonView`'s mode mutates bodies in a way `updateCapSurfaces`
    /// needs to undo-and-reapply around its own recompute. `.overlay`/`.sideBySide`/`.wipe`
    /// all mutate `modelBodies` directly; `.deviation` doesn't: it's a marker over a
    /// `ScalarField` the caller manages via `setScalarField(_:forBody:)`, independent of
    /// anything `updateCapSurfaces` touches. Treating `.deviation` as "nothing to preserve"
    /// (rather than routing it through the destructive `setScalarField(nil, forBody:)`
    /// "undo" of `undoComparison`, which has no corresponding restore in
    /// `applyComparison`) is what keeps an active deviation heatmap from being silently wiped
    /// by a clipping-plane change that has nothing to do with it; see the fix for #46.
    private func comparisonNeedsBodyPreservation(_ comparison: ComparisonView) -> Bool {
        switch comparison.mode {
        case .overlay, .sideBySide, .wipe: return true
        case .deviation: return false
        }
    }

    /// Rebuilds bodies actually intersected by the currently enabled `showCapSurface` planes,
    /// so a clipped solid shows real material at the cut instead of looking hollow.
    ///
    /// `OCCTSwiftViewport` has no shader-level capping (confirmed: no capping/stencil logic
    /// in its `Shaders.metal`, unlike the clip-plane discard it does have), so this is a
    /// genuine B-Rep split (`OCCTSwift.Shape.split(atPlane:normal:)`) and retessellation per
    /// affected body, not a cheap GPU trick. `showCapSurface: false` planes still clip (via
    /// `syncClippingPlanes`'s GPU path above) but stay hollow and don't hit this cost, and
    /// nor does a body no enabled cap plane actually touches, OR a body that's already
    /// showing exactly the cap outcome it should (see the `.capped` case below, #45's fix):
    /// only a body whose outcome ACTUALLY changes since the last call goes through
    /// `replaceBody` (a fresh `BRepGraph`/`generation`, and, per #43/#45, a durable
    /// `GraphUID` any caller was holding for it stops resolving). An earlier version
    /// unconditionally restored-then-recapped every body already in `clippingCapBackup` on
    /// every call, so an actively-capped body whose relationship to every plane hadn't
    /// changed at all still got two full retessellations (and a fresh, unresolvable
    /// `GraphUID`) every time ANY unrelated clipping-plane mutation happened anywhere in the
    /// scene.
    ///
    /// Considers the union of every body already tracked in `clippingCapBackup` (so one that
    /// no longer needs capping gets restored) and every currently loaded body (so a body
    /// that's newly in range of a plane, including one just loaded, per issue #44's fix in
    /// the loaders, gets capped for the first time), rather than the previous two-pass
    /// "restore everything, then re-cap everything" structure.
    ///
    /// Also undoes, then re-applies, an independently active BODY-MUTATING `comparison`
    /// (`comparisonNeedsBodyPreservation`) around its own restore/recompute. Without this, a
    /// `.overlay`/`.sideBySide`/`.wipe` mutation on a body this method also touches would be
    /// silently discarded (color/transform reset, or wipe-filtering undone) the moment an
    /// UNRELATED clipping-plane change ran, since this method's own backup only knows about
    /// capping, not about `comparisonBackup`. `setComparison`/`pruneComparison` clear
    /// `self.comparison` before calling this themselves specifically so this logic is a no-op
    /// when THEY are the ones driving the comparison change (avoiding a redundant
    /// undo/reapply of a comparison this method didn't initiate).
    func updateCapSurfaces() {
        let activeComparison = comparison.flatMap { comparisonNeedsBodyPreservation($0) ? $0 : nil }
        if let activeComparison {
            undoComparison(activeComparison)
        }

        let capPlanes = clippingPlaneStorage.filter { $0.isEnabled && $0.showCapSurface }

        var bodyIDsToConsider = Set(clippingCapBackup.keys)
        bodyIDsToConsider.formUnion(modelBodies.map(\.id))

        for bodyID in bodyIDsToConsider {
            guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { continue }
            guard let sourceShape = clippingSourceShapes[bodyID] ?? bodyShapes[bodyID] else {
                continue
            }
            clippingSourceShapes[bodyID] = sourceShape

            let wasCapped = clippingCapBackup[bodyID] != nil
            let outcome: CapOutcome =
                capPlanes.isEmpty ? .unchanged : cappedShape(sourceShape, cutBy: capPlanes)

            switch outcome {
            case .unchanged:
                guard wasCapped, let original = clippingCapBackup[bodyID] else { continue }
                _ = replaceBody(bodyID: bodyID, withCappedShape: sourceShape, preserving: original)
                clippingCapBackup.removeValue(forKey: bodyID)

            case .fullyClipped:
                // Every cap plane's kept region excludes this body entirely.
                if !wasCapped {
                    clippingCapBackup[bodyID] = modelBodies[index]
                }
                modelBodies[index].isVisible = false

            case .capped(let capped):
                // Skip the retessellation entirely when this body is already showing exactly
                // this outcome, visibly (not left hidden by a since-reverted full clip,
                // which always needs a real transition back to visible regardless of bounds).
                if wasCapped, modelBodies[index].isVisible,
                    let currentlyDisplayed = bodyShapes[bodyID],
                    boundsPracticallyEqual(capped, currentlyDisplayed)
                {
                    continue
                }
                let original =
                    wasCapped
                    ? (clippingCapBackup[bodyID] ?? modelBodies[index]) : modelBodies[index]
                clippingCapBackup[bodyID] = original
                if !replaceBody(bodyID: bodyID, withCappedShape: capped, preserving: original) {
                    // Retessellation failed: leave the original in place rather than show nothing.
                    modelBodies[index] = original
                    clippingCapBackup.removeValue(forKey: bodyID)
                }
            }
        }

        if let activeComparison {
            backUpComparisonBodies(activeComparison)
            applyComparison(activeComparison)
        }
        rebuildBodies()
    }

    /// Sequentially splits `shape` at each plane in `planes`, keeping only the piece(s) on
    /// the side the plane's normal points toward each time.
    ///
    /// Which returned `split(atPlane:normal:)` piece is "kept" is determined by testing each
    /// piece's OWN bounds-center against the plane equation: `Shape.split` documents no
    /// return-order guarantee. This is a bounds-center heuristic, not an exact interior-point
    /// test: a piece whose true bulk sits on the kept side but whose bounding-box center
    /// happens to fall just past the plane (an unusual, non-convex shape) could be
    /// misclassified. Adequate for a review affordance; not a substitute for a real
    /// point-containment query if that ever proves necessary.
    ///
    /// Returns `.unchanged` (rather than `.capped(shape)`) when the result's bounds are
    /// practically identical to `shape`'s own, i.e. no plane in `planes` actually removed
    /// anything. Determined by comparing bounds rather than by whether `split` returned
    /// `nil`: empirically, `split(atPlane:normal:)` does NOT reliably return `nil` for a
    /// plane that doesn't intersect the shape; it can come back with a single-element
    /// array containing the shape geometrically unchanged, which a naive "any non-nil result
    /// means a real cut happened" check would misread as a cut. This inherits the same
    /// bounds-based approximation as the "kept piece" test above (a cut that removes material
    /// without changing the axis-aligned bounding box, e.g. a chunk that isn't at the
    /// shape's extremal point along any axis, would be missed and reported `.unchanged`);
    /// accepted for the same reason.
    private func cappedShape(_ shape: OCCTSwift.Shape, cutBy planes: [ClippingPlane]) -> CapOutcome
    {
        var current = shape
        for plane in planes {
            let unitNormal = safeUnitNormal(plane.normal)
            func isKept(_ candidate: OCCTSwift.Shape) -> Bool {
                // A piece with no bounding box has no geometry to sit on either side of the
                // plane, so it is not kept; the callers below then route it through the same
                // `.fullyClipped` path an out-of-scope piece already takes.
                guard let b = candidate.bounds else { return false }
                let center = SIMD3<Double>(
                    (b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, (b.min.z + b.max.z) / 2)
                return simd_dot(unitNormal, center - plane.origin) >= 0
            }
            guard let pieces = current.split(atPlane: plane.origin, normal: unitNormal) else {
                guard isKept(current) else { return .fullyClipped }
                continue
            }
            let kept = pieces.filter(isKept)
            guard !kept.isEmpty else { return .fullyClipped }
            current = kept.count == 1 ? kept[0] : (OCCTSwift.Shape.fuseAll(kept) ?? kept[0])
        }
        return boundsPracticallyEqual(shape, current) ? .unchanged : .capped(current)
    }

    /// Two shapes with no bounding box at all are equal (nothing to tell apart); one of each
    /// is not (the split changed something).
    private func boundsPracticallyEqual(_ a: OCCTSwift.Shape, _ b: OCCTSwift.Shape) -> Bool {
        switch (a.bounds, b.bounds) {
        case (nil, nil):
            return true
        case (let ab?, let bb?):
            let epsilon = 1e-6
            return simd_length(ab.min - bb.min) < epsilon && simd_length(ab.max - bb.max) < epsilon
        default:
            return false
        }
    }

    /// Re-tessellates `bodyID` from `shape` (a capped shape from `cappedShape`, or the
    /// pristine `clippingSourceShapes` entry when `updateCapSurfaces` is restoring).
    ///
    /// Preserves the caller-configurable state of `original` (visibility, pickability,
    /// material, transform) that `CADFileLoader.shapeToBodyAndMetadata` would
    /// otherwise reset to its own defaults, and updates identity tables to match the new
    /// geometry (so picking the surviving faces, and the new cut face, resolves correctly,
    /// per the same identity contract `load(_:id:transform:)` maintains). Returns `false`
    /// (leaving `modelBodies` untouched) if retessellation fails.
    ///
    /// Also clears any `ScalarField` set on this body: a cut (in either direction, capping
    /// or restoring to pristine) inserts/removes faces and renumbers the rest, so the OLD
    /// field's values have no defined correspondence to the NEW tessellation's face/triangle
    /// ordinals. Leaving it in place would silently paint (or report via
    /// `scalarValue(forBody:faceIndex:triangleIndex:)`) values against geometry they were
    /// never computed for: the same failure mode `removeBodies`/`resetAllModelState` already
    /// guard against for a removed body.
    private func replaceBody(
        bodyID: String, withCappedShape shape: OCCTSwift.Shape, preserving original: _ViewportBody
    ) -> Bool {
        guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { return false }
        let (freshBody, meta) = CADFileLoader.shapeToBodyAndMetadata(
            shape, id: bodyID, color: original.color
        )
        guard var body = freshBody else { return false }
        body.isVisible = original.isVisible
        body.isPickable = original.isPickable
        body.roughness = original.roughness
        body.metallic = original.metallic
        body.material = original.material
        body.renderLayer = original.renderLayer
        body.pickLayer = original.pickLayer
        body.transform = original.transform

        modelBodies[index] = body
        if let meta { metadata[bodyID] = meta } else { metadata.removeValue(forKey: bodyID) }
        let identity = ShapeIdentity(shape: shape)
        installIdentity([bodyID: identity])
        // `installIdentity` merges, and a cap replaces this body's geometry outright: if the graph
        // failed to build for the NEW shape, the OLD one must go rather than linger naming
        // pre-cap topology. The tables above are unconditional, so only the graph needs this.
        if identity.graph == nil { bodyGraphs.removeValue(forKey: bodyID) }
        scalarFields.removeValue(forKey: bodyID)
        dropLastScalarFieldBodyID(ifCurrently: bodyID)
        return true
    }

    // MARK: - Clip-aware picking

    /// Whether `worldPoint` is hidden by an active clipping plane.
    ///
    /// The dedicated GPU pick shaders (`pick_fragment`/`pick_line_fragment`/
    /// `pick_arc_fragment`/point-pick) don't discard against `clipPlanes` the way the main
    /// shaded pass does (confirmed via `Shaders.metal` in `OCCTSwiftViewport`: the clip-plane
    /// discard loop only appears in the shaded fragment function), so a raw GPU pick can hit
    /// geometry that's invisible on screen. Resolvers test the picked primitive's own
    /// position against this rather than trusting the pick pass to have already excluded it.
    ///
    /// Limited to the first 4 *enabled* planes, matching `ViewportRenderer`'s own
    /// `Array(controller.clipPlanes.filter { $0.isEnabled }.prefix(4))`: with more than 4
    /// enabled hollow-clip planes, a 5th+ plane isn't actually applied by the renderer, so
    /// testing against it here would reject a pick the geometry is still visibly showing.
    /// (A body already geometrically truncated by capping has no such limit, see
    /// `cappedShape`, since that path doesn't go through the GPU clip-plane uniform at all.)
    func isPointClipped(_ worldPoint: SIMD3<Float>) -> Bool {
        guard !clippingPlaneStorage.isEmpty else { return false }
        for plane in clippingPlaneStorage.filter({ $0.isEnabled }).prefix(4) {
            let unitNormal = SIMD3<Float>(safeUnitNormal(plane.normal))
            let distance = Float(-simd_dot(safeUnitNormal(plane.normal), plane.origin))
            if simd_dot(unitNormal, worldPoint) + distance < 0 {
                return true
            }
        }
        return false
    }

    /// World-space centroid of a picked triangle (interleaved or direct-mesh body), for
    /// `isPointClipped`. `nil` on any out-of-bounds index rather than guessing; callers
    /// treat that as "couldn't determine, don't filter" rather than "clipped".
    func triangleWorldCentroid(bodyID: String, triangleIndex: Int) -> SIMD3<Float>? {
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
            triangleIndex >= 0, triangleIndex * 3 + 2 < body.indices.count
        else { return nil }
        let i0 = Int(body.indices[triangleIndex * 3])
        let i1 = Int(body.indices[triangleIndex * 3 + 1])
        let i2 = Int(body.indices[triangleIndex * 3 + 2])
        let local: SIMD3<Float>
        if body.usesDirectMesh {
            guard i0 * 3 + 2 < body.meshPositions.count, i1 * 3 + 2 < body.meshPositions.count,
                i2 * 3 + 2 < body.meshPositions.count
            else { return nil }
            let p0 = SIMD3<Float>(
                body.meshPositions[i0 * 3], body.meshPositions[i0 * 3 + 1],
                body.meshPositions[i0 * 3 + 2])
            let p1 = SIMD3<Float>(
                body.meshPositions[i1 * 3], body.meshPositions[i1 * 3 + 1],
                body.meshPositions[i1 * 3 + 2])
            let p2 = SIMD3<Float>(
                body.meshPositions[i2 * 3], body.meshPositions[i2 * 3 + 1],
                body.meshPositions[i2 * 3 + 2])
            local = (p0 + p1 + p2) / 3
        } else {
            guard i0 * 6 + 2 < body.vertexData.count, i1 * 6 + 2 < body.vertexData.count,
                i2 * 6 + 2 < body.vertexData.count
            else { return nil }
            let p0 = SIMD3<Float>(
                body.vertexData[i0 * 6], body.vertexData[i0 * 6 + 1], body.vertexData[i0 * 6 + 2])
            let p1 = SIMD3<Float>(
                body.vertexData[i1 * 6], body.vertexData[i1 * 6 + 1], body.vertexData[i1 * 6 + 2])
            let p2 = SIMD3<Float>(
                body.vertexData[i2 * 6], body.vertexData[i2 * 6 + 1], body.vertexData[i2 * 6 + 2])
            local = (p0 + p1 + p2) / 3
        }
        let world = body.transform * SIMD4<Float>(local, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// World-space midpoint of a picked edge segment, for `isPointClipped`.
    ///
    /// `segmentIndex` walks the polylines of `body.edges` in the same flattened order
    /// `edgeIndices` documents.
    func edgeSegmentWorldMidpoint(bodyID: String, segmentIndex: Int) -> SIMD3<Float>? {
        guard let body = modelBodies.first(where: { $0.id == bodyID }), segmentIndex >= 0 else {
            return nil
        }
        var remaining = segmentIndex
        for polyline in body.edges {
            let segmentCount = max(0, polyline.count - 1)
            if remaining < segmentCount {
                let local = (polyline[remaining] + polyline[remaining + 1]) / 2
                let world = body.transform * SIMD4<Float>(local, 1)
                return SIMD3<Float>(world.x, world.y, world.z)
            }
            remaining -= segmentCount
        }
        return nil
    }

    /// World-space position of a picked vertex, for `isPointClipped`.
    func vertexWorldPosition(bodyID: String, pointIndex: Int) -> SIMD3<Float>? {
        guard let body = modelBodies.first(where: { $0.id == bodyID }),
            pointIndex >= 0, pointIndex < body.vertices.count
        else { return nil }
        let world = body.transform * SIMD4<Float>(body.vertices[pointIndex], 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }
}
