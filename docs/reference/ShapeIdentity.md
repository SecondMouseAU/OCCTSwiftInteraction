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

| Table | Enumeration | Ordinal source |
|---|---|---|
| `faces` | `Shape.faces()` | `ViewportBody.faceIndices` / `CADBodyMetadata.faceIndices` |
| `edges` | `Shape.edges()` | `ViewportBody.edgeIndices` |
| `vertices` | `Shape.subShapes(ofType: .vertex)` | `ViewportBody.vertexIndices` |

Face identity keys on OCCT's `TopoDS_Shape::IsSame`, settled in
[OCCTSwiftInteraction#1](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/1), so a face
shared between two shells is **one** entry rather than two, and `graph.findNode(for:)` matches on
that same semantic. See [`FaceIdentityTable`](FaceIdentityTable) for the full reasoning.

## Failure behaviour

The three copies this replaced agreed on every success path and differed only here, which is why
these cases carry explicit test coverage.

| Case | Behaviour |
|---|---|
| `graph: nil` passed | Every table's `uids` is `nil` (absent, not an array of nils), so a caller can tell "no graph supplied" from "this ordinal did not resolve". `shape(forOrdinal:)` still works. |
| `BRepGraph(shape:)` fails in `init(shape:)` | Same as above. `graph` is `nil`; the shape is pathological but still resolvable by ordinal. |
| Shape has no faces (a wire, an edge, a lone vertex) | `faces.shapes` is empty and, with a graph, `faces.uids` is `[]`. Empty, not absent. The kinds the shape does have are unaffected. |
| An individual sub-shape has no node in the graph | That one `uids` element is `nil`; the rest are unaffected. |
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
