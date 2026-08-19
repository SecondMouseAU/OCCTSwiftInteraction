// ShapeIdentity.swift
// OCCTSwiftTools
//
// The one place a Shape becomes the three ordinal-to-identity tables a pick resolves through
// (OCCTSwiftInteraction#7).

import OCCTSwift

/// Everything needed to turn a render-path ordinal on one body back into topology: the `Shape` the
/// body was tessellated from, the `BRepGraph` its durable uids were minted from, and the three
/// per-kind identity tables `SubShapePickResolver` reads.
///
/// ## Why this type exists
///
/// Phase 2 of [ecosystem#43](https://github.com/SecondMouseAU/ecosystem/issues/43) made
/// `SubShapePickResolver` the one place a render-path ordinal becomes a `SubShapeRef`. It did not
/// consolidate the step before that, building the tables the resolver reads, and three copies of
/// that step accumulated: `CADFileLoader`'s private helpers, `OCCTSwiftCADKit`'s (whose own comment
/// said it mirrored them), and `OCCTSwiftUX`'s `ShapeIdentity`, added for the same reason and
/// saying so in its header. This is the merged version, and it lives in the lowest target that can
/// build a table at all.
///
/// The bakeoff on OCCTSwiftInteraction#7 found the three agreed on every success path and differed
/// only on failure paths, which is the configuration one edit away from a real divergence. Two
/// shapes were taken from the copies being replaced:
///
/// - The uid loop is written **once**, generic over `[Shape]`, which was `OCCTSwiftUX`'s shape
///   rather than the older two's (they each wrote it out three times, once per kind).
/// - The graph is **retained**, which was `OCCTSwiftCADKit`'s. `OCCTSwiftUX` built one per shape
///   and dropped it, so anything later needing a graph rebuilt it, and `BRepGraph.init` serialises
///   the whole shape to a BREP string on the way through.
///
/// ## Enumerations, and why these ones
///
/// Each table is built from the enumeration the matching render-path ordinal is assigned by, so
/// `shapes[ordinal]` always names the exact sub-shape behind the primitives carrying that ordinal:
///
/// - **Faces**: `Shape.faces()`, the same deduplicated enumeration the mesher assigns
///   `Mesh.Triangle.faceIndex` from since OCCTSwift v2.0.0.
/// - **Edges**: `Shape.edges()`, the same `TopTools_IndexedMapOfShape` traversal the bulk
///   edge-polyline extractor behind `ViewportBody.edgeIndices` uses.
/// - **Vertices**: `Shape.subShapes(ofType: .vertex)`, the traversal behind
///   `ViewportBody.vertexIndices`.
///
/// Face identity keys on OCCT's `TopoDS_Shape::IsSame` (settled in
/// [OCCTSwiftInteraction#1](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/1)), so a
/// face shared between two shells is one entry rather than two, and `graph.findNode(for:)` matches
/// on that same semantic. See `FaceIdentityTable` for the full reasoning.
///
/// ## Building the tables is not free
///
/// Measured against a 14-face, 36-edge solid: meshing 9.6ms, `BRepGraph(shape:)` 5.0ms, of which
/// 3.8ms is the `toBREPString()` full-BREP serialisation inside `BRepGraph.init`. That is why
/// `CADFileLoader.load(from:format:)` builds identity only when asked (`includeIdentity`), rather
/// than for every consumer: headless callers that load geometry to render or reproject it never
/// pick, and should not pay for a graph.
public struct ShapeIdentity: Sendable {

    /// The shape every table below was enumerated from.
    ///
    /// Also what `SubShapePickResolver` falls back to when a table misses, so carrying it here
    /// keeps the resolver's two inputs from drifting apart.
    public let shape: Shape

    /// The graph the tables' uids were minted from, retained for its shape's lifetime.
    ///
    /// `nil` when no graph was supplied to `init(shape:graph:)`, or when `BRepGraph(shape:)` failed
    /// in `init(shape:)` (a pathological shape). Either way every table's `uids` is `nil` and picks
    /// resolve to a `Shape` and an ordinal without a durable handle.
    public let graph: BRepGraph?

    /// Maps each `ViewportBody.faceIndices` ordinal to its `Shape` and `GraphUID`.
    public let faces: FaceIdentityTable

    /// Maps each `ViewportBody.edgeIndices` ordinal to its `Shape` and `GraphUID`.
    public let edges: EdgeIdentityTable

    /// Maps each `ViewportBody.vertexIndices` ordinal to its `Shape` and `GraphUID`.
    public let vertices: VertexIdentityTable

    /// Build all three tables for `shape`, minting uids from a graph the caller already holds.
    ///
    /// Pass a `BRepGraph` built from this same `shape`. Passing `nil` is supported and means
    /// "shapes but no durable handles": every table still resolves `shape(forOrdinal:)`, and every
    /// `uid(forOrdinal:)` returns `nil`. That is the mode `CADFileLoader`'s per-shape bridge has
    /// always offered through its `graph:` parameter, and it is preserved here.
    ///
    /// - Parameters:
    ///   - shape: the shape to enumerate.
    ///   - graph: a graph built from `shape`, or `nil` for shapes-only tables.
    public init(shape: Shape, graph: BRepGraph?) {
        self.shape = shape
        self.graph = graph
        let faceShapes = shape.faces().compactMap { Shape.fromFace($0) }
        let edgeShapes = shape.edges().compactMap { Shape.fromEdge($0) }
        let vertexShapes = shape.subShapes(ofType: .vertex)
        self.faces = FaceIdentityTable(
            shapes: faceShapes, uids: Self.uids(for: faceShapes, in: graph))
        self.edges = EdgeIdentityTable(
            shapes: edgeShapes, uids: Self.uids(for: edgeShapes, in: graph))
        self.vertices = VertexIdentityTable(
            shapes: vertexShapes, uids: Self.uids(for: vertexShapes, in: graph))
    }

    /// Build all three tables for `shape`, minting a `BRepGraph` for it first.
    ///
    /// The convenience `OCCTSwiftCADKit` and `OCCTSwiftUX` each hand-rolled: a consumer holding an
    /// in-memory `Shape` wants durable identity and has no graph yet. Graph construction is
    /// failable, and a failure degrades rather than throws: the tables still resolve every ordinal
    /// to its `Shape`, and `uid(forOrdinal:)` is `nil` throughout, so a pick carries an ordinal and
    /// a shape but nothing that survives a later modelling operation.
    ///
    /// See the type's own note on cost before calling this per body in a loop.
    public init(shape: Shape) {
        self.init(shape: shape, graph: BRepGraph(shape: shape))
    }

    /// The durable uid for each sub-shape, or `nil` throughout when there is no graph.
    ///
    /// Written once and shared by all three kinds. `findNode(for:)` matches on OCCT's `IsSame`,
    /// which is the identity these tables are enumerated by, so a face shared between two shells
    /// resolves to the one node naming it. An individual element is `nil` only when that
    /// sub-shape has no node in the graph.
    private static func uids(for shapes: [Shape], in graph: BRepGraph?) -> [BRepGraph.GraphUID?]? {
        guard let graph else { return nil }
        return shapes.map { sub in
            guard let node = graph.findNode(for: sub) else { return nil }
            return graph.uid(ofNodeKind: Int(node.kind.rawValue), index: node.index)
        }
    }
}
