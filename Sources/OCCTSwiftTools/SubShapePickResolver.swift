// SubShapePickResolver.swift
// OCCTSwiftTools
//
// The one place a render-path ordinal becomes a topological identity
// (OCCTSwiftInteraction#2, phase 2 of ecosystem#43).

import OCCTSwift

/// What the three identity tables have in common, so one resolver serves all three kinds
/// instead of three near-copies of the same five lines.
///
/// Internal on purpose: it exists to de-duplicate this file, not to invite a fourth table.
protocol SubShapeIdentityTable: Sendable {
    /// The `Shape` a render-path ordinal was tessellated (or extracted) from.
    func shape(forOrdinal ordinal: Int) -> Shape?
    /// The durable `GraphUID` that ordinal resolves to, if a graph was supplied when the table
    /// was built.
    func uid(forOrdinal ordinal: Int) -> BRepGraph.GraphUID?
}

extension FaceIdentityTable: SubShapeIdentityTable {}
extension EdgeIdentityTable: SubShapeIdentityTable {}
extension VertexIdentityTable: SubShapeIdentityTable {}

/// Turns a GPU pick's primitive index into a `SubShapeRef`: the identity half of picking, and
/// the only supported way to mint one.
///
/// ## Why this is one type and not three copies
///
/// Four implementations of "resolve a pick to topology" existed across the fleet (ecosystem#43),
/// two of which had silently diverged: `OCCTSwiftCADKit` fixed the empty-`vertexIndices` case in
/// its own copy and left `OCCTSwiftAIS`'s broken, so a vertex pick against a body with an empty
/// `vertexIndices` resolved through one path and not the other. This is the merged version, and
/// it lives in the lowest target that can produce a `SubShapeRef` at all.
///
/// ## What it deliberately does not do
///
/// This resolver owns exactly the identity concern: **ordinal in, `SubShapeRef` out.** Three
/// behaviours that look like its job belong to other layers and stay there (the bakeoff on
/// ecosystem#43 is the reasoning):
///
/// - **The selection-mode gate and any whole-body fallback.** Whether a face pick that fails to
///   resolve should fall back to selecting the entire body is a selection-mode decision, so it
///   lives in `OCCTSwiftAIS` where the modes do. OCCT models the same distinction as
///   `SelectMgr_EntityOwner::ComesFromDecomposition()`, a flag on the owner rather than a branch
///   in the resolver.
/// - **Clip-plane awareness.** Clip planes are the viewport service's state. A resolver in this
///   target has no business knowing about them, so discarding a pick that landed on clipped-away
///   geometry stays a caller-side pre-filter.
/// - **Geometry enrichment** (curve type, area, z-level, human-readable description). That is
///   presentation, and belongs above the resolver.
///
/// ## The rules it does own
///
/// 1. **The indirection is per-primitive, not per-ordinal.** A pick reports a triangle, line
///    segment or point index; `faceIndices` / `edgeIndices` / `vertexIndices` map that to the
///    sub-shape ordinal. Both are bounds-checked.
/// 2. **Empty `vertexIndices` means identity mapping**, per `ViewportBody`'s own documentation:
///    the point index *is* the ordinal. Empty `faceIndices` / `edgeIndices` mean the opposite,
///    also per `ViewportBody`: the body is simply not pickable that way, and the pick is
///    discarded rather than mapped.
/// 3. **The identity table wins over re-derivation.** The table captured the exact `Shape` that
///    ordinal was tessellated from; re-deriving it from the shape's own sub-shape enumeration is
///    the fallback for a body that has no table, not the primary path.
public enum SubShapePickResolver {

    /// Resolve a triangle-level pick to face identity.
    ///
    /// - Parameters:
    ///   - triangleIndex: `PickResult.triangleIndex` for a `.face` pick.
    ///   - faceIndices: the picked body's per-triangle source-face ordinals
    ///     (`ViewportBody.faceIndices`, mirrored by `CADBodyMetadata.faceIndices`). Empty means
    ///     the body is not face-pickable.
    ///   - identity: the body's `FaceIdentityTable`, captured at tessellation time.
    ///   - shape: the `Shape` the body was tessellated from, used only to re-derive the face
    ///     when there is no table.
    /// - Returns: the resolved reference, or `nil` if the pick does not name a face.
    public static func resolveFace(
        triangleIndex: Int,
        faceIndices: [Int32],
        identity: FaceIdentityTable?,
        shape: Shape?
    ) -> SubShapeRef? {
        guard triangleIndex >= 0, triangleIndex < faceIndices.count else { return nil }
        return resolve(
            ordinal: Int(faceIndices[triangleIndex]), of: .face, identity: identity, shape: shape)
    }

