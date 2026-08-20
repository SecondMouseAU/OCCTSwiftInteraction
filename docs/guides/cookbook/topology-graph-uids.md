---
title: Durable identity and GraphUIDs
parent: Cookbook
nav_order: 8
---

# Durable identity and GraphUIDs

A pick arrives from the renderer as an **ordinal**: a triangle index, a segment index, a point
index. An ordinal is not an identity. It is a position in whatever enumeration the mesher happened
to walk, and it means nothing once the shape is rebuilt, re-imported, or modified.

The identity tables in `OCCTSwiftTools` turn that ordinal back into the `Shape` it came from, and
where a `BRepGraph` is available, into a `BRepGraph.GraphUID` that survives the shape being rebuilt.

```swift
import OCCTSwift
import OCCTSwiftTools

let (body, metadata, identity) = CADFileLoader.shapeToBodyMetadataAndIdentity(shape, id: "part")

// A face pick arrives as a triangle index; metadata maps it to a face ordinal.
let faceOrdinal = metadata?.faceIndices[triangleIndex]
let face = identity?.faces.shape(forOrdinal: Int(faceOrdinal!))
let uid = identity?.faces.uid(forOrdinal: Int(faceOrdinal!))
```

In practice you rarely index the tables by hand. `SubShapePickResolver` is the one place a
render-path ordinal becomes a `SubShapeRef`, and it reads these tables for you. Reach for the
tables directly only when you are building something the resolver does not cover.

## Why the tables exist at all

OCCT attaches the `TopoDS_Shape` to the sensitive entity when selection is computed:
`StdSelect_BRepOwner` carries the shape itself, never an ordinal. It can do that because its
selection data is a CPU-side structure it owns.

Ours is a GPU buffer of triangles. There is nowhere to hang a `TopoDS_Shape` on a vertex buffer, so
the attachment has to happen earlier, at tessellation time, and be carried alongside. That is what
these tables are. They are not an index-caching optimisation, and treating them as one is how you
end up re-deriving the ordinal correspondence per pick and getting it subtly wrong.

## What identity means here

**Face identity keys on OCCT's `IsSame`**: same `TShape`, same `Location`, orientation may differ.
This was settled in [OCCTSwiftInteraction#1](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/1);
encode it rather than re-deciding it.

That is a comparison semantic, and the enumeration follows from it rather than being a separate
choice. `Shape.faces()` is deduplicated through a `TopTools_IndexedMapOfShape`, which is `IsSame`,
and is what `FaceIdentityTable` is built from. `orientedFaces()` is occurrence-based (`IsEqual`) and
is deliberately **not** an identity here.

So **a face shared between two shells is one entry, not two.** That it bounds two solids is a fact
about the model, not two selectable things. A caller who needs to know which use was picked reads
orientation off the returned `Shape`, which is OCCT's own answer, rather than asking for a second
enumeration.

The mesher still walks face occurrences, so a shared face is tessellated once per owning shell, each
wound for its own outside, and **both** triangulations carry the one deduplicated ordinal. Two
triangles with the same ordinal can therefore be different geometry belonging to different shells,
resolving to one identity. That is intended, not a collision.

## The three tables, and where they differ

| Table | Ordinal source | Already deduplicated? |
|---|---|---|
| `FaceIdentityTable` | `ViewportBody.faceIndices` / `CADBodyMetadata.faceIndices` | yes, since OCCTSwift v2.0.0 |
| `EdgeIdentityTable` | `ViewportBody.edgeIndices` | yes, always |
| `VertexIdentityTable` | `ViewportBody.vertexIndices` | yes, always |

Edges and vertices were never ambiguous. Both `Shape.edge(at:)` and the bulk polyline extractor
build one `TopTools_IndexedMapOfShape`, as do `Shape.vertices()` and `Shape.vertex(at:)`, so a
shared edge or vertex has always collapsed to a single ordinal, matching `subShapes(ofType:)` and
the graph. There was never a raw-versus-deduplicated split to reconcile for them.

Faces had one, and it is worth knowing because consumer code written before OCCTSwift v2.0.0 may
still assume the old behaviour. The render-path ordinal used a raw, non-deduplicating
`TopExp_Explorer` walk that visited a shared face once per shell, while `subShapes(ofType: .face)`
and `BRepGraph` collapsed it to one. All three agreed on a clean single solid and diverged the
moment a face was shared. OCCTSwift v2.0.0 (#541/#613) closed it upstream: `Shape.faces()` is now
itself the deduplicated enumeration, and `Mesh.Triangle.faceIndex` moved onto that same enumeration
in the same release.

`VertexIdentityTable.shapes` is `[Shape]` where its two siblings hold `[Shape?]`, because the vertex
traversal returns `Shape` values directly with no failable conversion in the way.

## The index space is the ordinal space

`FaceIdentityTable.shapes` and `EdgeIdentityTable.shapes` are `[Shape?]`, and the optionality is
load-bearing rather than defensive.

A `nil` marks an ordinal whose `Face`/`Edge` to `Shape` conversion failed, and it **keeps that
ordinal's slot**. Compacting the array instead would silently move every later entry down one, so
every ordinal after the failure would name the wrong sub-shape. That was a real bug
([OCCTSwiftInteraction#9](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/9)): a
`compactMap` where a `map` was needed. A `nil` entry costs that one ordinal its shape and its uid,
and nothing else.

If you build a table yourself, preserve the index space the same way.

## GraphUIDs

`uids` is `nil` when no `BRepGraph` was supplied when the table was built. When present, an
individual element is `nil` if that ordinal could not be resolved in the graph, or has no entry in
`shapes`.

A `GraphUID` is the durable half. Resolution goes through `graph.findNode(for:)`, an identity
lookup, so it never assumed index correspondence with the graph's own node numbering, which is why
it was unaffected by the face-enumeration divergence above.
