// CADViewportService+SubShapeAddress.swift
// OCCTSwiftCADKit
//
// OCCTSwiftInteraction#81: selecting faces, edges and vertices a host already knows by body id,
// kind and ordinal (from its own model, not from a pick), several at once and as one change.

import Foundation
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools

@MainActor
extension CADViewportService {

    // MARK: - Sub-shapes known by address

    /// The identity of body `bodyID` as it was loaded: the shape it was loaded from, that shape's
    /// graph, and its face, edge and vertex tables. `nil` for a body this service has not loaded.
    ///
    /// The tables are the ordinal space a `SubShapeAddress` names, so a host that looks a
    /// sub-shape up in them (by geometry, say) has the ordinal to address it by, without building a
    /// `ShapeIdentity` of its own. The graph is the one `load(_:id:graph:transform:)` was given, or
    /// the one the service minted when it was given none.
    ///
    /// **A cap does not change this.** A cap-enabled clipping plane recuts the body and gives the
    /// body as drawn new tables and a new graph, but this stays the identity of the shape as loaded
    /// until the body is reloaded or removed, so a host can keep what it read across any number of
    /// recuts. The tables of the body as drawn stay internal: they are renumbered by every recut,
    /// and every entry point that takes an address maps it onto them when it is called.
    ///
    /// While a cap is active, the ordinals and uids `selection` and `selection.json` report are
    /// the cut body's, not these. Once the cap is removed the ordinals agree again, but the uids
    /// stay those of the graph the restore minted for the body as drawn.
    public func loadedIdentity(ofBody bodyID: String) -> ShapeIdentity? {
        loadedIdentities[bodyID]
    }

    /// The sub-shapes `address` names on the body as drawn now, each enriched exactly as a viewport
    /// pick of it is (`description`, bounds, area, curve type, length, position and the rest).
    ///
    /// For a host that needs the `PickedEntity` itself: to show its description before selecting
    /// it, to point at it with `setAgentAttention(_:label:)`, or to put it in an
    /// `EscalationRequest`.
    ///
    /// - One entity when the body is uncut, or a cap left the sub-shape alone.
    /// - One per piece where a cap divided it.
    /// - None where a cap removed it, for a body this service has not loaded, for an ordinal
    ///   outside the body's table, and for a sub-shape whose geometry gives nothing to describe a
    ///   pick by (a face with no bounding box).
    ///
    /// Each entity names the body as drawn, as a pick does: its `faceIndex`, `edgeIndex` or
    /// `vertexIndex` and its `uid` are the current tables'. The ordinal differs from
    /// `address.ordinal` while a cap is active, and the uid from the loaded graph's once a cap has
    /// cut the body. A `.perTriangle` scalar field gives a face
    /// no `scalarValue`, since there is no picked triangle to sample, as for area selection.
    public func pickedEntities(at address: SubShapeAddress) -> [PickedEntity] {
        refs(at: address).compactMap { ref in
            switch address.kind {
            case .face:
                enrichFace(ref: ref, bodyID: address.bodyID, triangleIndex: nil).map(
                    PickedEntity.face)
            case .edge:
                enrichEdge(ref: ref, bodyID: address.bodyID).map(PickedEntity.edge)
            case .vertex:
                enrichVertex(ref: ref, bodyID: address.bodyID, renderPosition: nil).map(
                    PickedEntity.vertex)
            }
        }
    }

    /// Combines every entity in `entities` with the selection per `scheme`, as one change.
    ///
    /// The rules of `select(_:scheme:)` applied to the whole list at once, through the interactive
    /// context's set overload, so the selection is assigned once: `selectionChanges` publishes one
    /// change (`.programmatic`), the highlight is cut once, and the selection sidecar writes
    /// `selection.json` once. A run of single `select(_:scheme:)` calls does each of those once per
    /// entity, and the sidecar writes every partial selection on the way.
    ///
    /// The list is a set: an entity listed twice counts once, so `.xor` toggles it once. An empty
    /// list with `.replace` clears the selection; with any other scheme it changes nothing and
    /// publishes nothing.
    public func select(_ entities: [PickedEntity], scheme: SelectionScheme = .replace) {
        guard !entities.isEmpty || scheme == .replace else { return }
        var subShapes: Set<OCCTSwiftTools.SubShape> = []
        for entity in entities {
            let subShape = subShape(for: entity)
            // Before delegating, as `select(_:scheme:)` does, so the `$selection` sink finds each
            // enrichment cached.
            selectionInfo[subShape] = entity
            subShapes.insert(subShape)
        }
        interactiveContext.select(subShapes, scheme: scheme)
    }

    /// Combines the sub-shapes `addresses` name with the selection per `scheme`, as one change,
    /// and returns the addresses that name nothing.
    ///
    /// Each address is mapped onto the body as drawn when this is called, as `pickedEntities(at:)`
    /// maps it, so it selects the sub-shape itself, or its pieces while a cap divides it. The
    /// selection then holds exactly what a viewport pick of each would put there. Then
    /// `select(_:scheme:)` over the resulting entities applies them as one change: one
    /// `selectionChanges` publication, one highlight rebuild, one `selection.json` write.
    ///
    /// **An address that names nothing is skipped, not fatal.** The rest are applied, and the
    /// skipped ones come back, in the order given: an unknown body, an ordinal outside the body's
    /// table, or a sub-shape a cap has removed. The scheme applies to what was found, so with
    /// `.replace` and nothing found the selection is cleared, and with any other scheme nothing
    /// changes. A hollow clipping plane removes nothing from a body, so a sub-shape behind one
    /// still selects, as does one on a hidden body (whose highlight lights nothing).
    @discardableResult
    public func select(_ addresses: [SubShapeAddress], scheme: SelectionScheme = .replace)
        -> [SubShapeAddress]
    {
        var entities: [PickedEntity] = []
        var unresolved: [SubShapeAddress] = []
        for address in addresses {
            let found = pickedEntities(at: address)
            if found.isEmpty { unresolved.append(address) }
            entities += found
        }
        select(entities, scheme: scheme)
        return unresolved
    }

    /// The refs of the sub-shapes `address` names on the body as drawn now.
    ///
    /// An address names the body as loaded, which is the cut body's `CapOrigin.source`, so its
    /// images are the current table's ordinals with that origin: the one remap rule the selection
    /// follows across a recut (`remapSelection(acrossRecutOf:)`), applied here from the uncut
    /// body. With no cap the origin of each ordinal is itself, so an ordinal outside the table,
    /// negative included, has no image either way.
    private func refs(at address: SubShapeAddress) -> [OCCTSwiftTools.SubShapeRef] {
        let kind = address.kind.shapeType
        guard let identity = capRecutIdentity(ofBody: address.bodyID),
            let table = identity.table(kind)
        else { return [] }
        let source = CapOrigin.source(kind: kind, ordinal: address.ordinal)
        return identity.ordinals(of: kind, withOrigin: source).compactMap { ordinal in
            table.shapes[ordinal].map {
                OCCTSwiftTools.SubShapeRef(shape: $0, uid: table.uids?[ordinal], ordinal: ordinal)
            }
        }
    }
}
