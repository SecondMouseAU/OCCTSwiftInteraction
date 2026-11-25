// BodyMeshing.swift
// OCCTSwiftCADKit
//
// OCCTSwiftInteraction#82: the settings a model body was meshed with at its load, so a cap recut
// and the restore when the cap goes mesh it the same way.

import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport

/// How a model body was meshed when it was loaded: the `CADFileLoader.shapeToBodyAndMetadata`
/// settings its load used.
///
/// Recorded per body at the load, not read from `CADViewportService.meshDeflection` later, because
/// that applies only to shapes loaded after it is set: the current value is not necessarily the one
/// a body was meshed with.
struct BodyMeshing: Equatable, Sendable {
    /// The linear deflection, or `nil` for the loader's default.
    var deflection: Double?
    /// The loader's STL preset, which an STL file load meshes with.
    var stl = false

    /// The loader's defaults, which a STEP or BREP file load meshes with.
    static let loaderDefault = BodyMeshing()

    /// The settings `CADFileLoader.load(from:format:progress:includeIdentity:)` meshes a body of
    /// `format` with.
    ///
    /// It ignores `meshDeflection`. One case this cannot see: when meshing an STL file's shape
    /// fails, the loader reloads it through `Shape.loadSTLRobust(from:)` and meshes that without
    /// the STL preset. An STL's faces are planar triangles, which mesh to the same triangles either
    /// way (measured on a cylinder's STL, whole and cut), so the record is still right in effect.
    static func fileLoad(_ format: CADFileFormat) -> BodyMeshing {
        BodyMeshing(stl: format == .stl)
    }

    /// `shape` meshed with these settings, as body `id` in `color`.
    func mesh(_ shape: Shape, id: String, color: SIMD4<Float>) -> (ViewportBody?, CADBodyMetadata?)
    {
        CADFileLoader.shapeToBodyAndMetadata(
            shape, id: id, color: color, stl: stl, deflection: deflection)
    }
}
