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
/// So a face shared between two shells is **one** entry in `shapes`, not two. That it bounds two
/// solids is a fact about the model rather than two selectable things. A caller needing to know
/// which use of a shared face was picked reads orientation off the returned `Shape`, which is
/// OCCT's own answer (`StdSelect_BRepOwner` carries the shape, never an ordinal) rather than a
/// second enumeration.
///
/// The mesher still walks face occurrences, so a shared face is tessellated once per owning shell,
/// each wound for its own outside, and **both** triangulations carry the one deduplicated ordinal.
/// Two triangles with the same ordinal can therefore be different geometry belonging to different
/// shells, and they resolve to one identity. That is the intended behaviour, not a collision.
///
/// This table is also the reason the ordinal is durable at all. OCCT attaches the `TopoDS_Shape`
/// to the sensitive entity when selection is computed, because its selection data is a CPU-side
/// structure; ours is a GPU buffer of triangles, so the attachment has to happen at tessellation
/// time instead. That is what this type is, rather than an index-caching optimisation.
///
/// Consumers have historically resolved a triangle's face ordinal via
/// `shape.subShapes(ofType: .face)[ordinal]`. Before OCCTSwift v2.0.0, that assumed the
/// render-path ordinal, which walked faces via the same raw, non-deduplicating
/// `TopExp_Explorer` traversal `Shape.faces()` used, lined up with `subShapes(ofType:)`'s
/// independently deduplicated enumeration and with a `BRepGraph`'s own node ordering. All three
/// agreed on a single clean solid but diverged once a face was shared between two shells: the
/// graph collapsed it to one node, `subShapes(ofType:)` collapsed it to one entry (shifting every
/// later index), while the render path and `Shape.faces()` still visited it once per shell.
///
/// OCCTSwift v2.0.0 (#541/#613) closed that specific divergence upstream: `Shape.faces()` is now
/// itself the deduplicated enumeration, and `Mesh.Triangle.faceIndex` moved onto that same
/// enumeration in the same release, so a shared face's two shell-local triangulations now carry
/// one index, matching `Shape.faces()`'s one entry for it. `FaceIdentityTable` needed no source
/// change for the bump (it already reads `shape.faces()` dynamically), and it still earns its
/// keep: it captures the ordinal-to-`Shape`-to-`GraphUID` correspondence once at tessellation
/// time rather than asking a consumer to re-walk `shape.faces()` per pick, and `GraphUID`
/// resolution is an identity lookup (`graph.findNode(for:)`) that never assumed index
/// correspondence with the graph's own node numbering in the first place.
///
/// See the durable identity cookbook (`topology-graph-uids.md`).
public struct FaceIdentityTable: Sendable {
    /// Indexed by the ordinal stored in `ViewportBody.faceIndices` / `CADBodyMetadata.faceIndices`.
    ///
    /// Built from `Shape.faces()`, the same enumeration the mesher uses to assign that ordinal,
    /// so `shapes[ordinal]` is always the exact face tessellated into the triangles carrying that
    /// ordinal.
    public let shapes: [Shape]

    /// Durable per-ordinal handle, minted from the `BRepGraph` supplied when the table was built.
    ///
    /// `nil` when no graph was supplied. When present, an individual element is `nil` only if
    /// that ordinal's face could not be resolved in the graph.
    public let uids: [BRepGraph.GraphUID?]?

    public init(shapes: [Shape], uids: [BRepGraph.GraphUID?]? = nil) {
        self.shapes = shapes
        self.uids = uids
    }

    /// The `Shape` a render-path face ordinal was tessellated from.
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
