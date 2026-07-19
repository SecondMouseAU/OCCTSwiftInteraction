// swift-tools-version: 6.1

import PackageDescription
import Foundation

// Prefer a local sibling checkout (../<name>) when present, else the published URL — so the whole
// OCCT ecosystem SHARES the single OCCTSwift/Libraries/OCCT.xcframework instead of each repo
// extracting its own 1.3 GB copy. CI / fresh clones (no sibling) use the URL pin. `#filePath`-relative
// so it's independent of build CWD.
func occtDep(_ name: String, from version: String) -> Package.Dependency {
    let manifestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    // Only trust a sibling checkout for a REAL local dev clone — never when this manifest is itself a
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
        occtDep("OCCTSwift", from: "1.12.7"),   // ≥1.12.7: kernel crash fixes (fillet #298, free-bounds #310, ShapeFix_Face null-context #317)
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
