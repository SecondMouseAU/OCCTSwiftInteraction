// CADViewportService+CapRemap.swift
// OCCTSwiftCADKit
//
// OCCTSwiftInteraction#77: carrying the selection on a body across a cap recut, which renumbers
// the body's sub-shapes and mints its durable uids afresh.

import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools

/// A body's identity tables and the origin of each sub-shape in them: one side of a cap recut.
struct CapRecutIdentity {
    let faces: FaceIdentityTable
    let edges: EdgeIdentityTable
    let vertices: VertexIdentityTable
    /// `nil` for the uncut body, whose every sub-shape is its own `CapOrigin.source`.
    let origins: CapOrigins?

    /// The table for `kind` as shapes and uids, or `nil` for a kind with no table.
    func table(_ kind: ShapeType) -> (shapes: [Shape?], uids: [BRepGraph.GraphUID?]?)? {
        switch kind {
        case .face: (faces.shapes, faces.uids)
        case .edge: (edges.shapes, edges.uids)
        case .vertex: (vertices.shapes.map { Optional($0) }, vertices.uids)
        default: nil
        }
    }

    /// The ordinal in the table for `kind` of the sub-shape `ref` names, matched by `IsSame`.
    ///
    /// Tries `ref.ordinal` first, which is right whenever `ref` came from this table, and
    /// searches only when it is not: the shape is the identity and the ordinal advisory.
    func ordinal(of ref: SubShapeRef, _ kind: ShapeType) -> Int? {
        guard let shapes = table(kind)?.shapes else { return nil }
        if shapes.indices.contains(ref.ordinal), shapes[ref.ordinal]?.isSame(as: ref.shape) == true
        {
            return ref.ordinal
        }
        return shapes.firstIndex { $0?.isSame(as: ref.shape) == true }
    }

    func origin(of kind: ShapeType, at ordinal: Int) -> CapOrigin? {
        guard let origins else { return .source(kind: kind, ordinal: ordinal) }
        let list = origins.origins(of: kind)
        return list.indices.contains(ordinal) ? list[ordinal] : nil
    }

    /// Every ordinal of `kind` whose sub-shape has `origin`.
    func ordinals(of kind: ShapeType, withOrigin origin: CapOrigin) -> [Int] {
        guard let origins else {
            guard case .source(let sourceKind, let ordinal) = origin, sourceKind == kind,
                table(kind)?.shapes.indices.contains(ordinal) == true
            else { return [] }
            return [ordinal]
        }
        return origins.origins(of: kind).indices.filter { origins.origins(of: kind)[$0] == origin }
    }
}

@MainActor
extension CADViewportService {

    // MARK: - Selection across a cap recut

    /// The identity of body `bodyID` as the selection on it sees it now, or `nil` if it has no
    /// identity tables.
    func capRecutIdentity(ofBody bodyID: String) -> CapRecutIdentity? {
        guard let faces = faceIdentity[bodyID], let edges = edgeIdentity[bodyID],
            let vertices = vertexIdentity[bodyID]
        else { return nil }
        return CapRecutIdentity(
            faces: faces, edges: edges, vertices: vertices, origins: capOrigins[bodyID])
    }

    /// Remaps the selection on each body `updateCapSurfaces` recut or restored onto the body's
    /// new identity tables. `before` holds each such body's identity as the selection last saw it.
    ///
    /// A selected face, edge or vertex is replaced by every sub-shape of the new body with its
    /// origin (`CapOrigin`): itself, where the cut left it alone; its pieces, where the cut
    /// divided it; the whole sub-shape, where the cap was removed; and what the plane made from
    /// the same source sub-shape, where the cap moved. Each comes with the new table's ordinal
    /// and the new graph's uid, so `selection`, `selection.json` and the highlight all name the
    /// body as it is now drawn. A selected sub-shape with no image leaves the selection: the cap
    /// removed it, or it was the cap face or a section and the cap is gone, or the selection named
    /// something the old tables did not hold. It does not come back when the cap moves away again.
    /// A whole-body selection stays as it is.
    ///
    /// Publishes one change per body whose selection changed, as `.bodyRecut(bodyID:)`, and
    /// carries the agent's tag (`agentHighlightedEntities`) from each remapped entity to its
    /// images. Replaces the selection with one assignment per body, so a sidecar sees no
    /// half-remapped selection.
    func remapSelection(acrossRecutOf before: [String: CapRecutIdentity]) {
        for bodyID in before.keys.sorted() {
            guard let old = before[bodyID], let new = capRecutIdentity(ofBody: bodyID),
                let objectID = bodyObjectIDs[bodyID]
            else { continue }
            let current = interactiveContext.selection.subshapes
            let onBody = current.filter { $0.object.id == objectID && $0.ref != nil }
            guard let fallbackShape = onBody.first?.object.shape else { continue }

            let object = object(forBody: bodyID, fallbackShape: fallbackShape)
            let tagged = agentHighlightedEntities.filter { $0.bodyID == bodyID }
            var remapped: Set<OCCTSwiftTools.SubShape> = []
            var retaggedImages: [OCCTSwiftTools.SubShape] = []
            for subShape in onBody {
                let images = Self.images(of: subShape, from: old, to: new, rebindingTo: object)
                remapped.formUnion(images)
                if pickedEntity(for: subShape).map(tagged.contains) == true {
                    retaggedImages += images
                }
            }
            // Enriched before the change, as `select(_:scheme:)` does, so the `$selection` sink
            // finds each one cached rather than building it again. The old entries go first: one
            // could compare equal to an image (two refs without uids compare by ordinal) and
            // would then be read back as the image's enrichment.
            for subShape in onBody { selectionInfo[subShape] = nil }
            for image in remapped { selectionInfo[image] = pickedEntity(for: image) }
            let retagged = retaggedImages.compactMap { selectionInfo[$0] }
            agentHighlightedEntities.removeAll { $0.bodyID == bodyID }
            agentHighlightedEntities += retagged.filter { !agentHighlightedEntities.contains($0) }

            withSelectionSource(.bodyRecut(bodyID: bodyID)) {
                interactiveContext.select(
                    current.subtracting(onBody).union(remapped), scheme: .replace)
            }
        }
    }

    /// The sub-shapes of `new` that `subShape`, a sub-shape of `old`, maps to.
    private static func images(
        of subShape: OCCTSwiftTools.SubShape, from old: CapRecutIdentity, to new: CapRecutIdentity,
        rebindingTo object: OCCTSwiftTools.InteractiveObject
    ) -> [OCCTSwiftTools.SubShape] {
        let kind: ShapeType
        let make: (SubShapeRef) -> OCCTSwiftTools.SubShape
        switch subShape {
        case .body:
            return [subShape]
        case .face:
            kind = .face
            make = { .face(object, ref: $0) }
        case .edge:
            kind = .edge
            make = { .edge(object, ref: $0) }
        case .vertex:
            kind = .vertex
            make = { .vertex(object, ref: $0) }
        }
        guard let ref = subShape.ref, let ordinal = old.ordinal(of: ref, kind),
            let origin = old.origin(of: kind, at: ordinal), let table = new.table(kind)
        else { return [] }
        return new.ordinals(of: kind, withOrigin: origin).compactMap { image in
            guard let shape = table.shapes[image] else { return nil }
            return make(SubShapeRef(shape: shape, uid: table.uids?[image], ordinal: image))
        }
    }
}
