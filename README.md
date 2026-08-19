# OCCTSwiftInteraction

[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FSecondMouseAU%2FOCCTSwiftInteraction%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/SecondMouseAU/OCCTSwiftInteraction)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FSecondMouseAU%2FOCCTSwiftInteraction%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/SecondMouseAU/OCCTSwiftInteraction)
[![License](https://img.shields.io/badge/license-LGPL--2.1-blue)](LICENSE)

Identity, selection, and the assembled CAD viewport service for the OCCTSwift stack.

Part of the [OCCTSwift ecosystem](https://github.com/SecondMouseAU/OCCTSwift/blob/main/docs/ecosystem.md).

> Status: **0.x**, heading for `1.0.0` once the picking consolidation
> ([ecosystem#42](https://github.com/SecondMouseAU/ecosystem/issues/42)) has landed and settled.

## Three targets, one package

```
OCCTSwiftTools      kernel-to-renderer bridge: Shape into ViewportBody with picking metadata,
                    plus the identity tables that give a picked ordinal a durable
                    topological identity. No UI framework of any kind.
  └─ OCCTSwiftAIS   interactive services: selection state, modes, schemes, filters, area
                    selection, manipulator widgets, dimensions. Modeled on OCCT's own AIS_*.
       └─ OCCTSwiftCADKit    the assembled SwiftUI CAD viewport service: import, picking,
                             clipping, camera framing.
```

```swift
import OCCTSwift
import OCCTSwiftTools

let box = Shape.box(width: 10, height: 5, depth: 3)!
let body = ViewportBody.from(box)!
```

## Why one package instead of three

These were three repositories until [ecosystem#41](https://github.com/SecondMouseAU/ecosystem/issues/41).
The boundaries between them are real; the packaging of them was not. Three version lines that only
ever moved together, three release cuts that had to happen in strict order, three CI setups. A
single cross-cutting change needed six sequenced pull requests across three repositories with a
release between each. `OCCTSwiftTools` was 1,123 lines across 9 files, carrying more repository
overhead than code.

**The merge does not collapse the modules.** Each is still a SwiftPM target, so the layering stays
enforced by the compiler exactly as strictly as it was across package boundaries. Depending on this
package does not pull SwiftUI into a headless build: SwiftPM compiles only the targets reachable
from the products you name, and `OCCTSwiftTools` imports no UI framework.

This follows `OCCTSwiftUX`, which has vended six targets from one package since well before this.

## Migrating

Your `import` lines do not change. See [docs/MIGRATION.md](docs/MIGRATION.md).

## Documentation

- [docs/MIGRATION.md](docs/MIGRATION.md), moving from the three old packages
- [docs/reference/](docs/reference/), per-type reference across all three targets
- [docs/guides/](docs/guides/), getting started and cookbook
- Historical changelogs: [OCCTSwiftTools](docs/CHANGELOG-OCCTSwiftTools.md),
  [OCCTSwiftAIS](docs/CHANGELOG-OCCTSwiftAIS.md)

## Known issues

`InteractiveContextMutationTests` fails 5 assertions, carried over from before the merge and tracked
as [OCCTSwiftAIS#46](https://github.com/SecondMouseAU/OCCTSwiftAIS/issues/46). The test asserts a
`Shape.faces()` enumeration split that OCCTSwift 2.0.0 erased. Fixing it requires deciding whether
face identity keys on `faces()` or `orientedFaces()`, which is also the first step of the picking
consolidation.
