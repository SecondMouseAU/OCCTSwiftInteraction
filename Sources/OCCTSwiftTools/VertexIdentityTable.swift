// VertexIdentityTable.swift
// OCCTSwiftTools
//
// Vertex-ordinal identity captured at ViewportBody tessellation time (issue #43).

import OCCTSwift

/// Maps a render-path vertex ordinal (the value stored in `ViewportBody.vertexIndices`) back to
/// the `Shape` (and, when available, the durable `GraphUID`) it was extracted from.
///
/// Mirrors `FaceIdentityTable` and `EdgeIdentityTable`, but for vertices. `ViewportBody.vertexIndices`
/// is the sequential index into `Shape.vertices()`, which (like `Shape.edges()`) is built from one
/// `TopTools_IndexedMapOfShape` over the shape's vertices, the same map `Shape.vertex(at:)` and
/// `Shape.subShapes(ofType: .vertex)` use, so a shared vertex between two shells already collapses to
/// a single ordinal there.
///
/// `VertexIdentityTable` exists for the same reasons `EdgeIdentityTable` does: it captures the
/// ordinal to `Shape` to `GraphUID` correspondence once, at tessellation time, so a consumer resolving
/// a vertex pick doesn't have to re-walk the shape's vertex map itself, or hand-roll the
/// `graph.findNode(for:)` plus `graph.uid(ofNodeKind:index:)` resolution `FaceIdentityTable` already
/// does for faces.
public struct VertexIdentityTable: Sendable {
    /// Indexed by the ordinal stored in `ViewportBody.vertexIndices`. Built from
    /// `Shape.subShapes(ofType: .vertex)`, the same `TopTools_IndexedMapOfShape` traversal
    /// `Shape.vertices()` / `Shape.vertex(at:)` use, so `shapes[ordinal]` is always the exact
    /// vertex behind the pick point carrying that ordinal.
    public let shapes: [Shape]

    /// Durable per-ordinal handle, minted from the `TopologyGraph` supplied when the table was
    /// built. `nil` when no graph was supplied. When present, an individual element is `nil`
    /// only if that ordinal's vertex could not be resolved in the graph.
    public let uids: [TopologyGraph.GraphUID?]?

    public init(shapes: [Shape], uids: [TopologyGraph.GraphUID?]? = nil) {
        self.shapes = shapes
        self.uids = uids
    }

    /// The `Shape` a render-path vertex ordinal was extracted from.
    public func shape(forOrdinal ordinal: Int) -> Shape? {
        shapes.indices.contains(ordinal) ? shapes[ordinal] : nil
    }

    /// The durable `GraphUID` a render-path vertex ordinal resolves to, if a graph was supplied
    /// when the table was built.
    public func uid(forOrdinal ordinal: Int) -> TopologyGraph.GraphUID? {
        guard let uids, uids.indices.contains(ordinal) else { return nil }
        return uids[ordinal]
    }
}
