---
title: FaceIdentityTable
parent: API Reference
---

# FaceIdentityTable

Maps a render-path face ordinal, the value stored in `ViewportBody.faceIndices` and mirrored in
`CADBodyMetadata.faceIndices`, back to the `Shape` it was tessellated from, and, when a
`BRepGraph` was supplied, to the durable `GraphUID` minted from that graph.

## Why it exists

Before OCCTSwift v2.0.0, the mesher assigned `Mesh.Triangle.faceIndex` by walking faces with a
raw, non-deduplicating `TopExp_Explorer` traversal, the same one `Shape.faces()` used.
`Shape.subShapes(ofType: .face)` and a `BRepGraph`'s node ordering both deduplicated instead: a
face shared between two shells collapsed to one entry there. The two enumerations agreed on a
clean single solid and silently diverged, shifting every later index, once a face was shared
between shells. Resolving a face ordinal via `shape.subShapes(ofType: .face)[ordinal]` assumed
they agreed and could silently name the wrong face. `FaceIdentityTable` captures the
correspondence directly at tessellation time instead of asking a consumer to reconstruct it from
a mismatched enumeration.

**As of OCCTSwift v2.0.0** ([#541](https://github.com/SecondMouseAU/OCCTSwift/issues/541) and
[#613](https://github.com/SecondMouseAU/OCCTSwift/issues/613)), that specific divergence is closed
upstream: `Shape.faces()` is itself now the deduplicated enumeration, and `Mesh.Triangle.faceIndex`
moved onto that same enumeration in the same release. A shared face's two shell-local
triangulations now carry the one index that names it, matching the single entry `Shape.faces()`
returns for it. `FaceIdentityTable` needed no source change for the bump (it reads `Shape.faces()`
dynamically, not a hardcoded traversal) and still earns its keep: it saves a consumer from
re-walking `Shape.faces()` on every pick, and `GraphUID` resolution is an identity lookup
(`graph.findNode(for:)`) that never assumed index correspondence with the graph's own node
numbering to begin with.

See also [EdgeIdentityTable](EdgeIdentityTable) and [VertexIdentityTable](VertexIdentityTable),
which mirror this table for `ViewportBody.edgeIndices` / `vertexIndices`.

## API

```swift
public struct FaceIdentityTable: Sendable {
    public let shapes: [Shape]
    public let uids: [BRepGraph.GraphUID?]?

    public init(shapes: [Shape], uids: [BRepGraph.GraphUID?]? = nil)
    public func shape(forOrdinal ordinal: Int) -> Shape?
    public func uid(forOrdinal ordinal: Int) -> BRepGraph.GraphUID?
}
```

- `shapes` is indexed by the ordinal stored in `ViewportBody.faceIndices` / `CADBodyMetadata.faceIndices`, built from `Shape.faces()` so it always names the exact face tessellated into the triangles carrying that ordinal.
- `uids` is populated only when a `BRepGraph` was supplied to the entry point that produced this table. Each element is `nil` if that ordinal's face could not be resolved in the graph.
- `shape(forOrdinal:)` / `uid(forOrdinal:)` return `nil` for an out-of-range ordinal (or, for `uid(forOrdinal:)`, when no graph was supplied at all).

Obtained from [`CADFileLoader.shapeToBodyMetadataAndIdentity`](CADFileLoader#cadfileloadershapetobodymetadataandidentity) or [`shapeToBodyMetadataAndIdentities`](CADFileLoader#cadfileloadershapetobodymetadataandidentities).

## Example

```swift
let box = Shape.box(width: 10, height: 5, depth: 3)!
let graph = BRepGraph(shape: box)!
let (body, meta, faceTable) = CADFileLoader.shapeToBodyMetadataAndIdentity(
    box, id: "box", color: SIMD4<Float>(0.6, 0.6, 0.65, 1), graph: graph
)
guard let body, let faceTable else { return }

// Resolve a GPU face pick back to its Shape and durable GraphUID.
let pickedOrdinal = Int(body.faceIndices[0])
let pickedFace = faceTable.shape(forOrdinal: pickedOrdinal)
let pickedUID = faceTable.uid(forOrdinal: pickedOrdinal)
```
