---
title: SubShapePickResolver
parent: API Reference
---

# SubShapePickResolver

Turns a GPU pick's primitive index into a [`SubShapeRef`](Selection#subshaperef): the identity half
of picking, and the only supported way to mint one.

Lives in the `OCCTSwiftTools` target alongside the identity tables it reads, so every layer above
resolves picks the same way. `OCCTSwiftAIS` and `OCCTSwiftCADKit` both call it; neither keeps a copy
any more.

## Why it exists

Four implementations of "resolve a pick to topology" existed across the fleet
([ecosystem#43](https://github.com/SecondMouseAU/ecosystem/issues/43)), and two of them had already
diverged: `OCCTSwiftCADKit` fixed the empty-`vertexIndices` case in its own copy and left
`OCCTSwiftAIS`'s broken, so the same pick resolved through one path and not the other. This is the
merged version ([OCCTSwiftInteraction#2](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/2)).

## What it does not do

The resolver owns exactly the identity concern: **ordinal in, `SubShapeRef` out.** Three behaviours
that look like its job belong to other layers and stayed there:

| Behaviour | Where it lives | Why |
|---|---|---|
| Selection-mode gate, whole-body fallback | `OCCTSwiftAIS` | Whether a pick names one face or the entire object is a selection-mode decision. OCCT carries the same distinction as `SelectMgr_EntityOwner::ComesFromDecomposition()`, on the owner rather than inside the resolver. |
| Clip-plane awareness | `OCCTSwiftCADKit` | Clip planes are the viewport service's state. A resolver in the bridge target has no business knowing about them, so discarding a pick on clipped-away geometry is a caller-side pre-filter. |
| Geometry enrichment (curve type, area, z-level, description) | `OCCTSwiftCADKit`, `OCCTSwiftUX` | Presentation, not identity. |

## The rules it does own

1. **The indirection is per-primitive, not per-ordinal.** A pick reports a triangle, line segment or
   point index; `faceIndices` / `edgeIndices` / `vertexIndices` map that to the sub-shape ordinal.
   Both the primitive index and the resulting ordinal are bounds-checked.
2. **Empty `vertexIndices` means identity mapping**, per `ViewportBody`'s own documentation: the
   point index *is* the ordinal. Empty `faceIndices` / `edgeIndices` mean the opposite, also per
   `ViewportBody`: the body is simply not pickable that way, and the pick is discarded rather than
   mapped. A vertex pick is therefore bounded by how many points the body renders
   (`ViewportBody.vertices.count`), never by `vertexIndices.count`.
3. **The identity table wins over re-derivation.** The table captured the exact `Shape` that ordinal
   was tessellated from. Re-deriving it from the shape's own sub-shape enumeration is the fallback
   for a body with no table, not the primary path.

## API

```swift
public enum SubShapePickResolver {
    public static func resolveFace(
        triangleIndex: Int,
        faceIndices: [Int32],
        identity: FaceIdentityTable?,
        shape: Shape?
    ) -> SubShapeRef?

    public static func resolveEdge(
        segmentIndex: Int,
        edgeIndices: [Int32],
        identity: EdgeIdentityTable?,
        shape: Shape?
    ) -> SubShapeRef?

    public static func resolveVertex(
        pointIndex: Int,
        pointCount: Int,
        vertexIndices: [Int32],
        identity: VertexIdentityTable?,
        shape: Shape?
    ) -> SubShapeRef?
}
```

- `triangleIndex` / `segmentIndex` / `pointIndex` are all `PickResult.triangleIndex`, which the
  renderer interprets per `PickResult.kind`.
- `pointCount` is `ViewportBody.vertices.count`, the number of pick points the body renders. Zero
  means the body is not vertex-pickable.
- `shape` is the `Shape` the body was tessellated from, used **only** to re-derive the sub-shape when
  `identity` is `nil`. Pass it and the table together; the table is preferred.
- Every function returns `nil` when the pick does not name a sub-shape of that kind, rather than
  guessing.

## Example

```swift
let box = Shape.box(width: 10, height: 5, depth: 3)!
let graph = BRepGraph(shape: box)!
let (body, meta, faces, _, vertices) = CADFileLoader.shapeToBodyMetadataAndIdentities(
    box, id: "box", color: SIMD4<Float>(0.6, 0.6, 0.65, 1), graph: graph
)
guard let body, let meta else { return }

// A face pick: triangle 0 of the rendered mesh.
if let faceRef = SubShapePickResolver.resolveFace(
    triangleIndex: 0, faceIndices: meta.faceIndices, identity: faces, shape: box)
{
    print(faceRef.ordinal)          // the face ordinal, not the triangle index
    print(Face(faceRef.shape)?.area() ?? 0)
    print(faceRef.uid as Any)       // durable across a later mutation
}

// A vertex pick on a body whose vertexIndices is empty: the point index is the ordinal.
let vertexRef = SubShapePickResolver.resolveVertex(
    pointIndex: 3, pointCount: body.vertices.count, vertexIndices: [],
    identity: vertices, shape: box
)
print(vertexRef?.ordinal ?? -1)     // 3
```

See also [FaceIdentityTable](FaceIdentityTable) / [EdgeIdentityTable](EdgeIdentityTable) /
[VertexIdentityTable](VertexIdentityTable) for where the captured identities come from, and
[Selection](Selection) for `SubShapeRef` and `SubShape` themselves.
