// FaceIdentityTable.swift
// OCCTSwiftTools
//
// Face-ordinal identity captured at ViewportBody tessellation time (issue #42).

import OCCTSwift

/// Maps a render-path face ordinal (the value stored in `ViewportBody.faceIndices` /
/// `CADBodyMetadata.faceIndices`) back to the `Shape` (and, when available, the durable
/// `GraphUID`) it was tessellated from.
///
/// ## What identity means here (OCCTSwiftInteraction#1, settled)
///
/// Face identity keys on OCCT's `TopoDS_Shape::IsSame`: same `TShape`, same `Location`,
/// orientation may differ. That is a comparison semantic, not a choice of function, and the
/// enumeration follows from it: `Shape.faces()`, deduplicated through
/// `TopTools_IndexedMapOfShape`, is `IsSame` and is what this table is built from.
/// `orientedFaces()` is occurrence-based (`IsEqual`) and is deliberately NOT an identity here.
///
/// So a face shared between two shells is **one** entry in `shapes`, not two, and both of its
/// shell-local triangulations carry that one ordinal. Encode this rather than re-deciding it.
///
/// The reasoning behind all of that, why these tables exist at all rather than being an
/// index-caching optimisation, how the three tables differ, and the pre-v2.0.0 face-enumeration
/// divergence a consumer may still be carrying assumptions about, are in the durable identity
/// cookbook rather than repeated here and in the two sibling tables.
///
/// See the durable identity cookbook (`topology-graph-uids.md`).
public struct FaceIdentityTable: Sendable {
    /// Indexed by the ordinal stored in `ViewportBody.faceIndices` / `CADBodyMetadata.faceIndices`.
    ///
    /// Built from `Shape.faces()`, the same enumeration the mesher uses to assign that ordinal,
    /// so `shapes[ordinal]` is always the exact face tessellated into the triangles carrying that
    /// ordinal.
    ///
    /// An element is `nil` when that face's `Face` to `Shape` conversion failed. Optional so that
    /// the index space is the ordinal space by construction: a shorter array would silently move
    /// every later face down one and name the wrong one (OCCTSwiftInteraction#9). A `nil` entry
    /// costs that one ordinal its captured shape and its uid, and no other.
    public let shapes: [Shape?]

    /// Durable per-ordinal handle, minted from the `BRepGraph` supplied when the table was built.
    ///
    /// `nil` when no graph was supplied. When present, an individual element is `nil` if that
    /// ordinal's face could not be resolved in the graph, or has no entry in `shapes`.
    public let uids: [BRepGraph.GraphUID?]?

    public init(shapes: [Shape?], uids: [BRepGraph.GraphUID?]? = nil) {
        self.shapes = shapes
        self.uids = uids
    }

    /// The `Shape` a render-path face ordinal was tessellated from, or `nil` if the ordinal is out
    /// of range or its conversion failed when the table was built.
    public func shape(forOrdinal ordinal: Int) -> Shape? {
        shapes.indices.contains(ordinal) ? shapes[ordinal] : nil
    }

    /// The durable `GraphUID` a render-path face ordinal resolves to, if a graph was supplied
    /// when the table was built.
    public func uid(forOrdinal ordinal: Int) -> BRepGraph.GraphUID? {
        guard let uids, uids.indices.contains(ordinal) else { return nil }
        return uids[ordinal]
    }
}
