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

    /// Remaps everything that names a sub-shape of a body `updateCapSurfaces` recut or restored
    /// onto the body's new identity tables: the selection, the agent's attention marker and the
    /// pending escalation's entities. `before` holds each such body's identity as the selection
    /// last saw it.
    ///
    /// A face, edge or vertex is replaced by every sub-shape of the new body with its origin
    /// (`CapOrigin`): itself, where the cut left it alone; its pieces, where the cut divided it;
    /// the whole sub-shape, where the cap was removed; and what the plane made from the same
    /// source sub-shape, where the cap moved. Each comes with the new table's ordinal and the new
    /// graph's uid, so `selection`, `selection.json`, the highlight, `agentAttention` and
    /// `pendingEscalation` all name the body as it is now drawn. One with no image has nothing on
    /// the body to name: the cap removed it, or it was the cap face or a section and the cap is
    /// gone, or it named something the old tables did not hold. It does not come back when the cap
    /// moves away again. A whole-body selection stays as it is.
    ///
    /// The marker and the escalation go first, so a subscriber to the selection change finds them
    /// already naming the new body. See `remapAgentAttention(onBody:from:to:)`,
    /// `remapPendingEscalation(onBody:from:to:)` and `remapSubShapeSelection(onBody:from:to:)` for
    /// what each does with an entity that has no image, or several.
    func remapSelection(acrossRecutOf before: [String: CapRecutIdentity]) {
        for bodyID in before.keys.sorted() {
            guard let old = before[bodyID], let new = capRecutIdentity(ofBody: bodyID) else {
                continue
            }
            remapAgentAttention(onBody: bodyID, from: old, to: new)
            remapPendingEscalation(onBody: bodyID, from: old, to: new)
            remapSubShapeSelection(onBody: bodyID, from: old, to: new)
        }
    }

    /// Carries `agentAttention`, when it is on body `bodyID`, onto the body's new tables
    /// (OCCTSwiftInteraction#85).
    ///
    /// The marker holds one entity, so a sub-shape the cut divided leaves it on the piece with the
    /// lowest ordinal: it stays on part of what the agent pointed at rather than vanishing. One
    /// with no image is cleared, label and all, as when its body is removed and as a selected
    /// sub-shape with no image leaves the selection. Keeping it undrawn instead would need the
    /// marker to hold a sub-shape the body does not have, which every host drawing it would have
    /// to special-case. The label stays with a marker that moves.
    private func remapAgentAttention(
        onBody bodyID: String, from old: CapRecutIdentity, to new: CapRecutIdentity
    ) {
        guard let attended = agentAttention, attended.bodyID == bodyID else { return }
        if let image = images(of: attended, from: old, to: new).first {
            agentAttention = image
        } else {
            setAgentAttention(nil)
        }
    }

    /// Carries the entities of `pendingEscalation` on body `bodyID` onto the body's new tables
    /// (OCCTSwiftInteraction#85).
    ///
    /// Each is replaced by all of its images, in place and in ordinal order, as a selected
    /// sub-shape is. One with no image leaves `entities`. The escalation itself stays pending with
    /// the same id, question, candidates and context, even with no entity left: a cap changes what
    /// is drawn, not the model, so it neither answers the question nor rejects it on the human's
    /// behalf, and the human can still answer by picking. Removing the body is what rejects it
    /// (`pruneEscalation(removingBodyIDs:)`), which also reads the bodies the escalation was
    /// presented about, so one left naming nothing on the body is still rejected when it goes.
    private func remapPendingEscalation(
        onBody bodyID: String, from old: CapRecutIdentity, to new: CapRecutIdentity
    ) {
        guard let request = pendingEscalation,
            request.entities.contains(where: { $0.bodyID == bodyID })
        else { return }
        var entities: [PickedEntity] = []
        for entity in request.entities {
            guard entity.bodyID == bodyID else {
                entities.append(entity)
                continue
            }
            entities += images(of: entity, from: old, to: new).filter { !entities.contains($0) }
        }
        pendingEscalation = EscalationRequest(
            id: request.id, entities: entities, question: request.question,
            candidates: request.candidates, context: request.context)
    }

    /// Remaps the selection on body `bodyID` onto the body's new tables (OCCTSwiftInteraction#77).
    ///
    /// A selected sub-shape with no image leaves the selection. Publishes one change for the body,
    /// as `.bodyRecut(bodyID:)`, when anything on it is selected, and carries the agent's tag
    /// (`agentHighlightedEntities`) from each remapped entity to its images. Replaces the selection
    /// with one assignment, so a sidecar sees no half-remapped selection. `syncSelection(with:)`
    /// takes every re-enriched entity from it, including one that compares equal to the entity it
    /// replaces (OCCTSwiftInteraction#85).
    private func remapSubShapeSelection(
        onBody bodyID: String, from old: CapRecutIdentity, to new: CapRecutIdentity
    ) {
        guard let objectID = bodyObjectIDs[bodyID] else { return }
        let current = interactiveContext.selection.subshapes
        let onBody = current.filter { $0.object.id == objectID && $0.ref != nil }
        guard let fallbackShape = onBody.first?.object.shape else { return }

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

    /// The entities of the new body that `entity`, an entity of the old one, maps to, in ordinal
    /// order and enriched as a selection made without a pick is.
    private func images(
        of entity: PickedEntity, from old: CapRecutIdentity, to new: CapRecutIdentity
    ) -> [PickedEntity] {
        let bodyID = entity.bodyID
        switch entity {
        case .face(let info):
            return Self.images(of: info.ref, .face, from: old, to: new).compactMap {
                enrichFace(ref: $0, bodyID: bodyID, triangleIndex: nil).map(PickedEntity.face)
            }
        case .edge(let info):
            return Self.images(of: info.ref, .edge, from: old, to: new).compactMap {
                enrichEdge(ref: $0, bodyID: bodyID).map(PickedEntity.edge)
            }
        case .vertex(let info):
            return Self.images(of: info.ref, .vertex, from: old, to: new).compactMap {
                enrichVertex(ref: $0, bodyID: bodyID, renderPosition: nil).map(PickedEntity.vertex)
            }
        }
    }

    /// The sub-shapes of `new` that `subShape`, a sub-shape of `old`, maps to.
    private static func images(
        of subShape: OCCTSwiftTools.SubShape, from old: CapRecutIdentity, to new: CapRecutIdentity,
        rebindingTo object: OCCTSwiftTools.InteractiveObject
    ) -> [OCCTSwiftTools.SubShape] {
        switch subShape {
        case .body:
            return [subShape]
        case .face(_, let ref):
            return images(of: ref, .face, from: old, to: new).map { .face(object, ref: $0) }
        case .edge(_, let ref):
            return images(of: ref, .edge, from: old, to: new).map { .edge(object, ref: $0) }
        case .vertex(_, let ref):
            return images(of: ref, .vertex, from: old, to: new).map { .vertex(object, ref: $0) }
        }
    }

    /// The refs of `new` that `ref`, a sub-shape of `kind` in `old`, maps to, in ordinal order:
    /// the sub-shapes of `new` with its origin.
    private static func images(
        of ref: SubShapeRef, _ kind: ShapeType, from old: CapRecutIdentity,
        to new: CapRecutIdentity
    ) -> [SubShapeRef] {
        guard let ordinal = old.ordinal(of: ref, kind),
            let origin = old.origin(of: kind, at: ordinal), let table = new.table(kind)
        else { return [] }
        return new.ordinals(of: kind, withOrigin: origin).compactMap { image in
            guard let shape = table.shapes[image] else { return nil }
            return SubShapeRef(shape: shape, uid: table.uids?[image], ordinal: image)
        }
    }
}
