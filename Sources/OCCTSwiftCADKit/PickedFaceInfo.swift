import Foundation
import OCCTSwift
import OCCTSwiftTools
import simd

/// The one identity rule for a picked entity, shared by `PickedFaceInfo`, `PickedEdgeInfo` and
/// `PickedVertexInfo`.
///
/// `SubShapeRef.==` (the durable `uid` when both sides have one, else the ephemeral ordinal),
/// qualified by the body the pick landed on, which a bare ref does not carry. In `OCCTSwiftAIS`
/// that qualification comes from the `InteractiveObject` in the enclosing `SubShape`; here the
/// info types carry a `bodyID` instead, so it has to be applied explicitly.
///
/// Written once rather than three times: before OCCTSwiftInteraction#3 each of the three info
/// types carried its own hand-rolled copy of this, each commented "mirrors
/// `OCCTSwiftAIS.SubShapeRef.==` exactly", which is three chances for one rule to drift.
func isSamePick(
    _ lhs: OCCTSwiftTools.SubShapeRef, _ lhsBodyID: String, _ rhs: OCCTSwiftTools.SubShapeRef,
    _ rhsBodyID: String
)
    -> Bool
{
    guard lhs == rhs else { return false }
    // `SubShapeRef.==` compares uids when both sides have one, which is already body-agnostic
    // and durable. It falls back to the ordinal only when neither side has a uid, and an
    // ordinal means nothing across bodies, so that case needs the body checked too.
    return lhs.uid != nil || lhsBodyID == rhsBodyID
}

/// Information about a face picked in the viewport.
///
/// A presentation type built from `OCCTSwiftTools.SubShapeRef`: `ref` is the identity half,
/// minted by `SubShapePickResolver`, and everything else on here is the enrichment
/// `CADViewportService` adds for its UI (`bounds`, `zLevel`, `area`, `description`,
/// `scalarValue`). `shape`, `uid` and `faceIndex` forward to `ref` rather than duplicating it.
///
/// `faceIndex` is the ephemeral render-path ordinal that produced the pick, valid only against
/// the `ViewportBody`/`CADBodyMetadata` it was minted from. Once a face is shared between two
/// shells, `loadedShape.faces()[faceIndex]` and a `BRepGraph`'s node ordering diverge (the graph
/// dedups the shared face to one node; the render-path traversal counts it once per shell), so
/// re-deriving the face from `faceIndex` alone can silently name the wrong one. Use `shape`,
/// constructing a `Face` from it (`Face(info.shape)`) for face-specific queries, rather than
/// subscripting `loadedShape.faces()`.
public struct PickedFaceInfo: Sendable {
    /// The identity of this pick: the exact `Shape` the face was tessellated from, its durable
    /// `BRepGraph.GraphUID` when a graph was available, and the render-path ordinal.
    public let ref: OCCTSwiftTools.SubShapeRef

    /// The picked face, as the exact `Shape` (wrapping a `TopoDS_Face`) it was tessellated from.
    ///
    /// Construct a `Face` from it (`Face(shape)`) for face-specific queries such as area or
    /// normal.
    public var shape: OCCTSwift.Shape { ref.shape }

    /// Durable handle into the picked body's `BRepGraph`, when the graph was available at
    /// pick time. `nil` if graph construction failed for this body (a pathological shape):
    /// such a pick has nothing durable to resolve forward through a later rebuild.
    public var uid: BRepGraph.GraphUID? { ref.uid }

    /// Render-path ordinal into this body's tessellation (`CADBodyMetadata.faceIndices`).
    ///
    /// Ephemeral: do not use it to re-derive the face via `loadedShape.faces()[faceIndex]`;
    /// use `shape` instead.
    public var faceIndex: Int { ref.ordinal }

    public let bodyID: String
    public let isHorizontal: Bool
    public let isVertical: Bool
    public let bounds: FaceBounds
    public let zLevel: Float?
    public let area: Double
    public let description: String

    /// This face's value from the `ScalarField` set on its body (`setScalarField(_:forBody:)`),
    /// if any: resolved at pick time from the field's own domain (`.perFace` by `faceIndex`,
    /// `.perTriangle` by the picked triangle). `nil` when no field is set on this body, and
    /// also `nil` for a `.perTriangle` field when this info was built from a selection that
    /// did not come from a pick (an area selection, say), since no triangle was involved.
    public let scalarValue: Double?

    public init(
        ref: OCCTSwiftTools.SubShapeRef,
        bodyID: String,
        isHorizontal: Bool,
        isVertical: Bool,
        bounds: FaceBounds,
        zLevel: Float?,
        area: Double,
        description: String,
        scalarValue: Double? = nil
    ) {
        self.ref = ref
        self.bodyID = bodyID
        self.isHorizontal = isHorizontal
        self.isVertical = isVertical
        self.bounds = bounds
        self.zLevel = zLevel
        self.area = area
        self.description = description
        self.scalarValue = scalarValue
    }

    /// Source-compatible convenience for the pre-OCCTSwiftInteraction#3 shape of this type,
    /// which stored `shape`/`uid`/`faceIndex` separately instead of a `SubShapeRef`.
    public init(
        shape: OCCTSwift.Shape,
        uid: BRepGraph.GraphUID? = nil,
        faceIndex: Int,
        bodyID: String,
        isHorizontal: Bool,
        isVertical: Bool,
        bounds: FaceBounds,
        zLevel: Float?,
        area: Double,
        description: String,
        scalarValue: Double? = nil
    ) {
        self.init(
            ref: OCCTSwiftTools.SubShapeRef(shape: shape, uid: uid, ordinal: faceIndex),
            bodyID: bodyID,
            isHorizontal: isHorizontal,
            isVertical: isVertical,
            bounds: bounds,
            zLevel: zLevel,
            area: area,
            description: description,
            scalarValue: scalarValue
        )
    }
}

extension PickedFaceInfo: Equatable {
    /// Identity is `isSamePick`, the one rule shared with the edge and vertex info types.
    ///
    /// Hand-written because `OCCTSwift.Shape` has no `IsSame`-respecting `Equatable`
    /// conformance to piggyback on, so a synthesised `==` would drag the descriptive fields
    /// (`bounds`, `area`, and the rest) in through it. They are derived deterministically from
    /// the same face anyway, so they have nothing to add.
    public static func == (lhs: PickedFaceInfo, rhs: PickedFaceInfo) -> Bool {
        isSamePick(lhs.ref, lhs.bodyID, rhs.ref, rhs.bodyID)
    }
}

/// XY bounds of a face in world coordinates (millimetres).
public struct FaceBounds: Sendable, Equatable, Codable {
    public let minX: Float
    public let maxX: Float
    public let minY: Float
    public let maxY: Float

    public init(minX: Float, maxX: Float, minY: Float, maxY: Float) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    public var width: Float { maxX - minX }
    public var height: Float { maxY - minY }
}
