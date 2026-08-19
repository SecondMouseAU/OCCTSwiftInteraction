---
type: repo
title: OCCTSwiftInteraction
resource: https://github.com/SecondMouseAU/OCCTSwiftInteraction
tags: [cad, occt, bridge, viewport, selection, picking, identity, swift, kernel]
description: Identity, selection and the assembled CAD viewport service. One package vending three targets (OCCTSwiftTools, OCCTSwiftAIS, OCCTSwiftCADKit), merged from three repositories so the layers version and release together.
timestamp: 2026-08-19
---

# OCCTSwiftInteraction

> Everything between raw geometry and a user pointing at it. Turns OCCTSwift geometry into
> renderable `ViewportBody` instances with GPU pick metadata, gives a picked ordinal a durable
> topological identity, holds the selection state built on top of that, and assembles the whole
> thing into a SwiftUI CAD viewport service.

## Role in the ecosystem

- **Cluster:** kernel
- **Depends on:**
  [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) (B-Rep kernel, >= v3.0.0),
  [OCCTSwiftViewport](https://github.com/SecondMouseAU/OCCTSwiftViewport) (Metal renderer and
  `ViewportBody`, >= v1.1.26), and
  [OCCTSwiftIO](https://github.com/SecondMouseAU/OCCTSwiftIO) (headless file I/O, >= v1.7.8).
- **Feeds:** OCCTSwiftUX, OCCTMCP, OCCTSwiftScripts, OCCTParts, PadCAM, OCCTDesignLoop, OCCTStudio.
- The two kernels below stay decoupled because the bridge lives here: OCCTSwiftViewport carries no
  OCCT dependency at all.

## Three targets, one package

This repository is the merge of three former ones (ecosystem#42). The module boundaries survive as
SwiftPM targets, so the layering is still compiler-enforced; what went away is three version lines
that only ever moved together, three release cuts in strict order, and three CI setups.

| Target | Owns | UI framework |
|---|---|---|
| [OCCTSwiftTools](components/OCCTSwiftTools.md) | Shape to ViewportBody conversion, CAD file loading, and the `Face`/`Edge`/`VertexIdentityTable`s that mint durable topological identity | **none, and must stay that way** |
| [OCCTSwiftAIS](components/OCCTSwiftAIS.md) | Selection state, modes, schemes, filters, area selection, manipulator widgets, dimension annotations. Modeled on OCCT's own `AIS_*` | SwiftUI |
| [OCCTSwiftCADKit](components/OCCTSwiftCADKit.md) | The assembled CAD viewport service: import, picking, clipping, camera framing | SwiftUI |

`OCCTSwiftTools` having no UI import is load-bearing rather than incidental. Headless consumers take
that product alone, and SwiftPM compiles only the targets reachable from the products a consumer
names, so a UI import there would cost every headless build.

## Components

See [`components/`](components/index.md) for the three per-target bundles.

## References

See [`references/`](references/index.md).

## Notes

- Per-target specs: [OCCTSwiftTools](../docs/spec/OCCTSwiftTools.md),
  [OCCTSwiftAIS](../docs/spec/OCCTSwiftAIS.md). OCCTSwiftCADKit has no spec.
- Migration from the three old packages: [docs/MIGRATION.md](../docs/MIGRATION.md).
- Platforms are **macOS 15+ and iOS 18+, and only those two**: the floor is the higher of
  OCCTSwift's and OCCTSwiftViewport's, and the set is what the kernel actually ships.
  `OCCT.xcframework` carries exactly three slices (`ios-arm64`, `ios-arm64-simulator`,
  `macos-arm64`), so nothing links on visionOS or tvOS. The manifest inherited a `visionOS`/`tvOS`
  claim from the pre-merge Tools and AIS manifests, where it was never true either; dropped before
  1.0.0, root cause filed as
  [OCCTSwift#978](https://github.com/SecondMouseAU/OCCTSwift/issues/978).
- Version line starts at `0.x`, reaching `1.0.0` once the picking consolidation (ecosystem#43) has
  landed. The three old version lines do not continue here.
- LGPL-2.1, matching OCCT.

## Known open work

- **Pick resolution is consolidated inside this repo** as of
  [#2](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/2) (phase 2 of ecosystem#43):
  `OCCTSwiftTools.SubShapePickResolver` is the only place a render-path ordinal becomes a
  `SubShapeRef`, and both this repo's targets call it. Clip-plane awareness, geometry enrichment and
  the whole-body fallback deliberately stayed in their own layers. The wider fleet still carries two
  more implementations (OCCTSwiftUX#29, OCCTMCP#182); read ecosystem#43 before writing anything that
  maps a `PickResult` to topology.
- **The two parallel selection systems** (`select` / `clearSelection` / `remove` / `removeAll` in
  both `OCCTSwiftAIS` and `OCCTSwiftCADKit`) are still separate, tracked as
  [#3](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/3), and need their own behaviour
  matrix before either copy goes.
- **Face identity is decided and settled**: OCCT's `IsSame` semantics, so `faces()` (deduplicated)
  is the enumeration behind `FaceIdentityTable` and a face shared between two shells is one identity
  ([#1](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/1), phase 0 of ecosystem#43).
  Encode it rather than re-deciding it.

## Policies

- [Query `context` first for OCCT / OCCTSwift docs](policies/context-first.md)
- [Documentation updates are mandatory](policies/docs-current.md)
- [No em-dashes, banned words in prose](policies/writing-style.md)
- [Search before building](policies/search-before-building.md)
- [Code structure](policies/code-structure.md)
- [Issue labels and project-board tracking](policies/issue-tracking.md)
- [Code style](policies/code-style.md)
