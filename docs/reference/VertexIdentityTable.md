---
title: VertexIdentityTable
parent: API Reference
---

# VertexIdentityTable

Maps a render-path vertex ordinal, the value stored in `ViewportBody.vertexIndices`, back to the
`Shape` it was extracted from, and, when a `BRepGraph` was supplied, to the durable `GraphUID`
minted from that graph. Mirrors [FaceIdentityTable](FaceIdentityTable) and
[EdgeIdentityTable](EdgeIdentityTable), but for vertices.

## Why it exists

`ViewportBody.vertexIndices` is the sequential index into `Shape.vertices()`, which (like
`Shape.edges()`) is built from one deduplicating `TopTools_IndexedMapOfShape` over the shape's
vertices, the same map `Shape.vertex(at:)` and `Shape.subShapes(ofType: .vertex)` use. A shared
vertex between two shells already collapses to a single ordinal there.

`VertexIdentityTable` still earns its keep for the same reasons `EdgeIdentityTable` does: it
captures the ordinal to `Shape` to `GraphUID` correspondence once, at tessellation time, so a
consumer resolving a vertex pick does not have to re-walk the shape's vertex map itself, or
hand-roll the `graph.findNode(for:)` plus `graph.uid(ofNodeKind:index:)` resolution
`FaceIdentityTable` already does for faces.

## API

```swift
public struct VertexIdentityTable: Sendable {
    public let shapes: [Shape]
    public let uids: [BRepGraph.GraphUID?]?

    public init(shapes: [Shape], uids: [BRepGraph.GraphUID?]? = nil)
    public func shape(forOrdinal ordinal: Int) -> Shape?
    public func uid(forOrdinal ordinal: Int) -> BRepGraph.GraphUID?
}
```

- `shapes` is indexed by the ordinal stored in `ViewportBody.vertexIndices`, built from `Shape.subShapes(ofType: .vertex)`.
- `uids` is populated only when a `BRepGraph` was supplied to the entry point that produced this table. Each element is `nil` if that ordinal's vertex could not be resolved in the graph.
- `shape(forOrdinal:)` / `uid(forOrdinal:)` return `nil` for an out-of-range ordinal (or, for `uid(forOrdinal:)`, when no graph was supplied at all).

Obtained from [`CADFileLoader.shapeToBodyMetadataAndIdentities`](CADFileLoader#cadfileloadershapetobodymetadataandidentities).

## Example

```swift
let box = Shape.box(width: 10, height: 5, depth: 3)!
let graph = BRepGraph(shape: box)!
let (body, meta, faceTable, edgeTable, vertexTable) = CADFileLoader.shapeToBodyMetadataAndIdentities(
    box, id: "box", color: SIMD4<Float>(0.6, 0.6, 0.65, 1), graph: graph
)
guard let body, let vertexTable else { return }

// Resolve a B-Rep vertex pick back to its Shape and durable GraphUID.
let pickedOrdinal = Int(body.vertexIndices[0])
let pickedVertex = vertexTable.shape(forOrdinal: pickedOrdinal)
let pickedUID = vertexTable.uid(forOrdinal: pickedOrdinal)
```
