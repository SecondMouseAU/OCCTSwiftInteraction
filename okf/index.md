---
type: repo
title: OCCTSwiftTools
resource: https://github.com/SecondMouseAU/OCCTSwiftTools
tags: [cad, occt, bridge, viewport, converters, swift, kernel]
description: Bridge layer between the OCCTSwift kernel and the OCCTSwiftViewport renderer — converts Shapes/curves/surfaces into ViewportBody and loads CAD files.
timestamp: 2026-06-22
---

# OCCTSwiftTools

> The bridge layer of the ecosystem: it turns OCCTSwift geometry (`Shape`, `Curve2D`/`Curve3D`,
> `Surface`, `Wire`, point sets) into renderable `ViewportBody` instances with triangulated meshes
> and GPU pick metadata, and provides one-shot CAD file loaders. It is the only repo that depends
> on **both** sibling kernels, keeping OCCTSwift and OCCTSwiftViewport decoupled from each other.

## Role in the ecosystem

- **Cluster:** kernel
- **Depends on:**
  [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) (B-Rep kernel, ≥ v1.7.1),
  [OCCTSwiftViewport](https://github.com/SecondMouseAU/OCCTSwiftViewport) (Metal renderer / `ViewportBody`, ≥ v1.1.20), and
  [OCCTSwiftIO](https://github.com/SecondMouseAU/OCCTSwiftIO) (headless file I/O, ≥ v1.0.1).
- **Feeds:** OCCTSwiftAIS (selection / manipulators / dimensions) and any app that needs to display
  OCCTSwift geometry in the viewport. The two kernels stay decoupled because the bridge lives here.

## Components

See [`components/`](components/index.md) for the public converter and loader surface
(`CADFileLoader`, `ExportManager`, the per-domain converters, and the script-manifest types).

## References

See [`references/`](references/index.md) for the API spec, changelog, the Swift Package Index page,
and OpenCASCADE upstream.

## Notes

- Public API surface and roadmap are documented in
  [SPEC.md](https://github.com/SecondMouseAU/OCCTSwiftTools/blob/main/SPEC.md).
- Platform floor is the higher of OCCTSwift's and OCCTSwiftViewport's (macOS 15 / iOS 18).
- Published to the Swift Package Index via `.spi.yml`. LGPL-2.1 (matching OCCT).

## Policies

- [Query `context` first for OCCT / OCCTSwift docs](policies/context-first.md)
- [Documentation updates are mandatory](policies/docs-current.md)
- [No em-dashes, banned words in prose](policies/writing-style.md)
- [Search before building](policies/search-before-building.md)
