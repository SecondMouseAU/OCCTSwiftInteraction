---
title: EdgeIdentityTable
parent: API Reference
---

# EdgeIdentityTable

Maps a render-path edge ordinal, the value stored in `ViewportBody.edgeIndices`, back to the
`Shape` it was extracted from, and, when a `TopologyGraph` was supplied, to the durable `GraphUID`
minted from that graph. Mirrors [FaceIdentityTable](FaceIdentityTable), but for edges.

## Why it exists

Unlike the face ordinal, `ViewportBody.edgeIndices` is already keyed to `Shape.edge(at:)`'s index
space: `Shape.edge(at:)`, the bulk edge-polyline extractor behind `ViewportBody.edgeIndices`, and
`Shape.subShapes(ofType: .edge)` all build one deduplicating `TopTools_IndexedMapOfShape` over the
shape's edges, so a shared edge between two shells already collapses to a single ordinal there.
There is no raw-vs-deduplicated split to reconcile the way there is for faces.

`EdgeIdentityTable` still earns its keep for the same reasons `FaceIdentityTable` does: it captures
the ordinal to `Shape` to `GraphUID` correspondence once, at tessellation time, so a consumer
resolving an edge pick does not have to re-walk the shape's edge map itself
(`Shape.subShape(type:index:)` rebuilds it on every call), or hand-roll the
`graph.findNode(for:)` plus `graph.uid(ofNodeKind:index:)` resolution `FaceIdentityTable` already
does for faces. Edge identity also keeps working even if OCCT's edge traversal ever stopped
deduplicating the way it does today.

## API

```swift
public struct EdgeIdentityTable: Sendable {
    public let shapes: [Shape]
    public let uids: [TopologyGraph.GraphUID?]?

    public init(shapes: [Shape], uids: [TopologyGraph.GraphUID?]? = nil)
    public func shape(forOrdinal ordinal: Int) -> Shape?
    public func uid(forOrdinal ordinal: Int) -> TopologyGraph.GraphUID?
}
```

- `shapes` is indexed by the ordinal stored in `ViewportBody.edgeIndices`, built from `Shape.edges()`.
- `uids` is populated only when a `TopologyGraph` was supplied to the entry point that produced this table. Each element is `nil` if that ordinal's edge could not be resolved in the graph.
- `shape(forOrdinal:)` / `uid(forOrdinal:)` return `nil` for an out-of-range ordinal (or, for `uid(forOrdinal:)`, when no graph was supplied at all).

Obtained from [`CADFileLoader.shapeToBodyMetadataAndIdentities`](CADFileLoader#cadfileloadershapetobodymetadataandidentities).

## Example

```swift
let box = Shape.box(width: 10, height: 5, depth: 3)!
let graph = TopologyGraph(shape: box)!
let (body, meta, faceTable, edgeTable, vertexTable) = CADFileLoader.shapeToBodyMetadataAndIdentities(
    box, id: "box", color: SIMD4<Float>(0.6, 0.6, 0.65, 1), graph: graph
)
guard let body, let edgeTable else { return }

// Resolve a wireframe edge pick back to its Shape and durable GraphUID.
let pickedOrdinal = Int(body.edgeIndices[0])
let pickedEdge = edgeTable.shape(forOrdinal: pickedOrdinal)
let pickedUID = edgeTable.uid(forOrdinal: pickedOrdinal)
```
