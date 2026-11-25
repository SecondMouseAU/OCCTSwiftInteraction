// CADViewportService+Comparison.swift
// OCCTSwiftCADKit
//
// Split out of CADViewportService.swift for OCCTSwiftInteraction#13 (code-structure policy).
// The service's stored state stays in the core file; this is the reference/candidate comparison surface of the same
// type. The split itself was a move, not a rewrite; what changed since is in the history.

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

    // MARK: - Comparison

    /// Sets (or, with `nil`, clears) a comparison view between two already-loaded entities.
    ///
    /// Safe to call repeatedly (including with a different mode, or different `position`/
    /// `referenceOpacity` for the same mode) without reloading either entity; each call
    /// first undoes whatever the previous comparison did before applying the new one (or
    /// nothing, if clearing). No-op for an entity id that isn't currently loaded.
    public func setComparison(_ comparison: ComparisonView?) {
        if let previous = self.comparison {
            undoComparison(previous)
            // Cleared BEFORE calling updateCapSurfaces (rather than after, alongside the
            // assignment below): updateCapSurfaces reads `self.comparison` itself to preserve
            // an independently active comparison around its own cap recompute. Since THIS
            // method is the one driving the comparison change (about to apply a new value, or
            // none, itself), leaving `previous` in place here would make updateCapSurfaces
            // redundantly undo-then-reapply it a second time right before this method's own
            // code does the real work below.
            self.comparison = nil
            // Re-applies an active cap to the just-restored body; also rebuilds.
            updateCapSurfaces()
        }
        self.comparison = comparison
        guard let comparison else {
            rebuildBodies()
            return
        }
        switch comparison.mode {
        case .overlay, .sideBySide, .wipe:
            backUpComparisonBodies(comparison)
        case .deviation:
            break
        }
        applyComparison(comparison)
        rebuildBodies()
    }

    private func entityBodyIDs(_ entityID: String) -> [String] {
        entities[entityID]?.bodyIDs ?? []
    }

    func backUpComparisonBodies(_ comparison: ComparisonView) {
        let ids = entityBodyIDs(comparison.referenceID) + entityBodyIDs(comparison.candidateID)
        for bodyID in ids {
            guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { continue }
            comparisonBackup[bodyID] = modelBodies[index]
        }
    }

    func undoComparison(_ previous: ComparisonView) {
        switch previous.mode {
        case .deviation:
            // Fields are keyed by body id and `candidateID` names an entity. Each clear
            // rebuilds bodies itself.
            for bodyID in entityBodyIDs(previous.candidateID) where scalarFields[bodyID] != nil {
                setScalarField(nil, forBody: bodyID)
            }
        case .overlay, .sideBySide, .wipe:
            for (bodyID, original) in comparisonBackup {
                if let index = modelBodies.firstIndex(where: { $0.id == bodyID }) {
                    modelBodies[index] = original
                }
            }
        }
        comparisonBackup.removeAll()
        wipeKeptTriangles.removeAll()
    }

    /// Maps a drawn triangle of `bodyID` to its index in the unwiped body.
    ///
    /// The unwiped order is the one `metadata[bodyID].faceIndices` and a `.perTriangle` scalar
    /// field use. Returns the index unchanged unless a `.wipe` has filtered the body, and `nil`
    /// past the last triangle a wiped body draws; callers still bound-check what they index
    /// with it. A GPU pick names a drawn triangle, so a read by triangle from anything but the
    /// live body goes through this first.
    func unwipedTriangle(ofBody bodyID: String) -> (_ drawnTriangle: Int) -> Int? {
        guard let kept = wipeKeptTriangles[bodyID] else { return { $0 } }
        return { kept.indices.contains($0) ? kept[$0] : nil }
    }

    /// Runs `write` on a body as the active comparison's snapshot holds it, then applies the
    /// comparison again over the result.
    ///
    /// The write reaches both `comparisonBackup` and the live body, and a `.wipe` filters the
    /// written body afresh. Runs `write` directly when no `.overlay`, `.sideBySide` or `.wipe`
    /// comparison holds a snapshot of `bodyID`. The caller rebuilds bodies.
    func writeThroughComparison(toBody bodyID: String, _ write: () -> Void) {
        guard let active = comparison, comparisonNeedsBodyPreservation(active),
            comparisonBackup[bodyID] != nil
        else {
            write()
            return
        }
        undoComparison(active)
        write()
        backUpComparisonBodies(active)
        applyComparison(active)
    }

    func applyComparison(_ comparison: ComparisonView) {
        switch comparison.mode {
        case .overlay(let opacity):
            applyOverlay(referenceID: comparison.referenceID, opacity: opacity)
        case .deviation:
            break  // caller drives this via setScalarField(_:forBody:) on the candidate
        case .sideBySide:
            applySideBySide(
                referenceID: comparison.referenceID, candidateID: comparison.candidateID)
        case .wipe(let axis, let position):
            applyWipe(
                referenceID: comparison.referenceID, candidateID: comparison.candidateID,
                axis: axis, position: position)
        }
    }

    /// Ghosts the reference entity by lowering its bodies' alpha.
    ///
    /// Safe as an in-place mutation (unlike `triangleStyles`, `ViewportBody.color` is read
    /// fresh into `BodyUniforms` every frame rather than baked into a cached buffer,
    /// confirmed via `BodyUniforms(body:)` on `ViewportRenderer`, which always reads
    /// `body.effectiveMaterial` live), and bodies below full opacity are already routed
    /// through the renderer's sorted transparent pass.
    private func applyOverlay(referenceID: String, opacity: Double) {
        let alpha = Float(max(0, min(1, opacity)))
        for bodyID in entityBodyIDs(referenceID) {
            guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { continue }
            modelBodies[index].color.w = alpha
        }
    }

    /// Union of bounds across every body of an entity.
    ///
    /// Unlike `shape(id:)` (which deliberately returns only the entity's first body's shape,
    /// fine for the "roughly frame the camera" use in `focus(on:)`), `applySideBySide` needs
    /// the offset to actually clear every body of a multi-body entity, not just whichever
    /// one happens to be first.
    ///
    /// `nil` when the entity isn't loaded, or when no body of it has a bounding box.
    private func entityBounds(_ entityID: String) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        let shapes = entityBodyIDs(entityID).compactMap { bodyShapes[$0] }
        guard !shapes.isEmpty else { return nil }
        var minPt = SIMD3<Double>(repeating: .infinity)
        var maxPt = SIMD3<Double>(repeating: -.infinity)
        for s in shapes {
            guard let b = s.bounds else { continue }
            minPt = SIMD3(min(minPt.x, b.min.x), min(minPt.y, b.min.y), min(minPt.z, b.min.z))
            maxPt = SIMD3(max(maxPt.x, b.max.x), max(maxPt.y, b.max.y), max(maxPt.z, b.max.z))
        }
        guard minPt.x.isFinite else { return nil }
        return (minPt, maxPt)
    }

    /// Offsets the candidate's bodies along X so it sits beside the reference rather than
    /// overlapping it.
    ///
    /// A single shared camera/viewport means "linked cameras" is automatic. Via
    /// `ViewportBody.transform`, also read live per frame (not cache-gated), so this is a
    /// cheap in-place update, no re-tessellation.
    private func applySideBySide(referenceID: String, candidateID: String) {
        guard let referenceBounds = entityBounds(referenceID),
            let candidateBounds = entityBounds(candidateID)
        else { return }
        let referenceSizeX = referenceBounds.max.x - referenceBounds.min.x
        let candidateSizeX = candidateBounds.max.x - candidateBounds.min.x
        let gap = max(referenceSizeX, candidateSizeX) * 0.15
        let deltaX = Float((referenceBounds.max.x + gap) - candidateBounds.min.x)
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4<Float>(deltaX, 0, 0, 1)
        for bodyID in entityBodyIDs(candidateID) {
            guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else { continue }
            modelBodies[index].transform = translation * modelBodies[index].transform
        }
    }

    /// Splits reference and candidate at a shared world-space plane (`axis`/`position`),
    /// keeping the reference's bodies on the lower side and the candidate's on the higher
    /// side.
    ///
    /// `ViewportController.clipPlanes` in `OCCTSwiftViewport` clips the whole scene uniformly
    /// (confirmed via `ViewportRenderer`: there's no per-body clip-plane field on
    /// `ViewportBody`), so it can't show reference and candidate on opposite sides of the same
    /// plane; this filters each body's own triangles instead. See `wipeFiltered` for what that
    /// drops. Records which triangles each body kept in `wipeKeptTriangles`.
    private func applyWipe(
        referenceID: String, candidateID: String, axis: ComparisonAxis, position: Double
    ) {
        let axisVector = axis.unitVector
        let planePosition = Float(position)
        for (entityID, keepBelow) in [(referenceID, true), (candidateID, false)] {
            for bodyID in entityBodyIDs(entityID) {
                guard let index = modelBodies.firstIndex(where: { $0.id == bodyID }) else {
                    continue
                }
                let (filtered, kept) = wipeFiltered(
                    modelBodies[index], axisVector: axisVector, position: planePosition,
                    keepBelow: keepBelow)
                modelBodies[index] = filtered
                wipeKeptTriangles[bodyID] = kept
            }
        }
    }

    /// Rebuilds `body` keeping only the triangles whose centroid falls on one side of a
    /// world-space plane (unit `axisVector`, offset `position` along it): the mechanism
    /// behind `.wipe`.
    ///
    /// Filters `indices`/`faceIndices`/`triangleStyles` in lockstep by
    /// triangle; `vertexData` (or `meshPositions`/`meshNormals` for a direct-mesh body) is
    /// passed through unfiltered since the filtered `indices` simply reference fewer of its
    /// entries, no vertex remapping needed. Drops `edges`/`arcs`/`vertices`/`vertexIndices`/
    /// `vertexColors`: wireframe overlay and vertex-picking aren't preserved on a wiped body,
    /// only the shaded triangle mesh; filtering polylines/points against the same cut is
    /// unneeded complexity for a review affordance whose point is the shaded-surface split.
    /// A body with no triangles (e.g. `.point` primitive) passes through unchanged.
    ///
    /// - Returns: the filtered body, and the index in `body` of each triangle it kept, in
    ///   order; `nil` for a body passed through unchanged.
    private func wipeFiltered(
        _ body: _ViewportBody, axisVector: SIMD3<Float>, position: Float, keepBelow: Bool
    ) -> (body: _ViewportBody, kept: [Int]?) {
        let triangleCount = body.indices.count / 3
        guard triangleCount > 0 else { return (body, nil) }
        let direct = body.usesDirectMesh
        guard direct ? body.meshPositions.count >= 3 : body.vertexData.count >= 6 else {
            return (body, nil)
        }

        func vertexPosition(_ vertexIndex: Int) -> SIMD3<Float> {
            if direct {
                return SIMD3<Float>(
                    body.meshPositions[vertexIndex * 3],
                    body.meshPositions[vertexIndex * 3 + 1],
                    body.meshPositions[vertexIndex * 3 + 2]
                )
            } else {
                return SIMD3<Float>(
                    body.vertexData[vertexIndex * 6],
                    body.vertexData[vertexIndex * 6 + 1],
                    body.vertexData[vertexIndex * 6 + 2]
                )
            }
        }

        let hasFaceIndices = body.faceIndices.count == triangleCount
        let hasStyles = body.triangleStyles.count == triangleCount
        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(body.indices.count)
        var newFaceIndices: [Int32] = []
        var newStyles: [TriangleStyle] = []
        var kept: [Int] = []

        for triangle in 0..<triangleCount {
            let i0 = Int(body.indices[triangle * 3])
            let i1 = Int(body.indices[triangle * 3 + 1])
            let i2 = Int(body.indices[triangle * 3 + 2])
            let centroid = (vertexPosition(i0) + vertexPosition(i1) + vertexPosition(i2)) / 3
            let signedDistance = simd_dot(centroid, axisVector) - position
            guard (signedDistance < 0) == keepBelow else { continue }
            newIndices.append(body.indices[triangle * 3])
            newIndices.append(body.indices[triangle * 3 + 1])
            newIndices.append(body.indices[triangle * 3 + 2])
            if hasFaceIndices { newFaceIndices.append(body.faceIndices[triangle]) }
            if hasStyles { newStyles.append(body.triangleStyles[triangle]) }
            kept.append(triangle)
        }

        let filtered = _ViewportBody(
            id: body.id,
            vertexData: body.vertexData,
            indices: newIndices,
            edges: [],
            arcs: [],
            faceIndices: newFaceIndices,
            edgeIndices: [],
            vertices: [],
            vertexIndices: [],
            vertexColors: [],
            triangleStyles: newStyles,
            color: body.color,
            roughness: body.roughness,
            metallic: body.metallic,
            material: body.material,
            pointRadius: body.pointRadius,
            primitiveKind: body.primitiveKind,
            isVisible: body.isVisible,
            isPickable: body.isPickable,
            renderLayer: body.renderLayer,
            pickLayer: body.pickLayer,
            transform: body.transform,
            meshPositions: body.meshPositions,
            meshNormals: body.meshNormals
        )
        return (filtered, kept)
    }
}
