// FaceIdentityTable.swift
// OCCTSwiftTools
//
// Face-ordinal identity captured at ViewportBody tessellation time (issue #42).

import OCCTSwift

/// Maps a render-path face ordinal (the value stored in `ViewportBody.faceIndices` /
/// `CADBodyMetadata.faceIndices`) back to the `Shape` (and, when available, the durable
/// `GraphUID`) it was tessellated from.
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
