---
title: Changelog (CADKit)
nav_order: 6
---

# Changelog

Most recent first. Breaking changes and deprecations documented here.

Started at OCCTSwiftInteraction#3, the first change to this target that a consumer has to read
before upgrading. Earlier history is in the pre-merge `OCCTSwiftCADKit` repository.

## Unreleased

### New: optional label on an agent attention marker

Closes [OCCTSwiftInteraction#35](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/35).
Additive. A `highlight_requests` payload may carry `label`; `CADViewportService.agentAttentionLabel`
holds it beside `agentAttention` and `setAgentAttention(_:label:)` takes it (default nil). Empty
labels are ignored, and a label on a `target: "selection"` or `question` request is ignored.
OCCTMCP's `highlight_selection` needs a matching `label` input.

## 3.0.0-beta.3 (2026-10-02)

**Pre-release, same pins as 3.0.0-beta.2** (OCCTSwift 4.0.0-beta.4 exactly, OCCTSwiftIO 2.0.0-beta.1). A consumer only gets this by naming it; the stable line stays at 2.0.0.

### New: `load(_:id:graph:transform:)` takes the caller's `BRepGraph`

Closes [OCCTSwiftInteraction#27](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/27).

A host that already holds a graph for a shape passes it in, so a pick's `GraphUID` resolves in the
host's graph and the shape is not serialised and graphed a second time. `graph` must have been built
from `shape` as given; with a non-nil `transform` it is ignored and a fresh graph is minted from the
placed shape, since a graph of the unplaced shape would name the wrong sub-shapes. `load(_:id:
transform:)` is unchanged.

### New: `selectionChanges` publishes each selection change with its source

Closes [OCCTSwiftInteraction#31](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/31).

`CADViewportService.selectionChanges` emits a `SelectionChange` (`previous`, `current`, `source`)
from `syncSelection(with:)`, the one place every path ends. `source` is `.viewportPick`,
`.emptySpaceClick`, `.programmatic`, `.agentHighlight(requestID:)` or `.bodyRemoved(bodyID:)`. It
emits synchronously, only when the projected `selection` changed, so a whole-body change (which
moves `interactiveContext.selection` but not `selection`) does not emit. A change this service
cannot attribute, such as area selection or a pick on a body the context displays itself, reports
`.programmatic`. Removing a body with several selected sub-shapes publishes one `.bodyRemoved` change, not one per sub-shape. A pick that resolved to nothing (a mode or clip-plane rejection) reports
`.emptySpaceClick`.

## 3.0.0-beta.2 (2026-10-01)

**Pre-release, same pins as 3.0.0-beta.1** (OCCTSwift 4.0.0-beta.4 exactly, OCCTSwiftIO 2.0.0-beta.1). A consumer only gets this by naming it; the stable line stays at 2.0.0.

### Changed: an agent highlight no longer replaces the human's selection

Closes [OCCTSwiftInteraction#29](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/29).

A `highlight_requests/<id>.json` now carries an optional `target`, `"attention"` (the default) or
`"selection"`. Attention writes the new `CADViewportService.agentAttention`, one entity at a time,
and leaves `selection` and `selection.json` alone; the host renders the marker. `scheme` applies to
the attention slot (`remove` clears it, `xor` toggles it) unless the caller explicitly passes
`"selection"`, which keeps the old behaviour. Requests with a `question` still land in the
selection, since the escalation card reads it. `handled/<id>.json` gains `target` on `applied`.
`CADViewportService.setAgentAttention(_:)` lets a host dismiss the marker.

**Behaviour change for existing clients:** a request with no `target` used to select. Clients that
relied on that (OCCTMCP's `highlight_selection`) must send `"target": "selection"` until they move
to attention; the matching OCCTMCP change is still to do. See the ADR.
### Fixed: the click that activates the window no longer clears the selection

Closes [OCCTSwiftInteraction#28](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/28).

Clicking an unfocused window to re-focus it reached `handlePick(nil)` as an empty pick, which
deselects. `CADViewportView` now reports each mouse-down with whether its window was key
(`CADViewportService.noteMouseDown(windowWasActive:)`), and `handlePick` ignores the one empty
pick that answers an inactive-window click. The click still activates the window and still picks a
body if it hits one. Hosts using `CADViewportView(service:)` get this automatically; hosts using
the long initializer pass `onMouseDown: { viewport.noteMouseDown(windowWasActive: $0) }`.

## 3.0.0-beta.1 (2026-09-29)

**Pre-release, pinned exactly to OCCTSwift 4.0.0-beta.4.** A consumer only gets this by naming it; the stable line stays at 2.0.0.

### Breaking: `CADFileLoader`'s GD&T element types (OCCTSwiftTools target)

OCCTSwift 4.0.0 replaces the untyped `DimensionInfo`, `GeomToleranceInfo` and `DatumInfo` with the typed
`Document.Dimension`, `Document.GeomTolerance` and `Document.Datum`
([OCCTSwift#996](https://github.com/SecondMouseAU/OCCTSwift/issues/996)). `CADLoadResult.dimensions`,
`.geomTolerances` and `.datums`, and their initializer parameters, use the new types, so the major version
moves. `Document.Dimension.value` is `Double?` and a range dimension reports its bounds through `.bounds`.
The reference pages and the cookbook example are updated.

### Dependencies

- `OCCTSwift exact: "4.0.0-beta.4"`. Exact, not `from:`, because `v4.0.0-kernel.N` tags are pre-releases of
  the same package that sort above every beta, so `from: "4.0.0-beta.4"` would resolve to one of them
  (main's source) rather than the beta.
- `OCCTSwiftIO from: "2.0.0-beta.1"`, the release that carries the same GD&T type change.

Verified: `swift build --build-tests` is clean and all three test targets pass against the real beta.4 and IO 2.0.0-beta.1 checkouts.

## 2.0.0 (2026-09-29)

Adds the two fixes that landed after 2.0.0-rc3 (`CADViewportView` frozen bodies, face highlight
z-fighting). Everything else below was in the release candidates.

### Fixed: `CADViewportView` froze its bodies at first render

`CADViewportView` passed `.constant(bodies)` to the Metal viewport, whose renderer captures its
binding once, so bodies added or edited after the first render never reached the screen. Face,
edge and vertex selection highlights built after that point were the visible symptom. The view now
hands the renderer a reference-typed box refreshed on every `body` evaluation, so additions,
removals and in-place edits (`isVisible`, `transform`, `triangleStyles`) all reach it. Nothing is
diffed, and no per-evaluation key is built.

### Fixed: the face selection highlight never rendered

Closes [OCCTSwiftInteraction#22](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/22).

The face highlight body duplicates the selected face's own triangles, so on the default
`.geometry` layer it tied the real surface's depth and lost the renderer's strict `.less` test,
whatever its color or alpha. It now uses `renderLayer: .overlay` and `isPickable: false` (an
overlay body would otherwise win every pick over the model beneath it). Edge and vertex
highlights are unchanged. Trade-off: an overlay draws through occluding geometry, so a highlighted
face on the far side of a solid shows through it.

### New: the agent-viewport selection sidecar

Closes [OCCTSwiftInteraction#16](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/16).

`CADViewportService` gains `startSelectionSidecar(directory:hostName:hostVersion:)` /
`stopSelectionSidecar()`, the bridge described by the agent-viewport selection bridge ADR
(`okf/decisions/agent-viewport-selection-bridge.md`, OCCTSwiftInteraction#17): writes this
service's live selection out to `<directory>/selection.json` on every change, watches
`<directory>/highlight_requests/` (via `OCCTSwiftIO.DirectoryWatcher`) for a request an
MCP-side agent dropped, and applies each well-formed one via `select(_:scheme:)` or
`present(_:)` (when it carries a `question`), moving it to
`highlight_requests/handled/<id>.json` with an outcome. macOS-only: built on
`DirectoryWatcher`, itself Darwin-only (kqueue), so this API is absent on iOS.

An entity highlighted this way renders with the new `OCCTSwiftAIS.PresentationStyle
.agentHighlight` instead of the ordinary selection color, so a viewer can tell "the agent is
pointing at this" from "I selected this" at a glance.

The `DirectoryWatcher` dependency ships in `OCCTSwiftIO` 1.8.0 and is a normal version pin.

New: `CADViewportError.sidecarHostAlreadyRunning`.

### Platforms narrowed to iOS and macOS

A 1.0.0 blocker. `Package.swift` declared `.visionOS(.v1)` and `.tvOS(.v18)`, and both were false. `OCCT.xcframework`'s `Info.plist` carries exactly three slices, `ios-arm64`, `ios-arm64-simulator` and `macos-arm64`, supporting two platforms, and OCCTSwift's own v3.0.0 release notes open with "macOS / iOS (device + simulator)". Anything linking the kernel on visionOS or tvOS cannot link at all, so the manifest promised a build that never existed.

The merge took the union of what OCCTSwiftTools, OCCTSwiftAIS and OCCTSwiftCADKit declared, so as not to regress the two targets with the most dependents. That reasoning was wrong in a way invisible from the manifests: the wider claim was never true for any of the three, so there was nothing to regress. Root cause is filed upstream as [OCCTSwift#978](https://github.com/SecondMouseAU/OCCTSwift/issues/978).

`platforms` is now `.iOS(.v18)`, `.macOS(.v15)`. A consumer that declares a visionOS or tvOS target and depends on this package is now told so at resolution time rather than discovering it at link time.

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
