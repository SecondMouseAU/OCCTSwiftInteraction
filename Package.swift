// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Prefer a local sibling checkout (../<name>) when present, else the published URL — so the whole
// OCCT ecosystem SHARES the single OCCTSwift/Libraries/OCCT.xcframework instead of each repo
// extracting its own 1.3 GB copy. CI / fresh clones (no sibling) use the URL pin. `#filePath`-relative
// so it's independent of build CWD.
func occtDep(_ name: String, from version: String) -> Package.Dependency {
    let manifestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    if FileManager.default.fileExists(atPath: manifestDir + "/../\(name)/Package.swift") {
        return .package(path: "../\(name)")
    }
    return .package(url: "https://github.com/SecondMouseAU/\(name).git", from: Version(version)!)
}

let package = Package(
    name: "OCCTSwiftCADKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "OCCTSwiftCADKit",
            targets: ["OCCTSwiftCADKit"]
        ),
    ],
    dependencies: [
        occtDep("OCCTSwift", from: "3.0.0"),          // >=3.0.0: void-bounds correctness. Shape.bounds/size/center + Wire/Edge/Face.bounds + Face.exactBounds return nil (from Bnd_Box::IsVoid) instead of fabricating a zero-size box at the origin; 8 sites here unwrapped into their existing failure paths (camera framing declines to reframe, cap-split treats a boundless piece as clipped away, a boundless face pick resolves to nil) rather than defaulting to .zero, which would reinstate the defect. Other two breaks audited, zero hits: no .compsolid spelling, no ShapeFilterType.RawValue naming. OCCT kernel unchanged at 8.0.1 (rebuilt v3.0.0-kernel.1 for two missing patches). See SEMVER.md#v300
        occtDep("OCCTSwiftViewport", from: "1.1.26"),  // batched/region GPU pick readback + controller-level pick access
        occtDep("OCCTSwiftTools", from: "1.6.1"),      // FaceIdentityTable/EdgeIdentityTable/VertexIdentityTable (durable identity)
        occtDep("OCCTSwiftAIS", from: "1.3.1"),        // SubShapeRef, topology-aware selection filters, area selection
    ],
    targets: [
        .target(
            name: "OCCTSwiftCADKit",
            dependencies: [
                .product(name: "OCCTSwift", package: "OCCTSwift"),
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
                .product(name: "OCCTSwiftTools", package: "OCCTSwiftTools"),
                .product(name: "OCCTSwiftAIS", package: "OCCTSwiftAIS"),
            ],
            path: "Sources/OCCTSwiftCADKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "OCCTSwiftCADKitTests",
            dependencies: ["OCCTSwiftCADKit"],
            path: "Tests/OCCTSwiftCADKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
