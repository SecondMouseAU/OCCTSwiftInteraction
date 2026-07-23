import Foundation
import simd
import OCCTSwift

/// Information about a face picked in the viewport.
///
/// `shape` and `uid` are the durable identity of the pick, captured once at pick time
/// from the picked body's `FaceIdentityTable` rather than re-derived later. `faceIndex`
/// is the ephemeral render-path ordinal that produced the pick — valid only against the
/// `ViewportBody`/`CADBodyMetadata` it was minted from. Once a face is shared between two
/// shells, `loadedShape.faces()[faceIndex]` and a `BRepGraph`'s node ordering diverge (the
/// graph dedups the shared face to one node; the render-path traversal counts it once per
/// shell), so re-deriving the face from `faceIndex` alone can silently name the wrong one.
/// Use `shape` — construct a `Face` from it (`Face(info.shape)`) for face-specific queries
/// — rather than subscripting `loadedShape.faces()`.
public struct PickedFaceInfo: Sendable {
    /// The picked face, as the exact `Shape` (wrapping a `TopoDS_Face`) it was tessellated
    /// from. Construct a `Face` from it (`Face(shape)`) for face-specific queries such as
    /// area or normal.
    public let shape: OCCTSwift.Shape

    /// Durable handle into the picked body's `BRepGraph`, when the graph was available at
    /// pick time. `nil` if graph construction failed for this body (a pathological shape)
    /// — such a pick has nothing durable to resolve forward through a later rebuild.
    public let uid: BRepGraph.GraphUID?

    /// Render-path ordinal into this body's tessellation (`CADBodyMetadata.faceIndices`).
    /// Ephemeral — do not use it to re-derive the face via `loadedShape.faces()[faceIndex]`;
    /// use `shape` instead.
    public let faceIndex: Int
    public let bodyID: String
    public let isHorizontal: Bool
    public let isVertical: Bool
    public let bounds: FaceBounds
    public let zLevel: Float?
    public let area: Double
    public let description: String

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
        description: String
    ) {
        self.shape = shape
        self.uid = uid
        self.faceIndex = faceIndex
        self.bodyID = bodyID
        self.isHorizontal = isHorizontal
        self.isVertical = isVertical
        self.bounds = bounds
        self.zLevel = zLevel
        self.area = area
        self.description = description
    }
}

extension PickedFaceInfo: Equatable {
    /// Hand-written: `OCCTSwift.Shape` has no `IsSame`-respecting `Equatable` conformance to
    /// piggyback on, so `shape` is excluded. Identity follows `uid` when both sides have
    /// one — the durable handle, which two picks of the same shared face can carry even
    /// with different `faceIndex`/`bodyID` ordinals (see the shared-face-between-shells
    /// regression test) — falling back to `faceIndex` + `bodyID` only when neither side has
    /// a `uid`. Mirrors `OCCTSwiftAIS.SubShapeRef.==` exactly; the descriptive fields
    /// (`bounds`, `area`, etc.) are derived deterministically from the same face and so
    /// don't need to participate.
    public static func == (lhs: PickedFaceInfo, rhs: PickedFaceInfo) -> Bool {
        switch (lhs.uid, rhs.uid) {
        case (let l?, let r?): return l == r
        case (nil, nil): return lhs.faceIndex == rhs.faceIndex && lhs.bodyID == rhs.bodyID
        default: return false
        }
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
