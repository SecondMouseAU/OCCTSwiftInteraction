// EdgeIdentityTable.swift
// OCCTSwiftTools
//
// Edge-ordinal identity captured at ViewportBody tessellation time (issue #43).

import OCCTSwift

/// Maps a render-path edge ordinal (the value stored in `ViewportBody.edgeIndices`) back to the
/// `Shape` (and, when available, the durable `GraphUID`) it was extracted from.
///
/// Mirrors `FaceIdentityTable`, but for edges. Unlike the face ordinal, which is assigned by a raw,
/// non-deduplicating `TopExp_Explorer` walk that visits a face once per shell it belongs to,
/// `ViewportBody.edgeIndices` is already keyed to `Shape.edge(at:)`'s index space: both
/// `Shape.edge(at:)` and the bulk polyline extractor behind it build one `TopTools_IndexedMapOfShape`
/// over the shape's edges, so a shared edge collapses to a single ordinal there, the same as it does
/// in `Shape.subShapes(ofType: .edge)` and in a `TopologyGraph`. There is no raw-vs-deduplicated split
/// to reconcile the way there is for faces.
///
/// `EdgeIdentityTable` exists for the same reasons `FaceIdentityTable` does anyway: it captures the
/// ordinal to `Shape` to `GraphUID` correspondence once, at tessellation time, so a consumer resolving
/// an edge pick doesn't have to re-walk the shape's edge map itself (`Shape.subShape(type:index:)`
/// rebuilds it on every call), or hand-roll the `graph.findNode(for:)` plus `graph.uid(ofNodeKind:index:)`
/// resolution `FaceIdentityTable` already does for faces. It also means edge identity keeps working
/// even if OCCT's edge traversal ever stopped deduplicating the way it does today.
public struct EdgeIdentityTable: Sendable {
    /// Indexed by the ordinal stored in `ViewportBody.edgeIndices`. Built from `Shape.edges()`,
    /// the same `TopTools_IndexedMapOfShape` traversal `Shape.edge(at:)` and the bulk edge-polyline
    /// extractor use, so `shapes[ordinal]` is always the exact edge behind the segments carrying
    /// that ordinal.
    public let shapes: [Shape]

    /// Durable per-ordinal handle, minted from the `TopologyGraph` supplied when the table was
    /// built. `nil` when no graph was supplied. When present, an individual element is `nil`
    /// only if that ordinal's edge could not be resolved in the graph.
    public let uids: [TopologyGraph.GraphUID?]?

    public init(shapes: [Shape], uids: [TopologyGraph.GraphUID?]? = nil) {
        self.shapes = shapes
        self.uids = uids
    }

    /// The `Shape` a render-path edge ordinal was extracted from.
    public func shape(forOrdinal ordinal: Int) -> Shape? {
        shapes.indices.contains(ordinal) ? shapes[ordinal] : nil
    }

    /// The durable `GraphUID` a render-path edge ordinal resolves to, if a graph was supplied
    /// when the table was built.
    public func uid(forOrdinal ordinal: Int) -> TopologyGraph.GraphUID? {
        guard let uids, uids.indices.contains(ordinal) else { return nil }
        return uids[ordinal]
    }
}
