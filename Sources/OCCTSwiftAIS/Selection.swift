import Foundation
import OCCTSwift

/// Categories of sub-shape that can be selected.
public enum SelectionMode: Hashable, Sendable {
    case body
    case face
    case edge
    case vertex
}

/// Snapshot of selected sub-shapes.
public struct Selection: Hashable, Sendable {
    public let subshapes: Set<SubShape>

    public init(_ subshapes: Set<SubShape> = []) {
        self.subshapes = subshapes
    }

    public var isEmpty: Bool { subshapes.isEmpty }
    public var count: Int { subshapes.count }

    /// Distinct interactive objects represented in this selection.
    public var bodies: Set<InteractiveObject> {
        Set(subshapes.map(\.object))
    }

    /// Concrete `Face` handles for any `.face(...)` entries.
    ///
    /// Order is unspecified. Resolved directly from the ref's captured
    /// `Shape`: no ordinal round-trip through `Shape.subShape(type:index:)`
    /// (see `SubShapeRef's` documentation for why that round-trip is unsafe).
    public var faces: [Face] {
        subshapes.compactMap { sub in
            guard case .face(_, let ref) = sub else { return nil }
            return Face(ref.shape)
        }
    }

    /// Concrete `Edge` handles for any `.edge(...)` entries.
    ///
    /// Order is unspecified.
    public var edges: [Edge] {
        subshapes.compactMap { sub in
            guard case .edge(_, let ref) = sub else { return nil }
            return Edge(ref.shape)
        }
    }

    /// World-space positions of any `.vertex(...)` entries.
    ///
    /// Order is unspecified. Returns vertex coordinates rather than a rich
    /// type: OCCTSwift exposes vertices as positional `SIMD3<Double>`
    /// values, not a `Vertex` class.
    public var vertices: [SIMD3<Double>] {
        subshapes.compactMap { sub in
            guard case .vertex(_, let ref) = sub else { return nil }
            return ref.shape.vertices().first
        }
    }
}
