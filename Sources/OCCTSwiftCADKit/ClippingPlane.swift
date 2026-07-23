import simd

/// A clipping/section plane, set via `CADViewportService.clippingPlanes`/`addClippingPlane(origin:normal:showCapSurface:)`.
///
/// Geometry on the side the normal points away from is hidden. `showCapSurface` controls
/// whether the cut is shown hollow (fast — a GPU-only clip, see
/// `CADViewportService.syncClippingPlanes`) or as solid material (requires a genuine B-Rep
/// split/retessellation per affected body — see `CADViewportService.updateCapSurfaces`).
public struct ClippingPlane: Sendable, Identifiable, Equatable {
    public let id: String
    public var origin: SIMD3<Double>
    public var normal: SIMD3<Double>
    public var isEnabled: Bool
    public var showCapSurface: Bool

    public init(
        id: String,
        origin: SIMD3<Double>,
        normal: SIMD3<Double>,
        isEnabled: Bool = true,
        showCapSurface: Bool = true
    ) {
        self.id = id
        self.origin = origin
        self.normal = normal
        self.isEnabled = isEnabled
        self.showCapSurface = showCapSurface
    }
}
