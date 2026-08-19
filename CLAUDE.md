# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo state

**This repo is the merge of three: `OCCTSwiftTools`, `OCCTSwiftAIS` and `OCCTSwiftCADKit`**
(ecosystem#41). Each is still its own SwiftPM target under `Sources/<Module>` with tests under
`Tests/<Module>Tests`, and the module names are unchanged, so consumers keep their existing `import`
lines. The layering is enforced by target dependencies, not convention: `OCCTSwiftTools` depends on
no UI framework and must stay that way, because headless consumers (OCCTSwiftScripts, OCCTMCP) take
that product alone and SwiftPM only compiles what they name.

Version line starts at `0.x`, reaching `1.0.0` once the picking consolidation (ecosystem#42) has
landed and settled. The three old version lines do not continue here.

**Known failing test:** `InteractiveContextMutationTests` fails 5 assertions (OCCTSwiftAIS#46),
inherited from before the merge. It asserts a `Shape.faces()` enumeration split that OCCTSwift 2.0.0
erased. Do not "fix" it by relaxing the assertions; it is the regression test OCCTSwiftAIS#31 exists
to keep. The real fix is deciding whether face identity keys on `faces()` or `orientedFaces()`,
which is also step one of ecosystem#42.

**Docs still to finish after the merge:** `okf/index.md` and this file still describe the
OCCTSwiftTools half in more detail than the other two. Tracked on the migration issue.

## Architectural position (load-bearing context)

```
OCCTSwiftAIS         (selection / manipulators / dimensions — sibling repo, depends on us)
       ↑
OCCTSwiftTools       ← this repo: the only library that depends on BOTH siblings below
       ↑      ↑
OCCTSwift   OCCTSwiftViewport
(B-Rep)     (Metal renderer, intentionally OCCT-free)
```

The whole point of extracting this repo is to keep OCCTSwiftViewport cleanly OCCT-free so the two kernels stay decoupled. Do not add OCCT-aware code to OCCTSwiftViewport, and do not add Metal/rendering code to OCCTSwift — both of those go here.

**`ViewportBody.faceIndices` (per-triangle source-face index) is load-bearing.** OCCTSwiftAIS will read it to map GPU pick results back to `TopoDS_Face` instances. `CADBodyMetadata.faceIndices` mirrors it. Do not change semantics on either side without a coordinated change in OCCTSwiftAIS — the contract is `indices.count / 3 == faceIndices.count`, one face index per triangle.

## Build & test

```bash
swift build
OCCT_SERIAL=1 swift test --parallel --num-workers 1   # MUST run serially
swift test --filter OCCTSwiftToolsTests.SuiteName/testName   # single test
```

`OCCT_SERIAL=1` + serial workers is **required**, not optional: there is a known NCollection container-overflow race in OCCT on arm64 macOS that segfaults parallel test runs. This is inherited from OCCTSwift; do not "fix" it by re-enabling parallelism.

Dependencies resolve transitively — OCCTSwift ships `OCCT.xcframework` as a release asset, OCCTSwiftViewport is pure Swift. No binary lives in this repo.

## Platform floor

`Package.swift` pins `.iOS(.v18)`, `.macOS(.v15)`, `.visionOS(.v1)`, `.tvOS(.v18)`. This is the **max** of OCCTSwift's floor (12.0/15.0) and OCCTSwiftViewport's (15.0/18.0) — not arbitrary. If either sibling raises its floor, raise ours to match; never lower below either sibling.

## Conventions cribbed from OCCTSwift

These are the non-obvious ones — match the kernel repo exactly:

- **License**: LGPL 2.1 with `OCCT_LGPL_EXCEPTION` (matches OCCT itself). Already in `LICENSE`.
- **Swift**: tools-version 6.1, language mode `.v6`.
- **Tests**: Swift Testing (`@Suite` / `@Test` / `#expect`). Swift Testing **does not short-circuit** — never write `#expect(x != nil); #expect(x!.isValid)`. Always `if let x { #expect(x.isValid) }`.
- **Test names must not shadow API method names** used inside the test body — the test runner gets confused. Prefix `t_` or use descriptive English.
- **CODE_OF_CONDUCT.md**: short pointer to Contributor Covenant 2.1 only. **Never inline the full Covenant text** — Anthropic's content filter blocks it and the commit will fail mid-write.
- **Versioning (pre-1.0)**: tiny additive features = patch bump (x.y.z+1). Minor bumps only for new public API surface. Free to break — document deprecations in `docs/CHANGELOG.md` (most recent first, "Current" header pinned to the new version).
- **Release pattern**: every shipped version commits + pushes + tags + creates a GitHub release with notes from CHANGELOG.
- **`.spi.yml`**: SPI build matrix already configured with `documentation_targets: [OCCTSwiftTools]`. SPI submission is gated on v1.0.0 — don't submit early.

## What is explicitly out of scope

Per SPEC.md: selection/picking semantics, manipulator widgets, and dimension annotations all belong to **OCCTSwiftAIS** (one layer above) — do not implement them here. Also out: headless ray-tracing (use CADRays separately), Linux/Windows/Android, watchOS.

## Ecosystem context worth reading before non-trivial changes

- `~/Projects/OCCTSwift/CLAUDE.md` — kernel project conventions (this repo follows them)
- `~/Projects/OCCTSwift/docs/visualization-research.md` — *why* the three-layer cake exists
- [docs/CHANGELOG.md](docs/CHANGELOG.md) — release history; v0.1.0 entry documents the dependency floor reasoning, including why OCCTSwiftViewport ≥ 0.51.0 is a hard floor (not advisory)
