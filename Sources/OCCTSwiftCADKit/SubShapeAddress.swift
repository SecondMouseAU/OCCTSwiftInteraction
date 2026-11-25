// SubShapeAddress.swift
// OCCTSwiftCADKit
//
// OCCTSwiftInteraction#81: naming a face, edge or vertex of a loaded body by body id, kind and
// ordinal, for a host that knows it from its own model rather than from a pick.

import OCCTSwift

/// A face, edge or vertex of a loaded body, named by the body's id, its kind and its ordinal in the
/// body's identity table **as loaded**.
///
/// The ordinal indexes the tables `CADViewportService.loadedIdentity(ofBody:)` returns: the
/// `ShapeIdentity` of the shape the body was loaded from. That is the numbering a host's own
/// `ShapeIdentity(shape:)` of the same shape gives, and the one a cap does not change. It is not
/// the numbering `CADViewportService.selection` reports while a cap is active (`faceIndex`,
/// `edgeIndex`, `vertexIndex`, `selection.json`'s `index`), which is the cut body's as it is
/// drawn, renumbered by every recut. `CADViewportService.select(_:scheme:)` and
/// `pickedEntities(at:)` map an address onto the body as drawn when they are called.
public struct SubShapeAddress: Sendable, Hashable {
    /// Which kind of sub-shape an address names.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case face
        case edge
        case vertex
    }

    /// The id of the body, as `PickedEntity.bodyID` reports it: the entity id for a shape loaded
    /// with `load(_:id:)`, or `"<id>-<n>"` for the bodies of a file loaded with `loadFile(from:id:)`.
    public var bodyID: String
    public var kind: Kind
    /// The sub-shape's index in the body's table of `kind`, as loaded.
    public var ordinal: Int

    public init(bodyID: String, kind: Kind, ordinal: Int) {
        self.bodyID = bodyID
        self.kind = kind
        self.ordinal = ordinal
    }
}

extension SubShapeAddress.Kind {
    /// The OCCT shape type of this kind.
    var shapeType: ShapeType {
        switch self {
        case .face: .face
        case .edge: .edge
        case .vertex: .vertex
        }
    }
}
