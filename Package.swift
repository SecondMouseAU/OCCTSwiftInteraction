// swift-tools-version: 6.1

import PackageDescription
// Every dependency resolves from its published URL. NEVER from a `../<name>` sibling.
//
// The old helper preferred a sibling checkout when one existed, so the fleet would share the
// single OCCT.xcframework instead of each repo extracting its own (SecondMouseAU/ecosystem#8).
// The saving is real but bought in the wrong currency: a path dependency carries no version
// requirement, so SwiftPM compiles whatever happens to be checked out in that sibling and drops
// the pin from Package.resolved entirely. Committing that lockfile makes the repo unresolvable
// from any clean checkout, which is CI and every new clone.
//
// Not hypothetical: PadCAM's `main` was unresolvable for exactly this reason and nobody noticed,
// because everyone builds with siblings present. Four incidents in two days built stale sibling
// source (ecosystem#48), and four OCCTParts branches shipped a Package.resolved with every
// occtswift pin stripped, caught by a review bot reading the diff rather than by any check
// (ecosystem#51).
//
// Measured, which is what settles it: the artifact DOWNLOAD is already shared, in
// ~/Library/Caches/org.swift.swiftpm/artifacts, so a URL-resolved build reports
// "Fetched ... from cache" and touches no network. Sibling resolution only ever saved the
// per-project EXTRACTION, about 594 MB in .build/artifacts/. That is disk worth paying for a
// lockfile that means what it says, and it is separately recoverable by sharing the extraction
// (symlink or APFS clone) without substituting source at all.
//
// Ed's rule, 2026-08-20: nothing resolves locally except binaries, and the binary is already
// shared by the artifact cache. The helper is kept rather than reverted to a bare
// `.package(url:)` so the call sites stay identical across the fleet.
func occtDep(_ name: String, from version: String) -> Package.Dependency {
    .package(url: "https://github.com/SecondMouseAU/\(name).git", from: Version(version)!)
}

// OCCTSwiftInteraction: identity, selection, and the assembled CAD viewport service.
//
// One package, three targets, strict upward dependency direction:
//
//   OCCTSwiftTools     kernel-to-renderer bridge: Shape into ViewportBody with picking metadata,
//                      plus the Face/Edge/VertexIdentityTables that give a picked ordinal a durable
//                      topological identity. No UI framework of any kind.
//     └─ OCCTSwiftAIS  interactive services: selection state, modes, schemes, filters, area
//                      selection, manipulator widgets, dimensions. Modeled on OCCT's own AIS_*.
//          └─ OCCTSwiftCADKit   the assembled SwiftUI CAD viewport service: import, face/edge/vertex
//                               picking, clipping, camera framing.
//
// **These were three separate repositories until ecosystem#42.** They were merged because the
// boundaries between them are real but the packaging of them was not: three version lines that only
// ever moved together, three release cuts that had to happen in strict order, and three CI setups.
// A single cross-cutting change (the picking consolidation, ecosystem#43) would otherwise need six
// sequenced PRs across three repos with a release between each. OCCTSwiftTools was 1,123 lines
// across 9 files, carrying more repository overhead than code.
//
// The merge deliberately does NOT collapse the modules. Each stays a SwiftPM target, so the layering
// is still enforced by the compiler exactly as strictly as it was across package boundaries, and a
// headless consumer depending only on the `OCCTSwiftTools` product still compiles no SwiftUI:
// SwiftPM builds only the targets reachable from the products you actually name. Module names are
// unchanged, so every consumer keeps its existing `import OCCTSwiftTools` / `import OCCTSwiftAIS` /
// `import OCCTSwiftCADKit` lines and changes only the package reference in its own manifest.
//
// Modeled on OCCTSwiftUX, which has vended six targets from one package since well before this.
let package = Package(
    name: "OCCTSwiftInteraction",
    // iOS and macOS, and only those two. `OCCT.xcframework`'s `Info.plist` carries exactly three
    // slices, `ios-arm64`, `ios-arm64-simulator` and `macos-arm64`, supporting two platforms, and
    // OCCTSwift's own v3.0.0 release notes open with "macOS / iOS (device + simulator)". Anything
    // linking the kernel on visionOS or tvOS cannot link at all.
    //
    // This manifest declared `.visionOS(.v1)` and `.tvOS(.v18)` until the 1.0.0 sweep, taking the
    // union of what OCCTSwiftTools, OCCTSwiftAIS and OCCTSwiftCADKit declared during the merge so
    // as not to regress the two targets with the most dependents. That reasoning was wrong in a way
    // invisible from the manifests: the wider claim was never true for any of the three, so there
    // was nothing to regress. Root cause is filed upstream as
    // https://github.com/SecondMouseAU/OCCTSwift/issues/978.
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "OCCTSwiftTools", targets: ["OCCTSwiftTools"]),
        .library(name: "OCCTSwiftAIS", targets: ["OCCTSwiftAIS"]),
        .library(name: "OCCTSwiftCADKit", targets: ["OCCTSwiftCADKit"]),
    ],
    dependencies: [
        // >=3.0.0: `Selector.SubShapeType.compsolid` renamed `.compSolid`, and six bounding-box
        // accessors became Optional (OCCTSwift docs/SEMVER.md#v300). Audited across all three
        // targets during the v3.0.0 fanout (ecosystem#39): none needed a source change for it.
        occtDep("OCCTSwift", from: "3.0.0"),
        occtDep("OCCTSwiftViewport", from: "1.1.26"),
        // >=1.7.8: the release carrying OCCTSwift 3.0.0.
        occtDep("OCCTSwiftIO", from: "1.7.8"),
    ],
    targets: [
        .target(
            name: "OCCTSwiftTools",
            dependencies: [
                .product(name: "OCCTSwift", package: "OCCTSwift"),
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
                .product(name: "OCCTSwiftIO", package: "OCCTSwiftIO"),
            ],
            path: "Sources/OCCTSwiftTools",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "OCCTSwiftAIS",
            dependencies: ["OCCTSwiftTools"],
            path: "Sources/OCCTSwiftAIS",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "OCCTSwiftCADKit",
            dependencies: [
                "OCCTSwiftTools",
                "OCCTSwiftAIS",
                .product(name: "OCCTSwift", package: "OCCTSwift"),
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
            ],
            path: "Sources/OCCTSwiftCADKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OCCTSwiftToolsTests",
            dependencies: ["OCCTSwiftTools"],
            path: "Tests/OCCTSwiftToolsTests"
        ),
        .testTarget(
            name: "OCCTSwiftAISTests",
            dependencies: ["OCCTSwiftAIS"],
            path: "Tests/OCCTSwiftAISTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OCCTSwiftCADKitTests",
            dependencies: ["OCCTSwiftCADKit"],
            path: "Tests/OCCTSwiftCADKitTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
