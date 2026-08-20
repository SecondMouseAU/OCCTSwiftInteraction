// CADViewportService+ScalarFields.swift
// OCCTSwiftCADKit
//
// Split out of CADViewportService.swift for OCCTSwiftInteraction#13 (code-structure policy).
// The service's stored state stays in the core file; this is the scalar field surface of the same
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

    // MARK: - Scalar Fields

    /// Paints (or clears, with `nil`) a scalar field over a loaded body: rebuilds that
    /// body's `TriangleStyle` buffer to reflect it.
    ///
    /// Currently rebuilds the whole body (a fresh `generation`, so a full vertex/index/edge
    /// re-upload alongside the style buffer) rather than mutating `triangleStyles` in place,
    /// because `OCCTSwiftViewport` (pinned floor 1.1.26) doesn't actually apply an in-place
    /// style-only mutation to an already-rendered body: its renderer only rebuilds a body's
    /// GPU buffers when `generation` changes, which an in-place mutation never does. See the
    /// doc comment on `applyTriangleStyles` for how this was confirmed.
    public func setScalarField(_ field: ScalarField?, forBody id: String) {
        guard let field else {
            scalarFields.removeValue(forKey: id)
            dropLastScalarFieldBodyID(ifCurrently: id)
            applyTriangleStyles(nil, forBody: id)
            return
        }
        scalarFields[id] = field
        lastScalarFieldBodyID = id
        applyTriangleStyles(field, forBody: id)
    }

    /// The scalar field currently painted on a body, or `nil`.
    public func scalarField(forBody id: String) -> ScalarField? {
        scalarFields[id]
    }

    /// Legend for the most recently set (still-active) scalar field: label, unit, range,
    /// and evenly-spaced color stops a UI can lay out as a gradient bar or discrete
    /// swatches.
    ///
    /// `nil` if no field is currently set on any body.
    public var scalarFieldLegend: ScalarFieldLegend? {
        guard let bodyID = lastScalarFieldBodyID, let field = scalarFields[bodyID],
            let range = field.effectiveRange
        else {
            return nil
        }
        let stopCount = 9
        let stops = (0..<stopCount).map { i -> LegendStop in
            let t = Double(i) / Double(stopCount - 1)
            let value = range.lowerBound + t * (range.upperBound - range.lowerBound)
            return LegendStop(value: value, color: field.colorMap.color(for: value, in: range))
        }
        return ScalarFieldLegend(label: field.label, unit: field.unit, range: range, stops: stops)
    }

    /// Builds a `TriangleStyle` per triangle from `field`.
    ///
    /// `nil`, or a field whose `effectiveRange` is `nil`, clears every style back to empty
    /// (not a full array of `.none`; `ViewportBody.triangleStyles`'s own contract
    /// distinguishes "empty" (skips the highlight pass for this body entirely) from
    /// "populated but all zero-alpha" (still builds a style buffer and runs the pass, just
    /// compositing nothing)) and writes it into `id`'s body. See this method's
    /// implementation comment below for why that's a full body reconstruction rather than
    /// an in-place `triangleStyles` mutation.
    private func applyTriangleStyles(_ field: ScalarField?, forBody id: String) {
        guard let index = modelBodies.firstIndex(where: { $0.id == id }) else { return }
        let body = modelBodies[index]
        let triCount = body.indices.count / 3
        var styles: [TriangleStyle] = []

        if let field, let range = field.effectiveRange {
            styles = [TriangleStyle](repeating: .none, count: triCount)
            switch field.domain {
            case .perTriangle:
                for tri in 0..<triCount where tri < field.values.count {
                    let value = field.values[tri]
                    guard !value.isNaN else { continue }
                    styles[tri] = TriangleStyle(color: field.colorMap.color(for: value, in: range))
                }
            case .perFace:
                for tri in 0..<triCount where tri < body.faceIndices.count {
                    let faceIndex = Int(body.faceIndices[tri])
                    guard faceIndex >= 0, faceIndex < field.values.count else { continue }
                    let value = field.values[faceIndex]
                    guard !value.isNaN else { continue }
                    styles[tri] = TriangleStyle(color: field.colorMap.color(for: value, in: range))
                }
            }
        }

        // Rebuilds the body rather than mutating `triangleStyles` in place, even though
        // `_ViewportBody.triangleStyles`'s own doc comment says an in-place mutation
        // "forces the renderer to upload a fresh per-triangle style buffer" while
        // preserving the rest of the body's GPU state. Empirically verified (against
        // OCCTSwiftViewport's pinned 1.1.26 via its OffscreenRenderer, on an
        // already-rendered body) that this isn't actually true today:
        // `ViewportRenderer`/`OffscreenRenderer.ensureBuffers(for:)` gate ALL buffer
        // work (including the triangle-style buffer) behind a check that only looks
        // at `body.generation`, which an in-place `triangleStyles` mutation never
        // changes (`generation` is a `let`, fixed at `init`). A body already on screen
        // when this ran would silently keep whatever style buffer it had before,
        // regardless of the new styles just computed above. Reconstructing the body
        // mints a fresh `generation`, which does force a real rebuild, at the cost of
        // a full vertex/index/edge re-upload alongside the style buffer, since
        // OCCTSwiftViewport has no coarser-than-"whole body" cache key to target. This
        // is a workaround for what looks like an upstream bug, not a design choice; once
        // OCCTSwiftViewport's caching can distinguish a style-only change, this should
        // go back to the in-place mutation to actually deliver the cheap update its own
        // API promises.
        modelBodies[index] = _ViewportBody(
            id: body.id,
            vertexData: body.vertexData,
            indices: body.indices,
            edges: body.edges,
            arcs: body.arcs,
            faceIndices: body.faceIndices,
            edgeIndices: body.edgeIndices,
            vertices: body.vertices,
            vertexIndices: body.vertexIndices,
            vertexColors: body.vertexColors,
            triangleStyles: styles,
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
        rebuildBodies()
    }

    /// The scalar value at a resolved face pick, if a field is set on that body.
    ///
    /// `nil` domain matches `PickedFaceInfo.faceIndex`/`triangleIndex` per `ScalarField.Domain`.
    /// `triangleIndex` is `nil` when the face was not reached through a pick (an area
    /// selection, or a selection made through `interactiveContext` directly), in which case a
    /// `.perTriangle` field has nothing to sample and reports no value. A `.perFace` field is
    /// unaffected: the face ordinal is enough.
    func scalarValue(forBody bodyID: String, faceIndex: Int, triangleIndex: Int?)
        -> Double?
    {
        guard let field = scalarFields[bodyID] else { return nil }
        switch field.domain {
        case .perFace:
            return faceIndex >= 0 && faceIndex < field.values.count ? field.values[faceIndex] : nil
        case .perTriangle:
            guard let triangleIndex else { return nil }
            return triangleIndex >= 0 && triangleIndex < field.values.count
                ? field.values[triangleIndex] : nil
        }
    }
}
