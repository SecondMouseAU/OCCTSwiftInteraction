// swift-tools-version: 6.0
import PackageDescription

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
        // Sibling path packages (consistent with how PadCAM consumes OCCTSwift /
        // OCCTSwiftViewport / PadCAMEngine — the OCCTSwift repo ships a binary
        // OCCT.xcframework and OCCTSwiftViewport's `OCCTSwiftTools` target is
        // not yet published as a versioned product). Once those repos publish
        // tagged products, swap to URL-based dependencies.
        .package(path: "../OCCTSwift"),
        .package(path: "../OCCTSwiftViewport"),
    ],
    targets: [
        .target(
            name: "OCCTSwiftCADKit",
            dependencies: [
                .product(name: "OCCTSwift", package: "OCCTSwift"),
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
                .product(name: "OCCTSwiftTools", package: "OCCTSwiftViewport"),
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
