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
        occtDep("OCCTSwift", from: "2.0.0"),          // >=2.0.0: correctness release (duplication audit #377 + five correctness clusters #669); 17 breaking Swift API changes, OCCT kernel 8.0.1 (+15 carried patches); see SEMVER.md#v200
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
