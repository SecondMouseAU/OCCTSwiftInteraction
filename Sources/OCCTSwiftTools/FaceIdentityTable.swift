// FaceIdentityTable.swift
// OCCTSwiftTools
//
// Face-ordinal identity captured at ViewportBody tessellation time (issue #42).

import OCCTSwift

/// Maps a render-path face ordinal — the value stored in `ViewportBody.faceIndices` /
/// `CADBodyMetadata.faceIndices` — back to the `Shape` (and, when available, the durable
/// `GraphUID`) it was tessellated from.
///
/// Consumers have historically resolved a triangle's face ordinal via
/// `shape.subShapes(ofType: .face)[ordinal]`. That assumes the render-path ordinal — which
/// walks faces via the same raw, non-deduplicating `TopExp_Explorer` traversal `Shape.faces()`
/// uses — lines up with `subShapes(ofType:)`'s deduplicated enumeration and with a
/// `BRepGraph`'s own node ordering. All three agree on a single clean solid but diverge
/// once a face is shared between two shells: the graph collapses it to one node,
/// `subShapes(ofType:)` collapses it to one entry (shifting every later index), while the
/// render path — and `Shape.faces()` — still visit it once per shell.
///
/// `FaceIdentityTable` captures the correspondence directly at tessellation time instead of
/// asking a consumer to reconstruct it from a mismatched enumeration. See the durable identity
/// cookbook (`topology-graph-uids.md`).
public struct FaceIdentityTable: Sendable {
    /// Indexed by the ordinal stored in `ViewportBody.faceIndices` /
    /// `CADBodyMetadata.faceIndices`. Built from `Shape.faces()` — the same traversal the
    /// mesher uses to assign that ordinal — so `shapes[ordinal]` is always the exact face
    /// tessellated into the triangles carrying that ordinal.
    public let shapes: [Shape]

    /// Durable per-ordinal handle, minted from the `BRepGraph` supplied when the table was
    /// built. `nil` when no graph was supplied. When present, an individual element is `nil`
    /// only if that ordinal's face could not be resolved in the graph.
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
