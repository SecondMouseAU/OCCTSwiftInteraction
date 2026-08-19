---
type: index
title: OCCTSwiftInteraction components
resource: https://github.com/SecondMouseAU/OCCTSwiftInteraction
tags: [index, okf, components]
description: The three targets this package vends, each with its own component bundle.
---

# Components

This package vends three SwiftPM targets in a strict upward dependency direction. Each keeps its
own component bundle, carried over from when it was its own repository.

- [OCCTSwiftTools](OCCTSwiftTools.md): kernel-to-renderer bridge. Shape into ViewportBody with
  picking metadata, plus the Face/Edge/VertexIdentityTables. Depends on no UI framework, and must
  not gain one: headless consumers take this product alone.
- [OCCTSwiftAIS](OCCTSwiftAIS.md): interactive services. Selection state, modes, schemes, filters,
  area selection, manipulator widgets, dimensions. Modeled on OCCT's own `AIS_*`.
- [OCCTSwiftCADKit](OCCTSwiftCADKit.md): the assembled SwiftUI CAD viewport service. Import,
  picking, clipping, camera framing.

The layering is enforced by target dependencies, so the compiler checks it exactly as strictly as
it did when these were three packages.
