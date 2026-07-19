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
        occtDep("OCCTSwift", from: "1.12.9"),   // ≥1.12.9: OCCT kernel crash/hang fixes through #318 and #323 (patches 0003-0009)
        occtDep("OCCTSwiftViewport", from: "1.1.22"),
        occtDep("OCCTSwiftTools", from: "1.0.0"),
        occtDep("OCCTSwiftAIS", from: "1.0.0"),
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
