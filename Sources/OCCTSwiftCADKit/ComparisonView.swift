import simd

/// Axis a `.wipe` comparison splits along. A local mirror of the same concept elsewhere in the
/// ecosystem (e.g. `OCCTSwiftAIS.ManipulatorWidget.Axis`) rather than a re-export, so this
/// package's public surface doesn't couple to a widget-specific type for an unrelated concept.
public enum Axis: Sendable, Equatable, CaseIterable {
    case x, y, z

    var unitVector: SIMD3<Float> {
        switch self {
        case .x: return SIMD3<Float>(1, 0, 0)
        case .y: return SIMD3<Float>(0, 1, 0)
        case .z: return SIMD3<Float>(0, 0, 1)
        }
    }
}

/// How `setComparison(_:)` displays a reference entity against a candidate entity.
public enum ComparisonMode: Sendable, Equatable {
    /// Reference ghosted behind the candidate at `referenceOpacity` (`0`...`1`, clamped).
    case overlay(referenceOpacity: Double)

    /// Candidate painted via the existing scalar-field path (`setScalarField(_:forBody:)`),
    /// showing distance-to-reference or any other precomputed per-face/per-triangle value.
    /// CADKit doesn't compute the deviation itself — this mode is a marker only; call
    /// `setScalarField(_:forBody:)` on the candidate with the values to display.
    case deviation

    /// Reference and candidate placed next to each other (offset along X) rather than
    /// overlapping, sharing this service's single camera/viewport — "linked cameras" is
    /// automatic since there is only ever one camera.
    case sideBySide

    /// Reference and candidate spatially split by a plane perpendicular to `axis` at world
    /// coordinate `position`: the reference is visible where its geometry's coordinate along
    /// `axis` is less than `position`, the candidate where it's greater or equal.
    case wipe(axis: Axis, position: Double)
}

/// A comparison between two already-loaded entities — typically a source mesh (`referenceID`)
/// and a reconstructed solid (`candidateID`) — set via `CADViewportService.setComparison(_:)`.
public struct ComparisonView: Sendable, Equatable {
    public let referenceID: String
    public let candidateID: String
    public let mode: ComparisonMode

    public init(referenceID: String, candidateID: String, mode: ComparisonMode) {
        self.referenceID = referenceID
        self.candidateID = candidateID
        self.mode = mode
    }
}
