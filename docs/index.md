---
title: OCCTSwiftInteraction
---

# OCCTSwiftInteraction

Identity, selection, and the assembled CAD viewport service for the OCCTSwift stack. One package,
three targets.

- **OCCTSwiftTools**: kernel-to-renderer bridge. `Shape` into `ViewportBody` with picking metadata,
  plus the `Face`/`Edge`/`VertexIdentityTable`s that give a picked ordinal a durable topological
  identity, and the one `SubShapePickResolver` every layer above resolves picks through. No UI
  framework.
- **OCCTSwiftAIS**: interactive services. Selection state, modes, schemes, filters, area selection,
  manipulator widgets, dimensions.
- **OCCTSwiftCADKit**: the assembled SwiftUI CAD viewport service. Import, picking, clipping,
  camera framing.

## Start here

- [Migrating from the three old packages](MIGRATION.md)
- Getting started: [OCCTSwiftAIS](guides/getting-started-OCCTSwiftAIS.md),
  [OCCTSwiftCADKit](guides/getting-started-OCCTSwiftCADKit.md)
- [Cookbook](guides/cookbook/)
- [Per-type reference](reference/), covering all three targets

## Specs

- [OCCTSwiftTools](spec/OCCTSwiftTools.md)
- [OCCTSwiftAIS](spec/OCCTSwiftAIS.md)

## Release history

These were three separate release lines before the merge, kept separate rather than interleaved:

- [OCCTSwiftTools](CHANGELOG-OCCTSwiftTools.md)
- [OCCTSwiftAIS](CHANGELOG-OCCTSwiftAIS.md)

## Pre-merge documentation indexes

Kept for anything they cover that the merged docs do not yet:

- [OCCTSwiftTools](index-OCCTSwiftTools.md)
- [OCCTSwiftAIS](index-OCCTSwiftAIS.md)
