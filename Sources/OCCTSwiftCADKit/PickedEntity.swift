import Foundation
import simd
import OCCTSwift

/// A pick result, generalised over which kind of sub-shape was hit. Face picks carry the
/// existing `PickedFaceInfo`; edge and vertex picks carry their own info types alongside it,
/// all sharing the same durable-identity shape (`shape`/`uid`, plus an ephemeral render-path
/// ordinal) established for faces in `PickedFaceInfo`.
public enum PickedEntity: Sendable, Equatable {
    case face(PickedFaceInfo)
    case edge(PickedEdgeInfo)
    case vertex(PickedVertexInfo)

    /// The id of the body this pick landed on, regardless of kind. With the multi-entity
    /// loading API (`CADViewportService.load`/`loadFile(from:id:)`), pass this to
    /// `entityID(forBodyID:)` to find which loaded entity was hit.
    public var bodyID: String {
        switch self {
        case .face(let info): return info.bodyID
        case .edge(let info): return info.bodyID
        case .vertex(let info): return info.bodyID
        }
    }
}

/// Information about an edge picked in the viewport.
///
/// `shape` and `uid` are the durable identity of the pick, captured at pick time from the
/// picked body's `EdgeIdentityTable`. `edgeIndex` is the ephemeral render-path ordinal —
/// valid only against the `ViewportBody`/`edgeIndices` it was minted from.
public struct PickedEdgeInfo: Sendable {
    /// The picked edge, as the exact `Shape` (wrapping a `TopoDS_Edge`) it was extracted
    /// from. Construct an `Edge` from it (`Edge(shape)`) for edge-specific queries.
    public let shape: OCCTSwift.Shape

    /// Durable handle into the picked body's `BRepGraph`, when the graph was available at
    /// pick time. `nil` if graph construction failed for this body.
    public let uid: BRepGraph.GraphUID?

    /// Render-path ordinal into this body's `edgeIndices`. Ephemeral — do not use it to
    /// re-derive the edge via `loadedShape.edges()[edgeIndex]`; use `shape` instead.
    public let edgeIndex: Int
    public let bodyID: String
    public let curveType: OCCTSwift.Edge.CurveType
    public let length: Double
    public let startPoint: SIMD3<Double>
    public let endPoint: SIMD3<Double>
    public let description: String

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
        self.shape = shape
        self.uid = uid
        self.edgeIndex = edgeIndex
        self.bodyID = bodyID
        self.curveType = curveType
        self.length = length
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.description = description
    }
}

extension PickedEdgeInfo: Equatable {
    /// Hand-written for the same reason as `PickedFaceInfo.==`: `Shape` has no usable
    /// `Equatable`, and `uid` (when present on both sides) is authoritative over the
    /// ephemeral ordinal.
    public static func == (lhs: PickedEdgeInfo, rhs: PickedEdgeInfo) -> Bool {
        switch (lhs.uid, rhs.uid) {
        case (let l?, let r?): return l == r
        case (nil, nil): return lhs.edgeIndex == rhs.edgeIndex && lhs.bodyID == rhs.bodyID
        default: return false
        }
    }
}

/// Information about a vertex picked in the viewport.
///
/// `shape` and `uid` are the durable identity of the pick, captured at pick time from the
/// picked body's `VertexIdentityTable`. `vertexIndex` is the ephemeral render-path ordinal —
/// valid only against the `ViewportBody`/`vertexIndices` it was minted from.
public struct PickedVertexInfo: Sendable {
    /// The picked vertex, as the exact `Shape` (wrapping a `TopoDS_Vertex`) it was
    /// extracted from. OCCTSwift exposes vertices positionally rather than as their own
    /// class — use `position`, or `shape.vertices().first`, for its world-space location.
    public let shape: OCCTSwift.Shape

    /// Durable handle into the picked body's `BRepGraph`, when the graph was available at
    /// pick time. `nil` if graph construction failed for this body.
    public let uid: BRepGraph.GraphUID?

    /// Render-path ordinal into this body's `vertexIndices`. Ephemeral.
    public let vertexIndex: Int
    public let bodyID: String
    public let position: SIMD3<Double>
    public let description: String

    public init(
        shape: OCCTSwift.Shape,
        uid: BRepGraph.GraphUID? = nil,
        vertexIndex: Int,
        bodyID: String,
        position: SIMD3<Double>,
        description: String
    ) {
        self.shape = shape
        self.uid = uid
        self.vertexIndex = vertexIndex
        self.bodyID = bodyID
        self.position = position
        self.description = description
    }
}

extension PickedVertexInfo: Equatable {
    public static func == (lhs: PickedVertexInfo, rhs: PickedVertexInfo) -> Bool {
        switch (lhs.uid, rhs.uid) {
        case (let l?, let r?): return l == r
        case (nil, nil): return lhs.vertexIndex == rhs.vertexIndex && lhs.bodyID == rhs.bodyID
        default: return false
        }
    }
}
