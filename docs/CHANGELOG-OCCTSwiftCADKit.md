---
title: Changelog (CADKit)
nav_order: 6
---

# Changelog

Most recent first. Breaking changes and deprecations documented here.

Started at OCCTSwiftInteraction#3, the first change to this target that a consumer has to read
before upgrading. Earlier history is in the pre-merge `OCCTSwiftCADKit` repository.

## Unreleased

### `CADViewportService` stops building identity tables and reads the loader's

Closes [OCCTSwiftInteraction#7](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/7).

This service carried a private copy of `OCCTSwiftTools.CADFileLoader`'s three identity-table
builders, and said so: *"Mirrors the private `makeFaceIdentityTable` in
`OCCTSwiftTools.CADFileLoader`"*. It existed because `CADFileLoader.load(from:format:)` returned
no tables, so the only way to get identity after a multi-body file load was to rebuild it here.
`CADLoadResult.identity` now exists, so the copy is gone.

#### What changes for a consumer

Nothing in the public API. `rebuildIdentity(bodies:shapes:)` and `addIdentity(bodyIDs:shapes:)`
were both internal; they are replaced by a single internal `installIdentity(_:)` taking
`[String: OCCTSwiftTools.ShapeIdentity]`.

One behaviour improves. Both file-loading paths used to detect a `shapes`/`bodies` count mismatch
and drop durable identity for **every** body rather than risk pairing one with the wrong shape
(the mismatch is produced by `CADFileLoader`'s STL/IGES robust reload, which appends a shape even
when that input produced no body). A file that hit that case therefore loaded with picks that
resolved to nothing at all, including for bodies that were paired correctly. The loader now keys
identity by body id in the same branch that creates each body, so there is no positional pairing
anywhere and no mismatch to detect: those bodies now pick normally.

The guard was also implemented three times for one hazard. `loadFile(from:id:)` pre-detected the
mismatch at the call site and `addIdentity` re-detected it; `rebuildIdentity`'s wholesale wipe of
`bodyShapes` / `bodyGraphs` / all three tables ran against dictionaries `resetAllModelState()` had
emptied on the line above.

`replaceBody` (the cap-plane re-tessellation path) keeps one thing the shared installer does not
do: it still removes a stale `BRepGraph` when the new capped shape fails to build one, since
`installIdentity` merges and would otherwise leave a graph naming pre-cap topology.

### `CADViewportService` adopts the interactive context's selection

Closes [OCCTSwiftInteraction#3](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/3),
phase 3 of [ecosystem#43](https://github.com/SecondMouseAU/ecosystem/issues/43).

This service held an `InteractiveContext` and ran a second selection alongside it. Its own source
described the situation: `.body` "exists on `SelectionMode` for
`OCCTSwiftAIS.InteractiveContext.selectionMode`, a separate, independent selection system this
service does not share state with". There is now one selection.

#### What breaks

**1. `SelectionSummary` is renamed to `SelectionMeasurements`**, and `selectionSummary` to
`selectionMeasurements`. Both old spellings still resolve as deprecated aliases, so this is a
warning rather than an error today. The reason is a name collision, not a merge:
`OCCTSwiftUXKit.SelectionSummary` is an unrelated public type (a selection pill's caption and SF
Symbol, built from `EntityRef` values) sharing no field, no input and no consumer with this one.
The bakeoff on the issue found nothing to merge, so the collision is resolved by naming, the same
way OCCTSwiftViewport's `SelectionFilter` was in phase 1.

**2. `selection` is no longer in the order entries were selected.** It is ordered by (body id,
kind, ordinal). The underlying store is now a `Set<SubShape>`, so there is no insertion order left
to preserve; the ordering is deterministic, just not chronological. Code that assumed `selection`
grew by appending, or read `selection.last` as "the most recent pick", needs to change.

**3. Assigning `selectionModes` clears the selection.** It is now `interactiveContext.selectionMode`
itself, and that property's documented behaviour is to clear the selection when the mode set
changes. Previously `selectionModes` was plain storage. Set the modes before selecting, not after.

**4. `selectionModes` and `interactiveContext.selectionMode` are one setting.** Writing either
writes the other. The service initialises it to `[.face]` at `init`, which **overrides the
interactive context's own `[.body]` default**. An app that displays extra geometry into the
context (`interactiveContext.display(_:style:)`) and relied on picks against it producing a
whole-body selection now gets a face selection instead: set `service.selectionModes = [.body]`, or
`[.face, .body]`, to choose deliberately.

**5. The two selections are no longer independent.** A pick on a model body replaces the whole
shared selection, including anything selected for an object displayed into the interactive
context, and a pick on empty space clears all of it. A pick on a body the context displays itself
is left for the context to resolve, rather than being treated as an unresolved pick and clearing
the selection.

**6. `PickedFaceInfo`, `PickedEdgeInfo` and `PickedVertexInfo` now store an
`OCCTSwiftTools.SubShapeRef`** as `ref`, with `shape`, `uid` and `faceIndex` / `edgeIndex` /
`vertexIndex` forwarding to it. Every existing read compiles unchanged, and the previous
memberwise initialisers are kept as source-compatible conveniences, so this breaks nothing today.
It matters because it makes the types derived from the resolver's identity rather than parallel to
it: the three hand-written `==` implementations, each commented "mirrors
`OCCTSwiftAIS.SubShapeRef.==` exactly", are now one shared `isSamePick` rule.

**7. `PickedFaceInfo.scalarValue` can now be `nil` where it was not.** For a `.perTriangle` scalar
field only, and only for a face that reached the selection without a pick (through the interactive
context directly, or by area selection): there is no picked triangle to sample. A `.perFace` field
is unaffected, and a real pick is unaffected.

#### What does not break

`selection`, `select(_:scheme:)`, `clearSelection()`, `selected`, `selectedFace`, `PickedEntity`
and the whole loading, overlay, clipping, comparison, scalar-field and escalation surface are
unchanged. `PickedEntity` gains no case: whole-body selection is a `SubShape.body` in the
interactive context, not a fourth `PickedEntity`.

#### For the two known consumers

- **PadCAM** reads `viewportService.selectedFace` (three sites) and calls `clearSelection()` (one
  site), and reads only `bounds`, `zLevel` and `description` off it. All four keep working
  unchanged. Its one exposure is item 4: it displays a stock box via
  `interactiveContext.display(_:style:)` and installs a `ManipulatorWidget` on it, so picks
  against that stock body now resolve under `[.face]` rather than `[.body]`.
- **OCCTSwiftUX** does not depend on this target at all, in either direction. Its own
  `SelectionSummary` is untouched and stays where it is.

#### Tests

10 new in `SharedSelectionTests`, covering the shared mode set, both directions of the shared
selection, on-demand enrichment, ordering, the AIS-body pick case, ref forwarding, and cross-body
identity. Package total 330 to 343 in 28 to 30 suites, all passing, none deleted or weakened.
