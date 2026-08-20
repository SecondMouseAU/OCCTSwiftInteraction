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
- Version line starts at `0.x`. The gate on `1.0.0` was the picking consolidation (ecosystem#43),
  and **that gate is now met**: all six phases have landed and the duplication audit below found no
  unresolved collision. The three old version lines do not continue here.
- LGPL-2.1, matching OCCT.

## Settled, so do not re-decide it

The picking consolidation (ecosystem#43) is **complete across all six phases**, and every collision
it enumerated has been resolved. Each of these is an answer someone worked for, not a default:

- **Pick resolution has exactly one implementation**
  ([#2](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/2), phase 2).
  `OCCTSwiftTools.SubShapePickResolver` is the only place a render-path ordinal becomes a
  `SubShapeRef`. `OCCTSwiftAIS.InteractiveContext.resolve*SubShape` are thin wrappers over it that
  add selection-mode gating and the whole-body fallback, and nothing else. That fallback stays in
  AIS deliberately: "the pick names the object rather than one of its faces" is a selection
  decision, not an identity one, and OCCT draws the same line at
  `SelectMgr_EntityOwner::ComesFromDecomposition()`. Read ecosystem#43 before writing anything that
  maps a `PickResult` to topology.
- **Selection state lives in `OCCTSwiftAIS`, and `OCCTSwiftCADKit` is a façade over it**
  ([#3](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/3), phase 3). CADKit's
  `select`/`clearSelection` delegate to `interactiveContext` and add only viewport-side concerns:
  the enrichment cache, highlight bodies and the rebuild. `remove`/`removeAll` share the verb but
  act on CADKit's own entity and body model, which AIS has no equivalent of. There is no longer a
  second selection system.
- **Face identity is OCCT's `IsSame` semantics**, so `faces()` (deduplicated) is the enumeration
  behind `FaceIdentityTable`, and a face shared between two shells is one identity
  ([#1](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/1), phase 0). Encode it.
- **The rest of the fleet is consolidated too**: `OCCTSwiftUX.ShapeEnricher` is an adapter over the
  Tools resolver (OCCTSwiftUX#29, phase 4), `OCCTMCP.SelectionRegistry` is re-keyed on `GraphUID`
  (OCCTMCP#182, phase 5), and `OCCTSwiftViewport.PickResultFilter` is renamed away from the
  `SelectionFilter` collision (OCCTSwiftViewport#111, phase 1). Four implementations became one.

## Known open work

- **`Axis` exists in both `OCCTSwiftAIS` and `OCCTSwiftCADKit`, on purpose.**
  `ManipulatorWidget.Axis` is nested and carries widget `direction` and `color`;
  `OCCTSwiftCADKit.Axis` is the axis a `.wipe` comparison splits along, and mirrors the concept
  rather than re-exporting a widget type for an unrelated purpose. The shared part is three lines
  of unit-vector arithmetic. What is worth a second look before 1.0 is not the duplication but the
  name: `Axis` is a broad thing for this package to claim at the top level of its public surface,
  and public names are much harder to change after 1.0 than before it.

## Policies

- [Query `context` first for OCCT / OCCTSwift docs](policies/context-first.md)
- [Documentation updates are mandatory](policies/docs-current.md)
- [No em-dashes, banned words in prose](policies/writing-style.md)
- [Search before building](policies/search-before-building.md)
- [Code structure](policies/code-structure.md)
- [Issue labels and project-board tracking](policies/issue-tracking.md)
- [Code style](policies/code-style.md)
