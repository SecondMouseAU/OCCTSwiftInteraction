# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**The merge of three former repositories**: `OCCTSwiftTools`, `OCCTSwiftAIS` and `OCCTSwiftCADKit`
(ecosystem#42). Each is still its own SwiftPM target:

```
Sources/OCCTSwiftTools     Tests/OCCTSwiftToolsTests
Sources/OCCTSwiftAIS       Tests/OCCTSwiftAISTests
Sources/OCCTSwiftCADKit    Tests/OCCTSwiftCADKitTests
```

Module names are unchanged, so consumers keep their existing `import` lines and changed only the
package reference in their manifests. See [docs/MIGRATION.md](docs/MIGRATION.md).

Version line starts at `0.x`, reaching `1.0.0` once the picking consolidation (ecosystem#43) has
landed and settled. The three old version lines do not continue here.

## Layering, and the one rule that matters

```
OCCTSwiftCADKit    assembled SwiftUI CAD viewport service: import, picking, clipping, camera
      ↑
OCCTSwiftAIS       interactive services: selection state, modes, schemes, filters, area
                   selection, manipulator widgets, dimensions. Modeled on OCCT's own AIS_*
      ↑
OCCTSwiftTools     kernel-to-renderer bridge: Shape into ViewportBody with picking metadata,
                   plus Face/Edge/VertexIdentityTables. NO UI framework
      ↑        ↑
OCCTSwift    OCCTSwiftViewport
(B-Rep)      (Metal renderer, deliberately OCCT-free)
```

Direction is enforced by target dependencies, so the compiler checks it exactly as strictly as it
did when these were three packages. Never point a dependency back down.

**`OCCTSwiftTools` must not gain a UI framework import.** Headless consumers (OCCTSwiftScripts,
OCCTMCP) depend on that product alone, and SwiftPM compiles only the targets reachable from the
products a consumer names. Adding SwiftUI to `OCCTSwiftTools` would cost every headless build. This
is the property that made merging these three safe; it is worth not breaking.

Equally: do not add OCCT-aware code to `OCCTSwiftViewport`, and do not add Metal or rendering code
to `OCCTSwift`. Both belong here.

**`ViewportBody.faceIndices` (per-triangle source-face index) is load-bearing.** The `OCCTSwiftAIS`
target reads it to map GPU pick results back to `TopoDS_Face` instances, and
`CADBodyMetadata.faceIndices` mirrors it. The contract is `indices.count / 3 == faceIndices.count`,
one face index per triangle. Changing either side needs the other changed with it, which is now a
same-repo change rather than a cross-repo one.

## Build and test

```bash
swift build
OCCT_SERIAL=1 swift test --parallel --num-workers 1   # MUST run serially
swift test --filter OCCTSwiftAISTests                 # one target
```

`OCCT_SERIAL=1` with serial workers is **required**, not optional: there is a known NCollection
container-overflow race in OCCT on arm64 macOS that segfaults parallel test runs. Inherited from
OCCTSwift; do not "fix" it by re-enabling parallelism.

`swift build` does **not** compile test targets. Use `swift build --build-tests` or `swift test`
before concluding anything compiles. This is not pedantry: during the OCCTSwift v3.0.0 fanout,
OCCTSwiftIO built clean with zero errors while carrying three real breaks in its test target.

Dependencies resolve against local siblings when present (`../OCCTSwift` and friends), else the
published URLs. No binary lives in this repo.

**Expected baseline: 314 tests across 27 suites, of which 5 fail.** See below.

## Known failing test, do not "fix" it the easy way

`InteractiveContextMutationTests` fails 5 assertions
([OCCTSwiftInteraction#1](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/1),
formerly OCCTSwiftAIS#46). Inherited from before the merge.

It asserts the raw-versus-deduplicated `Shape.faces()` split that OCCTSwift **2.0.0** erased. Not a
v3.0.0 regression: `Shape.faces()` is byte-identical between the v2.0.0 and v3.0.0 tags.

**Do not relax the assertions.** They are the regression test OCCTSwiftAIS#31 exists to keep. The
real fix is deciding whether face identity keys on `faces()` or `orientedFaces()`, which is also
phase 0 of ecosystem#43 and blocks the rest of that work.

## Active known duplication

Picking is resolved in more than one place across these targets, tracked as ecosystem#43. Before
writing anything that maps a `PickResult` to topology, read that issue: there are already four
implementations across the fleet and two have silently diverged. Prefer the `OCCTSwiftTools`
identity tables as the source of durable identity over re-deriving from sub-shape enumeration.

## Where things are

Each module kept its own documentation through the merge rather than having it collapsed:

| | Tools | AIS | CADKit |
|---|---|---|---|
| Spec | [docs/spec/OCCTSwiftTools.md](docs/spec/OCCTSwiftTools.md) | [docs/spec/OCCTSwiftAIS.md](docs/spec/OCCTSwiftAIS.md) | none |
| Getting started | none | [guide](docs/guides/getting-started-OCCTSwiftAIS.md) | [guide](docs/guides/getting-started-OCCTSwiftCADKit.md) |
| Module notes | this file | [docs/module-notes/OCCTSwiftAIS.md](docs/module-notes/OCCTSwiftAIS.md) | [docs/module-notes/OCCTSwiftCADKit.md](docs/module-notes/OCCTSwiftCADKit.md) |
| okf component | [okf/components/OCCTSwiftTools.md](okf/components/OCCTSwiftTools.md) | [okf/components/OCCTSwiftAIS.md](okf/components/OCCTSwiftAIS.md) | [okf/components/OCCTSwiftCADKit.md](okf/components/OCCTSwiftCADKit.md) |
| Changelog | [docs/CHANGELOG-OCCTSwiftTools.md](docs/CHANGELOG-OCCTSwiftTools.md) | [docs/CHANGELOG-OCCTSwiftAIS.md](docs/CHANGELOG-OCCTSwiftAIS.md) | none |

`docs/module-notes/*.md` are the pre-merge `CLAUDE.md` files kept verbatim. They still speak as
though their module is its own repository; read them for module-specific traps, not for repo layout.

Per-type reference for all three targets is in [docs/reference/](docs/reference/).

## Conventions

- **License**: LGPL 2.1 with `OCCT_LGPL_EXCEPTION`, matching OCCT itself.
- **Swift**: tools-version 6.1, language mode `.v6`.
- **Tests**: Swift Testing (`@Suite` / `@Test` / `#expect`). Swift Testing does **not**
  short-circuit, so never write `#expect(x != nil); #expect(x!.isValid)`. Use `if let x { ... }`.
- **Test names must not shadow API method names** used in the test body; the runner gets confused.
  Prefix `t_` or use descriptive English.
- **No em-dashes** anywhere in code comments, commit messages, PR text or docs. Use commas, colons
  or parentheses. Banned words in prose: "honest", "honestly", "you're right".
- **CODE_OF_CONDUCT.md**: a short pointer to Contributor Covenant 2.1 only. Never inline the full
  Covenant text.
- **Release pattern**: commit, push, tag, and create a GitHub release with notes.

## Still to finish after the merge

- `okf/index.md` describes the OCCTSwiftTools half in more detail than the other two.
- The CADKit target's `visionOS`/`tvOS` build is unverified. `Package.swift` keeps the union of what
  the three declared, and CADKit declared only iOS and macOS. Confirm or narrow before 1.0.0.

## Ecosystem context worth reading before non-trivial changes

- `~/Projects/OCCTSwift/CLAUDE.md`, kernel project conventions that this repo follows
- `~/Projects/OCCTSwift/docs/visualization-research.md`, why the layer cake exists
- `~/Projects/ecosystem/okf/`, the shared policy set
