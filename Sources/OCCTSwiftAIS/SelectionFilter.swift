import Foundation
import OCCTSwift

/// Restricts what `InteractiveContext` accepts as pickable.
///
/// Installed filters gate both pick-driven selection (`handlePick`) and
/// hover (`handleHover`), never programmatic `select(_:)`, which (like
/// `selectionMode`) is an intentional override by app code. Mirrors OCCT's
/// `SelectMgr_Filter` / `StdSelect_FaceFilter` / `StdSelect_EdgeFilter` /
/// `StdSelect_ShapeTypeFilter` family, minus the C++ handle machinery.
///
/// A concrete conformer is a `class` (not a `struct`) so `InteractiveContext.removeFilter(_:)`
/// can identify a specific installed instance by reference, the same way
/// `Dimension` conformers are removed by `ObjectIdentifier`.
public protocol SelectionFilter: AnyObject, Sendable {
    /// Return `true` to keep `candidate` selectable/hoverable.
    func accepts(_ candidate: SubShape) -> Bool
}

/// Restricts `.face` candidates to faces whose surface classifies as one of
/// `kinds` (`OCCTSwift.Face.SurfaceType`: plane, cylinder, cone, sphere,
/// torus, …).
///
/// Every other case (`.body`, `.edge`, `.vertex`) is accepted
/// unconditionally; combine with `ShapeTypeFilter` via `AllOfFilter` to also
/// restrict the sub-shape kind.
public final class SurfaceTypeFilter: SelectionFilter, @unchecked Sendable {
    public let kinds: Set<Face.SurfaceType>

    public init(_ kinds: Set<Face.SurfaceType>) {
        self.kinds = kinds
    }

    public func accepts(_ candidate: SubShape) -> Bool {
        guard case .face(_, let ref) = candidate else { return true }
        guard let face = Face(ref.shape) else { return false }
        return kinds.contains(face.surfaceType)
    }
}

/// Restricts `.edge` candidates to edges whose 3D curve classifies as one of
/// `kinds` (`OCCTSwift.Edge.CurveType`: line, circle, ellipse, …).
///
/// Every other case is accepted unconditionally.
public final class CurveTypeFilter: SelectionFilter, @unchecked Sendable {
    public let kinds: Set<Edge.CurveType>

    public init(_ kinds: Set<Edge.CurveType>) {
        self.kinds = kinds
    }

    public func accepts(_ candidate: SubShape) -> Bool {
        guard case .edge(_, let ref) = candidate else { return true }
        guard let edge = Edge(ref.shape) else { return false }
        return kinds.contains(edge.curveType)
    }
}

/// Restricts candidates to one of the given sub-shape kinds. Functionally
/// overlaps `InteractiveContext.selectionMode` (which gates which kinds are
/// resolved from a pick at all) but composes with other filters, e.g.
/// `AllOfFilter([ShapeTypeFilter([.face]), NotFilter(SurfaceTypeFilter([.plane]))])`
/// for "faces, and not planar ones."
public final class ShapeTypeFilter: SelectionFilter, @unchecked Sendable {
    public let modes: Set<SelectionMode>

    public init(_ modes: Set<SelectionMode>) {
        self.modes = modes
    }

    public func accepts(_ candidate: SubShape) -> Bool {
        switch candidate {
        case .body: return modes.contains(.body)
        case .face: return modes.contains(.face)
        case .edge: return modes.contains(.edge)
        case .vertex: return modes.contains(.vertex)
        }
    }
}

/// Accepts a candidate only if every one of `filters` does: OCCT's AND
/// composition (`SelectMgr_AndFilter` / `SelectMgr_CompositionFilter`).
public final class AllOfFilter: SelectionFilter, @unchecked Sendable {
    public let filters: [any SelectionFilter]

    public init(_ filters: [any SelectionFilter]) {
        self.filters = filters
    }

    public func accepts(_ candidate: SubShape) -> Bool {
        filters.allSatisfy { $0.accepts(candidate) }
    }
}

/// Accepts a candidate if at least one of `filters` does: OCCT's OR
/// composition (`SelectMgr_OrFilter`).
public final class AnyOfFilter: SelectionFilter, @unchecked Sendable {
    public let filters: [any SelectionFilter]

    public init(_ filters: [any SelectionFilter]) {
        self.filters = filters
    }

    public func accepts(_ candidate: SubShape) -> Bool {
        filters.contains { $0.accepts(candidate) }
    }
}

/// Inverts another filter.
public final class NotFilter: SelectionFilter, @unchecked Sendable {
    public let filter: any SelectionFilter

    public init(_ filter: any SelectionFilter) {
        self.filter = filter
    }

    public func accepts(_ candidate: SubShape) -> Bool {
        !filter.accepts(candidate)
    }
}

/// Closure escape hatch for app-specific predicates, e.g. a radius threshold
/// on a circular edge that no built-in filter expresses.
public final class PredicateFilter: SelectionFilter, @unchecked Sendable {
    private let predicate: @Sendable (SubShape) -> Bool

    public init(_ predicate: @escaping @Sendable (SubShape) -> Bool) {
        self.predicate = predicate
    }

    public func accepts(_ candidate: SubShape) -> Bool {
        predicate(candidate)
    }
}
