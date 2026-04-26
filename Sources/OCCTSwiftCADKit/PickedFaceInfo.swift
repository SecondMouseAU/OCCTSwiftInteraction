import Foundation
import simd

/// Information about a face picked in the viewport.
///
/// `faceIndex` is the 0-based index into `loadedShape.faces()`. Use it to look
/// the face back up via OCCTSwift if you need to do further analysis.
public struct PickedFaceInfo: Sendable, Equatable {
    public let faceIndex: Int
    public let bodyID: String
    public let isHorizontal: Bool
    public let isVertical: Bool
    public let bounds: FaceBounds
    public let zLevel: Float?
    public let area: Double
    public let description: String

    public init(
        faceIndex: Int,
        bodyID: String,
        isHorizontal: Bool,
        isVertical: Bool,
        bounds: FaceBounds,
        zLevel: Float?,
        area: Double,
        description: String
    ) {
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
