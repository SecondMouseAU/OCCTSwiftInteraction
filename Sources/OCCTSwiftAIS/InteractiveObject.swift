import Foundation
import OCCTSwift

/// Erased reference to something currently displayed in an `InteractiveContext`.
///
/// Equality and hashing are by `id` only. Two `InteractiveObject`s with the same
/// id refer to the same logical scene entry even if their `Shape` was rebuilt.
public struct InteractiveObject: Hashable, Sendable {
    public let id: UUID
    public let shape: Shape

    public init(id: UUID = UUID(), shape: Shape) {
        self.id = id
        self.shape = shape
    }

    public static func == (lhs: InteractiveObject, rhs: InteractiveObject) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// A durable handle to a picked sub-shape, carrying three things that answer
/// different questions.
///
/// - `shape`: the concrete sub-shape resolved once at pick time. Use this for
///   geometry queries (`Face(ref.shape)`, `Edge(ref.shape)`, vertex position, …)
///   instead of re-deriving it from `ordinal` via `Shape.subShape(type:index:)`.
///   That round-trip is exactly the coincidence SPEC.md warns about: a
///   render-path ordinal need not agree with `Shape`'s own sub-shape enumeration
///   once a sub-shape is shared between shells (see OCCTSwiftTools#42).
/// - `uid`: a `BRepGraph.GraphUID`, minted when a graph was in hand at pick
///   time. This is the durable identity: it survives `InteractiveContext.remap`
///   across a mutation via `BRepGraph.add(_:absorbing:inputRoots:operationName:)`.
///   `nil` when no graph was available; remap then has nothing durable to
///   resolve the sub-shape by and drops it.
/// - `ordinal`: the tessellation-time render-path index. Ephemeral: valid only
///   against the `ViewportBody` it was minted from (highlight overlays index
///   per-triangle buffers by it). Never compare sub-shapes by ordinal alone.
public struct SubShapeRef: Sendable {
    public let shape: Shape
    public let uid: BRepGraph.GraphUID?
    public let ordinal: Int

    public init(shape: Shape, uid: BRepGraph.GraphUID? = nil, ordinal: Int) {
        self.shape = shape
        self.uid = uid
        self.ordinal = ordinal
    }
}

extension SubShapeRef: Hashable {
    /// Identity follows `uid` when both sides have one: the durable handle.
    /// Falls back to `ordinal` otherwise. `shape` never participates: OCCTSwift's
    /// `Shape` has no `IsSame`-respecting `Hashable` conformance to piggyback on
    /// (same reasoning as `InteractiveObject`'s id-only equality, above).
    public static func == (lhs: SubShapeRef, rhs: SubShapeRef) -> Bool {
        switch (lhs.uid, rhs.uid) {
        case (let l?, let r?): return l == r
        case (nil, nil): return lhs.ordinal == rhs.ordinal
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        if let uid { hasher.combine(uid) } else { hasher.combine(ordinal) }
    }
}

/// A specific TopoDS sub-shape inside a displayed `InteractiveObject`, or the
/// whole body. `.body` is identity-stable across mutations by construction
/// (rebinds to the same `InteractiveObject.id`). `.face`/`.edge`/`.vertex` carry
/// a `SubShapeRef`; see its documentation for what survives mutation and what
/// doesn't, and SPEC.md §"Selection survival across mutation".
public enum SubShape: Hashable, Sendable {
    case body(InteractiveObject)
    case face(InteractiveObject, ref: SubShapeRef)
    case edge(InteractiveObject, ref: SubShapeRef)
    case vertex(InteractiveObject, ref: SubShapeRef)

    public var object: InteractiveObject {
        switch self {
        case .body(let o): return o
        case .face(let o, _): return o
        case .edge(let o, _): return o
        case .vertex(let o, _): return o
        }
    }

    /// The durable ref carried by this sub-shape, or `nil` for `.body`.
    public var ref: SubShapeRef? {
        switch self {
        case .body: return nil
        case .face(_, let r): return r
        case .edge(_, let r): return r
        case .vertex(_, let r): return r
        }
    }
}