    /// Resolve a line-segment-level pick to edge identity.
    ///
    /// - Parameters:
    ///   - segmentIndex: `PickResult.triangleIndex` for an `.edge` pick, which indexes the
    ///     flattened line segments of `ViewportBody.edges`.
    ///   - edgeIndices: the picked body's per-segment source-edge ordinals
    ///     (`ViewportBody.edgeIndices`). Empty means the body is not edge-pickable.
    ///   - identity: the body's `EdgeIdentityTable`.
    ///   - shape: the `Shape` the body was tessellated from, used only as the fallback.
    /// - Returns: the resolved reference, or `nil` if the pick does not name an edge.
    public static func resolveEdge(
        segmentIndex: Int,
        edgeIndices: [Int32],
        identity: EdgeIdentityTable?,
        shape: Shape?
    ) -> SubShapeRef? {
        guard segmentIndex >= 0, segmentIndex < edgeIndices.count else { return nil }
        return resolve(
            ordinal: Int(edgeIndices[segmentIndex]), of: .edge, identity: identity, shape: shape)
    }

    /// Resolve a point-sprite-level pick to vertex identity.
    ///
    /// The one place `OCCTSwiftCADKit`'s copy was more complete than `OCCTSwiftAIS`'s, and the
    /// reason: a vertex pick is bounded by how many points the body actually renders
    /// (`pointCount`), **not** by the length of `vertexIndices`, because an empty `vertexIndices`
    /// is documented on `ViewportBody` as identity mapping rather than as "no vertices". Bounding
    /// by `vertexIndices.count` (as AIS did) means such a body never resolves a vertex pick at
    /// all.
    ///
    /// - Parameters:
    ///   - pointIndex: `PickResult.triangleIndex` for a `.vertex` pick.
    ///   - pointCount: how many pick points the body renders (`ViewportBody.vertices.count`).
    ///     Zero means the body is not vertex-pickable.
    ///   - vertexIndices: the picked body's per-point source-vertex ordinals
    ///     (`ViewportBody.vertexIndices`). Empty means identity mapping.
    ///   - identity: the body's `VertexIdentityTable`.
    ///   - shape: the `Shape` the body was tessellated from, used only as the fallback.
    /// - Returns: the resolved reference, or `nil` if the pick does not name a vertex.
    public static func resolveVertex(
        pointIndex: Int,
        pointCount: Int,
        vertexIndices: [Int32],
        identity: VertexIdentityTable?,
        shape: Shape?
    ) -> SubShapeRef? {
        guard pointIndex >= 0, pointIndex < pointCount else { return nil }
        let ordinal =
            pointIndex < vertexIndices.count ? Int(vertexIndices[pointIndex]) : pointIndex
        return resolve(ordinal: ordinal, of: .vertex, identity: identity, shape: shape)
    }

    /// The identity rule itself, once: prefer the table's captured `Shape`, fall back to
    /// re-deriving from the source shape, and carry whatever durable uid the table has.
    ///
    /// The two fallback paths in the copies this replaced, `subShape(type:index:)` and
    /// `faces()[i]`, were checked and are equivalent: both go through `occtMapSubShapes` into the
    /// same `TopTools_IndexedMapOfShape`. `subShape(type:index:)` is kept because it is one call
    /// and already returns a `Shape`.
    private static func resolve(
        ordinal: Int,
        of type: ShapeType,
        identity: (any SubShapeIdentityTable)?,
        shape: Shape?
    ) -> SubShapeRef? {
        guard ordinal >= 0 else { return nil }
        guard
            let resolved = identity?.shape(forOrdinal: ordinal)
                ?? shape?.subShape(type: type, index: ordinal)
        else { return nil }
        return SubShapeRef(
            shape: resolved, uid: identity?.uid(forOrdinal: ordinal), ordinal: ordinal)
    }
}
