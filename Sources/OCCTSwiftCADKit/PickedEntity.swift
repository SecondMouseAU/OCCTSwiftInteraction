import Foundation
import OCCTSwift
import OCCTSwiftTools
import simd

/// A pick result, generalised over which kind of sub-shape was hit.
///
/// The presentation half of a selection: each case wraps an `OCCTSwiftTools.SubShapeRef`
/// (the identity, minted by `SubShapePickResolver`) together with the geometry
/// `CADViewportService` reads off it for display. The selection *state* itself lives in
/// `OCCTSwiftAIS.InteractiveContext` as `SubShape` values; see `CADViewportService.selection`.
///
/// There is deliberately no `.body` case. Whole-body selection is a `SubShape.body` in the
/// interactive context, where AIS's whole-body fallback and its body-level highlight already
/// live; this enum names the sub-shape kinds this service enriches. See the bakeoff on
/// OCCTSwiftInteraction#3.
public enum PickedEntity: Sendable, Equatable {
    case face(PickedFaceInfo)
    case edge(PickedEdgeInfo)
    case vertex(PickedVertexInfo)

    /// The id of the body this pick landed on, regardless of kind.
    ///
    /// With the multi-entity loading API (`CADViewportService.load`/`loadFile(from:id:)`),
    /// pass this to `entityID(forBodyID:)` to find which loaded entity was hit.
    public var bodyID: String {
        switch self {
        case .face(let info): return info.bodyID
        case .edge(let info): return info.bodyID
        case .vertex(let info): return info.bodyID
        }
    }

    /// The identity half of this pick.
    ///
    /// The same value the `OCCTSwiftAIS` selection state holds for it.
    public var ref: OCCTSwiftTools.SubShapeRef {
        switch self {
        case .face(let info): return info.ref
        case .edge(let info): return info.ref
        case .vertex(let info): return info.ref
        }
    }
}

/// Information about an edge picked in the viewport.
///
/// A presentation type built from `OCCTSwiftTools.SubShapeRef`, exactly like `PickedFaceInfo`:
/// `ref` is the identity, captured at pick time from the picked body's `EdgeIdentityTable`, and
/// the rest is enrichment. `edgeIndex` is the ephemeral render-path ordinal, valid only against
/// the `ViewportBody`/`edgeIndices` it was minted from.
public struct PickedEdgeInfo: Sendable {
    /// The identity of this pick.
    ///
    /// See `PickedFaceInfo.ref`.
    public let ref: OCCTSwiftTools.SubShapeRef

    /// The picked edge, as the exact `Shape` (wrapping a `TopoDS_Edge`) it was extracted from.
    ///
    /// Construct an `Edge` from it (`Edge(shape)`) for edge-specific queries.
    public var shape: OCCTSwift.Shape { ref.shape }

    /// Durable handle into the picked body's `BRepGraph`, when the graph was available at
    /// pick time. `nil` if graph construction failed for this body.
    public var uid: BRepGraph.GraphUID? { ref.uid }

    /// Render-path ordinal into this body's `edgeIndices`.
    ///
    /// Ephemeral: do not use it to re-derive the edge via `loadedShape.edges()[edgeIndex]`;
    /// use `shape` instead.
    public var edgeIndex: Int { ref.ordinal }

    public let bodyID: String
    public let curveType: OCCTSwift.Edge.CurveType
    public let length: Double
    public let startPoint: SIMD3<Double>
    public let endPoint: SIMD3<Double>
    public let description: String

    public init(
        ref: OCCTSwiftTools.SubShapeRef,
        bodyID: String,
        curveType: OCCTSwift.Edge.CurveType,
        length: Double,
        startPoint: SIMD3<Double>,
        endPoint: SIMD3<Double>,
        description: String
    ) {
        self.ref = ref
        self.bodyID = bodyID
        self.curveType = curveType
        self.length = length
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.description = description
    }

    /// Source-compatible convenience for the pre-OCCTSwiftInteraction#3 shape of this type.
    public init(
        shape: OCCTSwift.Shape,
        uid: BRepGraph.GraphUID? = nil,
        edgeIndex: Int,
        bodyID: String,
        curveType: OCCTSwift.Edge.CurveType,
        length: Double,
        startPoint: SIMD3<Double>,
        endPoint: SIMD3<Double>,
        description: String
    ) {
        self.init(
            ref: OCCTSwiftTools.SubShapeRef(shape: shape, uid: uid, ordinal: edgeIndex),
            bodyID: bodyID,
            curveType: curveType,
            length: length,
            startPoint: startPoint,
            endPoint: endPoint,
            description: description
        )
    }
}

extension PickedEdgeInfo: Equatable {
    /// Hand-written for the same reason as `PickedFaceInfo.==`, and by the same rule.
    public static func == (lhs: PickedEdgeInfo, rhs: PickedEdgeInfo) -> Bool {
        isSamePick(lhs.ref, lhs.bodyID, rhs.ref, rhs.bodyID)
    }
}

/// Information about a vertex picked in the viewport.
///
/// A presentation type built from `OCCTSwiftTools.SubShapeRef`, exactly like `PickedFaceInfo`:
/// `ref` is the identity, captured at pick time from the picked body's `VertexIdentityTable`.
/// `vertexIndex` is the ephemeral render-path ordinal, valid only against the
/// `ViewportBody`/`vertexIndices` it was minted from.
public struct PickedVertexInfo: Sendable {
    /// The identity of this pick.
    ///
    /// See `PickedFaceInfo.ref`.
    public let ref: OCCTSwiftTools.SubShapeRef

    /// The picked vertex, as the exact `Shape` (wrapping a `TopoDS_Vertex`) it was extracted
    /// from.
    ///
    /// OCCTSwift exposes vertices positionally rather than as their own class: use
    /// `position`, or `shape.vertices().first`, for its world-space location.
    public var shape: OCCTSwift.Shape { ref.shape }

    /// Durable handle into the picked body's `BRepGraph`, when the graph was available at
    /// pick time. `nil` if graph construction failed for this body.
    public var uid: BRepGraph.GraphUID? { ref.uid }

    /// Render-path ordinal into this body's `vertexIndices`.
    ///
    /// Ephemeral.
    public var vertexIndex: Int { ref.ordinal }

    public let bodyID: String
    public let position: SIMD3<Double>
    public let description: String

    public init(
        ref: OCCTSwiftTools.SubShapeRef,
        bodyID: String,
        position: SIMD3<Double>,
        description: String
    ) {
        self.ref = ref
        self.bodyID = bodyID
        self.position = position
        self.description = description
    }

    /// Source-compatible convenience for the pre-OCCTSwiftInteraction#3 shape of this type.
    public init(
        shape: OCCTSwift.Shape,
        uid: BRepGraph.GraphUID? = nil,
        vertexIndex: Int,
        bodyID: String,
        position: SIMD3<Double>,
        description: String
    ) {
        self.init(
            ref: OCCTSwiftTools.SubShapeRef(shape: shape, uid: uid, ordinal: vertexIndex),
            bodyID: bodyID,
            position: position,
            description: description
        )
    }
}

extension PickedVertexInfo: Equatable {
    /// Hand-written for the same reason as `PickedFaceInfo.==`, and by the same rule.
    public static func == (lhs: PickedVertexInfo, rhs: PickedVertexInfo) -> Bool {
        isSamePick(lhs.ref, lhs.bodyID, rhs.ref, rhs.bodyID)
    }
}
