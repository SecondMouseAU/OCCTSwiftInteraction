---
title: ShapeIdentity
parent: API Reference
---

# ShapeIdentity

Everything needed to turn a render-path ordinal on one body back into topology: the `Shape` the
body was tessellated from, the `BRepGraph` its durable uids were minted from, and the three
per-kind identity tables [`SubShapePickResolver`](SubShapePickResolver) reads.

This is the one place a `Shape` becomes identity tables, added in
[OCCTSwiftInteraction#7](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/7). Phase 2 of
[ecosystem#43](https://github.com/SecondMouseAU/ecosystem/issues/43) made `SubShapePickResolver` the
one place a render-path ordinal becomes a `SubShapeRef`; it did not consolidate the step before
that, and three copies of table construction had accumulated (`CADFileLoader`'s private helpers,
`OCCTSwiftCADKit`'s statics, and `OCCTSwiftUX`'s own `ShapeIdentity`). This is the merged version.

```swift
public struct ShapeIdentity: Sendable {
    public let shape: Shape
    public let graph: BRepGraph?
    public let faces: FaceIdentityTable
    public let edges: EdgeIdentityTable
    public let vertices: VertexIdentityTable

    public init(shape: Shape, graph: BRepGraph?)
    public init(shape: Shape)
}
```

## Topics

- [Building it](#building-it)
- [What each table is enumerated from](#what-each-table-is-enumerated-from)
- [Ordinal alignment is the invariant](#ordinal-alignment-is-the-invariant)
- [Failure behaviour](#failure-behaviour)
- [Cost](#cost)

---

## Building it

Two initialisers, differing only in who owns the graph.

```swift
// A graph you already hold, e.g. one retained across a modelling operation.
let identity = ShapeIdentity(shape: shape, graph: myGraph)

// No graph yet: mint one for this shape.
let identity = ShapeIdentity(shape: shape)
```

`init(shape:graph:)` accepts `nil` for `graph`, which means "tables but no durable handles": every
ordinal still resolves to a `Shape`, and every `uid(forOrdinal:)` returns `nil`. That is the mode
[`CADFileLoader`](CADFileLoader)'s per-shape bridge has always offered through its `graph:`
parameter.

`init(shape:)` is the convenience `OCCTSwiftCADKit` and `OCCTSwiftUX` each hand-rolled before this
type existed.

After a file load, do not build one per body by hand: ask the loader for them instead, with
`CADFileLoader.load(from:format:includeIdentity: true)`. That is what removes the shape-to-body
pairing hazard rather than leaving each consumer to detect it, see
[`CADLoadResult`](CADFileLoader#cadloadresult).

## What each table is enumerated from

Each table is built from the enumeration the matching render-path ordinal is assigned by, so
`shapes[ordinal]` always names the exact sub-shape behind the primitives carrying that ordinal.

| Table | Enumeration | Element type | Ordinal source |
|---|---|---|---|
| `faces` | `Shape.faces()` then `Shape.fromFace` | `Shape?` | `ViewportBody.faceIndices` / `CADBodyMetadata.faceIndices` |
| `edges` | `Shape.edges()` then `Shape.fromEdge` | `Shape?` | `ViewportBody.edgeIndices` |
| `vertices` | `Shape.subShapes(ofType: .vertex)` | `Shape` | `ViewportBody.vertexIndices` |

Face identity keys on OCCT's `TopoDS_Shape::IsSame`, settled in
[OCCTSwiftInteraction#1](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/1), so a face
shared between two shells is **one** entry rather than two, and `graph.findNode(for:)` matches on
that same semantic. See [`FaceIdentityTable`](FaceIdentityTable) for the full reasoning.

## Ordinal alignment is the invariant

Fixed in
[OCCTSwiftInteraction#9](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/9).

The ordinals stored in `ViewportBody.faceIndices` index the **full** `faces()` enumeration, because
that is what the mesher walks. Two of the three tables need a conversion on the way from that
enumeration to a `Shape`, and both conversions are failable: `Shape.fromFace` and `Shape.fromEdge`
return `nil` whenever the bridge call behind them yields no handle.

The tables used to be built with `compactMap`, which dropped a failed conversion instead of holding
its place. One failure at ordinal `k` moved every later face down one, so `shapes[ordinal]` returned
the face **after** the one the pick hit and `uid(forOrdinal:)` minted a durable identity for it. It
failed silently: no error, no assertion, and the pick resolved and highlighted confidently on a
neighbour.

So `faces.shapes` and `edges.shapes` are `[Shape?]`, built with `map`, and a failed conversion is a
`nil` at its own ordinal:

- The index space **is** the ordinal space, by construction rather than by every conversion
  happening to succeed. `shapes.count` is the size of the enumeration, and `shapes.indices` is the
  range of valid ordinals.
- The damage from a failure is bounded to the one ordinal that failed. It loses its captured shape
  and its uid; no other ordinal moves.
- A pick landing on that ordinal still resolves to the right sub-shape.
  [`SubShapePickResolver`](SubShapePickResolver) reads a `nil` entry as a table miss and re-derives
  from the shape via `subShape(type:index:)`, which walks the same `TopTools_IndexedMapOfShape`.
  What the pick loses is the durable `GraphUID`, not the identity of what was hit.

`vertices.shapes` is `[Shape]` and stays that way: `subShapes(ofType: .vertex)` returns `Shape`
values directly, so there is no conversion in front of it that could fail. The asymmetry records
where the hazard actually is. Do not add a conversion to the vertex path to match the other two, and
do not take the other two back to `compactMap` to match the vertex path.

Two rejected alternatives, both from the issue. **Refusing the table** when any conversion fails is
safe but throws away identity for every face because one failed. **Asserting** on a count mismatch
turns a silent wrong answer into a crash, which is better, but only in a debug build.

## Failure behaviour

The three copies this replaced agreed on every success path and differed only here, which is why
these cases carry explicit test coverage.

| Case | Behaviour |
|---|---|
| `graph: nil` passed | Every table's `uids` is `nil` (absent, not an array of nils), so a caller can tell "no graph supplied" from "this ordinal did not resolve". `shape(forOrdinal:)` still works. |
| `BRepGraph(shape:)` fails in `init(shape:)` | Same as above. `graph` is `nil`; the shape is pathological but still resolvable by ordinal. |
| Shape has no faces (a wire, an edge, a lone vertex) | `faces.shapes` is empty and, with a graph, `faces.uids` is `[]`. Empty, not absent. The kinds the shape does have are unaffected. |
| An individual sub-shape has no node in the graph | That one `uids` element is `nil`; the rest are unaffected. |
| A `Face`/`Edge` to `Shape` conversion fails | That one ordinal's `shapes` element and `uids` element are both `nil`; every other ordinal keeps the shape and uid it had. See [ordinal alignment](#ordinal-alignment-is-the-invariant). |
| The shape produced no mesh (edge-polyline-only bridge) | All three tables are built in full, including `faces`. The face table then names faces no pick can reach, which is safe because `SubShapePickResolver.resolveFace` bounds-checks against `faceIndices` first. `CADFileLoader` used to substitute an empty face table here; #7 dropped the special case, since it was the only place any copy varied a table's content and it was asymmetric with the edge and vertex tables built in full on the same branch. |

## Cost

Building identity is not free, which is why `CADFileLoader.load` does not do it by default.

Measured against a 14-face, 36-edge solid:

| Step | Time |
|---|---|
| `shape.mesh(parameters:)` (high-quality preset) | 9.6ms |
| `BRepGraph(shape:)` | 5.0ms |
| of which `toBREPString()` inside `BRepGraph.init` | 3.8ms |

So identity is roughly half again on top of meshing, and it scales with geometry size, because
`BRepGraph.init` serialises the whole shape to a BREP string on the way through. A headless
consumer that renders or reprojects and never picks should not pay for it.
