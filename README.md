# OCCTSwiftTools

[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FSecondMouseAU%2FOCCTSwiftTools%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/SecondMouseAU/OCCTSwiftTools)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FSecondMouseAU%2FOCCTSwiftTools%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/SecondMouseAU/OCCTSwiftTools)
[![License](https://img.shields.io/badge/license-LGPL--2.1-blue)](LICENSE)

The bridge layer between [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) (B-Rep modeling kernel) and [OCCTSwiftViewport](https://github.com/SecondMouseAU/OCCTSwiftViewport) (Metal viewport).

Part of the [OCCTSwift ecosystem](https://github.com/SecondMouseAU/OCCTSwift/blob/main/docs/ecosystem.md) — see the ecosystem map for how this package fits with the kernel, viewport, and sibling layers.

> Status: **v1.6.0**. SemVer-stable from v1.0.0; versioning follows the [cohort SemVer policy](https://github.com/SecondMouseAU/OCCTSwift/blob/main/docs/SEMVER.md). See [docs/CHANGELOG.md](docs/CHANGELOG.md) and [SPEC.md](SPEC.md).

## What it does

```swift
import OCCTSwift
import OCCTSwiftTools

let box = Shape.box(width: 10, height: 5, depth: 3)!
let body = ViewportBody.from(box)!     // ← this lives here
```

Plus one-shot file loaders:

```swift
let bodies = try CADFile.loadSTEP(at: stepURL)
let mesh   = try CADFile.loadSTL(at: stlURL)
```

## Architecture position

```
OCCTSwiftAIS          (selection / manipulator / dimensions; sibling repo)
       ↑
OCCTSwiftTools        ← this repo
       ↑      ↑
OCCTSwift   OCCTSwiftViewport
(B-Rep)     (Metal renderer)
```

OCCTSwiftTools is the only repo that depends on **both** sibling kernels. OCCTSwiftAIS depends on this; the two kernels stay decoupled from each other.

## Converters

Per-domain helpers that turn an OCCT-or-raw input into a `ViewportBody`:

| Helper | Input | Output body shape |
|---|---|---|
| `CADFileLoader.shapeToBodyAndMetadata` | `OCCTSwift.Shape` | Triangulated mesh + picking metadata |
| `CurveConverter.curve2DToBody` / `curve3DToBody` | `Curve2D` / `Curve3D` | Edge polyline (no mesh) |
| `SurfaceConverter` | `Surface` | Triangulated surface mesh |
| `WireConverter.wireToBody` | `Wire` | Edge polyline |
| `PointConverter.pointsToBody` | `[SIMD3<Float>]` | Point list (no mesh, no edges) |

> **Note on `PointConverter`**: produces a `ViewportBody` with `primitiveKind == .point`, drawn by the point-cloud rendering pipeline added in [OCCTSwiftViewport v1.0.2](https://github.com/SecondMouseAU/OCCTSwiftViewport/releases/tag/v1.0.2) (issue [#28](https://github.com/SecondMouseAU/OCCTSwiftViewport/issues/28)). `pointRadius` and `perPointColors` are now carried through to the body's `pointRadius` and `vertexColors` fields; consumers (e.g. OCCTMCP's `add_scene_primitive(pointCloud)`) can lift their previous sphere-compound caps and render tens of thousands of points cleanly.

## Identity tables

`shapeToBodyMetadataAndIdentities` (and the narrower `shapeToBodyMetadataAndIdentity`) resolve a
render-path face / edge / vertex ordinal back to the `Shape` it was extracted from, and, when a
`TopologyGraph` is supplied, to a durable `GraphUID`. See
[FaceIdentityTable](docs/reference/FaceIdentityTable.md),
[EdgeIdentityTable](docs/reference/EdgeIdentityTable.md), and
[VertexIdentityTable](docs/reference/VertexIdentityTable.md).

## Installation

```swift
.package(url: "https://github.com/SecondMouseAU/OCCTSwiftTools.git", from: "1.6.0"),
```

## Supported platforms

| Platform | Status |
|---|---|
| macOS 15+ arm64 | Supported |
| iOS 18+ device + simulator arm64 | Supported |
| visionOS 1+ device + simulator arm64 | Supported |
| tvOS 18+ device + simulator arm64 | Supported |

The platform floor is the **higher** of OCCTSwift's (12.0 / 15.0) and OCCTSwiftViewport's (15.0 / 18.0).

## Status

Active. Requires `OCCTSwift` ≥ `v0.168.0` (for `ImportProgress`) and `OCCTSwiftViewport` ≥ `v0.55.0` (for the GPU edge/vertex pick fields populated by `shapeToBodyAndMetadata`). See [docs/CHANGELOG.md](docs/CHANGELOG.md) for release history and [SPEC.md](SPEC.md) for the public API surface and roadmap.

## License

LGPL 2.1 (matching OCCT). See [LICENSE](LICENSE).
