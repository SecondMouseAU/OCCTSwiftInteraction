import Foundation
import OCCTSwift
import OCCTSwiftTools

extension InteractiveContext {

    /// Remap a `Selection` whose sub-shapes were captured against an earlier
    /// shape state into a new `Selection` against `newObject`, using history
    /// absorbed into `graph` via `BRepGraph.add(_:absorbing:inputRoots:operationName:)`.
    ///
    /// Resolution goes entirely through each sub-shape's durable `GraphUID`,
    /// never a stored ordinal, so there is no index-correlation guesswork:
    /// `BRepGraph.node(forUID:)` rejects a uid that didn't come from
    /// `graph` itself, so a sub-shape can never resolve to a coincidentally
    /// matching but wrong neighbour the way a raw-index lookup could. A
    /// `.face`/`.edge`/`.vertex` sub-shape with no `uid` at all (no graph was
    /// in hand at pick time) is dropped: there's nothing durable to resolve
    /// it by.
    ///
    /// - **1 → 1** (sub-shape modified in place): the result carries the same
    ///   node, re-resolved to its current index and a freshly minted uid.
    /// - **1 → N** (e.g. a face split by a cut): expands to N sub-shapes, one
    ///   per live successor.
    /// - **1 → 0** (deleted): dropped silently. Call `isDeleted(_:in:)` first
    ///   (same `graph`) to tell a deletion from a sub-shape that was simply
    ///   never selected.
    ///
    /// `.body(_)` sub-shapes always rebind to `newObject`: the body-level
    /// concept is identity-stable across mutations by construction.
    ///
    /// Every successor gets its render-path `ordinal` from `newObject`'s
    /// identity table for that kind (matched by uid) when `newObject` is
    /// displayed in this context; otherwise the ordinal falls back to the
    /// graph's own node index, which is *not* a tessellation ordinal and
    /// should not be used to index a `ViewportBody`'s per-triangle buffers.
    public func remap(
        _ selection: Selection,
        using graph: BRepGraph,
        rebindingTo newObject: InteractiveObject
    ) -> Selection {
        let faceUIDs = faceIdentityTable(for: newObject)?.uids
        let edgeUIDs = edgeIdentityTable(for: newObject)?.uids
        let vertexUIDs = vertexIdentityTable(for: newObject)?.uids
        var result: Set<SubShape> = []
        for sub in selection.subshapes {
            switch sub {
            case .body:
                result.insert(.body(newObject))

            case .face(_, let ref):
                for successor in remapRef(ref, kind: .face, graph: graph, uids: faceUIDs) {
                    result.insert(.face(newObject, ref: successor))
                }

            case .edge(_, let ref):
                for successor in remapRef(ref, kind: .edge, graph: graph, uids: edgeUIDs) {
                    result.insert(.edge(newObject, ref: successor))
                }

            case .vertex(_, let ref):
                for successor in remapRef(ref, kind: .vertex, graph: graph, uids: vertexUIDs) {
                    result.insert(.vertex(newObject, ref: successor))
                }
            }
        }
        return Selection(result)
    }

    /// Whether `subshape's` durable node was explicitly consumed by history
    /// absorbed into `graph`, as opposed to simply never being mentioned by
    /// any recorded operation.
    ///
    /// Distinguishes "the operation deleted this" from "this wasn't touched"
    /// / "this wasn't selected", which `remap's` silent drop can't on its own
    /// (see `BRepGraph.historyIsDeleted(_:)`).
    ///
    /// `.body` sub-shapes and sub-shapes with no `uid`, or whose `uid` isn't
    /// `graph's` own, always return `false`: there's no node in `graph` to
    /// ask about.
    public func isDeleted(_ subshape: SubShape, in graph: BRepGraph) -> Bool {
        guard let ref = subshape.ref, let uid = ref.uid,
            let node = graph.node(forUID: uid)
        else { return false }
        let kind: BRepGraph.NodeKind
        switch subshape {
        case .body: return false
        case .face: kind = .face
        case .edge: kind = .edge
        case .vertex: kind = .vertex
        }
        return graph.historyIsDeleted(BRepGraph.NodeRef(kind: kind, index: node.index))
    }

    private func remapRef(
        _ ref: SubShapeRef,
        kind: BRepGraph.NodeKind,
        graph: BRepGraph,
        uids: [BRepGraph.GraphUID?]?
    ) -> [SubShapeRef] {
        guard let uid = ref.uid, let node = graph.node(forUID: uid) else { return [] }
        let original = BRepGraph.NodeRef(kind: kind, index: node.index)
        let successors = graph.findDerivedOrSelf(of: original).filter { $0.kind == kind }
        return successors.compactMap { successor in
            guard let shape = graph.shape(nodeKind: successor.kind, nodeIndex: successor.index)
            else {
                return nil
            }
            let newUID = graph.uid(ofNodeKind: Int(successor.kind.rawValue), index: successor.index)
            var ordinal = successor.index
            if let newUID, let matched = uids?.firstIndex(of: newUID) {
                ordinal = matched
            }
            return SubShapeRef(shape: shape, uid: newUID, ordinal: ordinal)
        }
    }
}
