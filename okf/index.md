---
type: repo
title: OCCTSwiftCADKit
resource: https://github.com/SecondMouseAU/OCCTSwiftCADKit
tags: [cad, occt, viewport, metal, swiftui, step, stl, brep, face-picking, kernel]
description: Shared SwiftUI Metal CAD viewport plus STEP/STL/BREP import and face picking for OCCT-based apps.
timestamp: 2026-06-22
---

# OCCTSwiftCADKit

> A reusable SwiftUI Metal viewport plus CAD file import (STEP/STL/BREP) and face picking, for apps
> built on OCCTSwift and OCCTSwiftViewport. Extracted from PadCAM's `CADViewportService` /
> `CADViewportView` so multiple OCCT-based apps can share the same viewport plumbing without
> forking it.

## Role in the ecosystem

- **Cluster:** kernel
- **Depends on:** [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) (geometry kernel), [OCCTSwiftViewport](https://github.com/SecondMouseAU/OCCTSwiftViewport) (Metal renderer), [OCCTSwiftTools](https://github.com/SecondMouseAU/OCCTSwiftTools) (Shape ↔ ViewportBody bridge / file utilities), and [OCCTSwiftAIS](https://github.com/SecondMouseAU/OCCTSwiftAIS) (interactive services).
- **Feeds:** OCCT-based applications (PadCAM, the UnfoldEngine test app, and similar) that need a drop-in CAD viewport. Note: its viewport-service role is also being absorbed into OCCTSwiftUX's `OCCTSwiftUXViewportService` layer.

## Components

See [`components/`](components/index.md) for the public surface.

## References

See [`references/`](references/index.md) for sibling repos and upstream links.
