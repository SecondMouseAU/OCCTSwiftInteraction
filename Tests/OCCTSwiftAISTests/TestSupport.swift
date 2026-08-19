import OCCTSwift
import Testing

@testable import OCCTSwiftAIS

/// Test-only convenience: a `SubShapeRef` resolved directly from `object's`
/// shape at `index`, with no durable `uid`, for tests exercising geometry
/// resolution (dimension anchors, `Selection` accessors) that don't need a
/// `BRepGraph` in the loop.
func faceRef(_ object: InteractiveObject, _ index: Int) throws -> SubShapeRef {
    SubShapeRef(
        shape: try #require(object.shape.subShape(type: .face, index: index)), ordinal: index)
}

func edgeRef(_ object: InteractiveObject, _ index: Int) throws -> SubShapeRef {
    SubShapeRef(
        shape: try #require(object.shape.subShape(type: .edge, index: index)), ordinal: index)
}

func vertexRef(_ object: InteractiveObject, _ index: Int) throws -> SubShapeRef {
    SubShapeRef(
        shape: try #require(object.shape.subShape(type: .vertex, index: index)), ordinal: index)
}

/// Indices into `shape.faces()` paired with each face's resolved surface
/// centroid, for tests that pin a face by picking an extreme along an axis.
///
/// `ShapeMeasurements.faceCentroids` is an array of optionals, since a face
/// whose surface mass is zero has no centroid, so a face that did not resolve
/// is dropped here rather than compared as if its centroid sat at the origin.
func facesWithCentroids(of shape: OCCTSwift.Shape) -> [(index: Int, centroid: SIMD3<Double>)] {
    shape.measure().faceCentroids.enumerated().compactMap { index, centroid in
        centroid.map { (index: index, centroid: $0) }
    }
}

/// Test-only helpers for asserting against `SubShape`s produced by
/// `InteractiveContext.handlePick`. These compare by render-path `ordinal`
/// only, ignoring `SubShapeRef.uid`: tests assert against the ordinal the
/// pick resolved to (the observable, renderer-visible outcome), not a durable
/// uid they'd otherwise have to duplicate `InteractiveContext`'s own minting
/// logic to reconstruct. See `SubShapeRef`'s equality docs for why a uid-less
/// ref never equals a uid-carrying one via `==`.
func containsFace(_ subshapes: Set<SubShape>, _ object: InteractiveObject, ordinal: Int) -> Bool {
    subshapes.contains { sub in
        guard case .face(let o, let ref) = sub else { return false }
        return o == object && ref.ordinal == ordinal
    }
}

func containsEdge(_ subshapes: Set<SubShape>, _ object: InteractiveObject, ordinal: Int) -> Bool {
    subshapes.contains { sub in
        guard case .edge(let o, let ref) = sub else { return false }
        return o == object && ref.ordinal == ordinal
    }
}

func containsVertex(_ subshapes: Set<SubShape>, _ object: InteractiveObject, ordinal: Int) -> Bool {
    subshapes.contains { sub in
        guard case .vertex(let o, let ref) = sub else { return false }
        return o == object && ref.ordinal == ordinal
    }
}
