// swift-tools-version: 6.1

import PackageDescription
import Foundation

// Prefer a local sibling checkout (../<name>) when present, else the published URL, so the whole
// OCCT ecosystem SHARES the single OCCTSwift/Libraries/OCCT.xcframework instead of each repo
// extracting its own 1.3 GB copy. CI / fresh clones (no sibling) use the URL pin. `#filePath`-relative
// so it's independent of build CWD.
func occtDep(_ name: String, from version: String) -> Package.Dependency {
    let manifestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    // Only trust a sibling checkout for a REAL local dev clone, never when this manifest is itself a
    // transitively-resolved checkout under a consumer's `.build/checkouts/` (SwiftPM lays every dep out
    // flat there, so `../\(name)` spuriously exists and flips this to a path dep → a SwiftPM identity
    // conflict with the URL-based dep. See SecondMouseAU/ecosystem#14.
    if !manifestDir.contains("/.build/"),
       FileManager.default.fileExists(atPath: manifestDir + "/../\(name)/Package.swift") {
        return .package(path: "../\(name)")
    }
    return .package(url: "https://github.com/SecondMouseAU/\(name).git", from: Version(version)!)
}

let package = Package(
    name: "OCCTSwiftTools",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v1),
        .tvOS(.v18)
    ],
    products: [
        .library(
            name: "OCCTSwiftTools",
            targets: ["OCCTSwiftTools"]
        ),
    ],
    dependencies: [
        occtDep("OCCTSwift", from: "3.0.0"),    // ≥3.0.0: Rule 2 major on a much smaller surface than 2.0.0 (docs/SEMVER.md#v300). OCCT itself does not move: the kernel stays at 8.0.1, rebuilt as v3.0.0-kernel.1 to carry two patches the 2.0.0 asset was missing (OCCTSwift#905/#913). Three breaks, every one audited here and none of them reachable: Selector.SubShapeType.compsolid renamed .compSolid (#844); Shape.ShapeFilterType.RawValue moving Int32 to Int now that ShapeFilterType is a ShapeType typealias (#844), a break only where the raw type is named or stored; and Shape.bounds/size/center, Wire.bounds, Edge.bounds, Face.bounds/exactBounds becoming Optional (#943), returning nil on OCCT's own Bnd_Box::IsVoid() instead of fabricating a (0,0,0)-(0,0,0) box that was indistinguishable from a genuine zero-size shape at the world origin. That third one is what bites elsewhere in the fleet, but nothing here asks a shape for its extent: this repo is a Shape/ViewportBody bridge over meshes, edge polylines and the identity tables, and the ShapeMeasurements it hangs on CADBodyMetadata are computed inside OCCTSwift, not recomputed from bounds here. Verified by a build against the real v3.0.0 sibling rather than grep alone (grep is unreliable on .bounds/.size/.center, which collide with Viewport and SIMD types): floor bump only, zero source changes; ≥2.0.0: correctness release (OCCTSwift#377/#669), OCCT absorbed to 8.0.1. 17 breaking changes (docs/SEMVER.md#v200); audited every call site in this repo against the full break table (issue #51). Shape.faces() and Mesh.Triangle.faceIndex both moved to the deduplicated enumeration together (#541/#613), which the FaceIdentityTable comments below described as a raw-vs-deduplicated split that no longer exists post-2.0.0 (comments updated, no logic change: makeFaceIdentityTable already reads shape.faces() dynamically rather than hardcoding the old enumeration). AAG / mass-property / continuity / PathParser surfaces are not reachable from this repo (grep-verified, zero hits); ≥1.17.0: Pass 1a duplication/bug-fix audit (OCCTSwift#377/#380): continuity enum consolidation (source-compatible via deprecated aliases), Surface.drawMesh/evaluateGrid now return SurfaceGrid (not used here); ≥1.15.0: TopologyGraph renamed to BRepGraph (OCCTSwift#333)
        occtDep("OCCTSwiftViewport", from: "1.1.23"),
        occtDep("OCCTSwiftIO", from: "1.7.0"),  // ≥1.7.0: ShapeLoader splits multibody into per-body entries (#21)
    ],
    targets: [
        .target(
            name: "OCCTSwiftTools",
            dependencies: [
                .product(name: "OCCTSwift",         package: "OCCTSwift"),
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
                .product(name: "OCCTSwiftIO",       package: "OCCTSwiftIO"),
            ],
            path: "Sources/OCCTSwiftTools",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OCCTSwiftToolsTests",
            dependencies: ["OCCTSwiftTools"],
            path: "Tests/OCCTSwiftToolsTests"
        ),
    ]
)
