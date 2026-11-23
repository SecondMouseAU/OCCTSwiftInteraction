---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTSwiftCADKit
tags: [index, api]
description: OCCTSwiftCADKit public API: one library target wrapping the CAD viewport service and view.
timestamp: 2026-11-23
---

# Components

`OCCTSwiftCADKit` ships a single public library/target, **`OCCTSwiftCADKit`**. Its API surface:

- **`CADViewportService`**: `@Observable @MainActor` service that owns the loaded geometry, drives the
  Metal viewport, and routes picking results via `selection: [PickedEntity]`, gated by
  `selectionModes: Set<SelectionMode>` (default `[.face]`; add `.edge`/`.vertex` to opt in).
  **It holds no selection state of its own since OCCTSwiftInteraction#3**: `selection` is
  `interactiveContext.selection` projected into `PickedEntity` values (ordered by body id, kind
  and ordinal, since the store is a `Set`), and `selectionModes` **is**
  `interactiveContext.selectionMode`. A real pick replaces the selection wholesale; build a
  multi-selection with `select(_:scheme:)` (`SelectionScheme`: `.replace`/`.add`/`.remove`/`.xor`,
  `OCCTSwiftAIS`'s own type, which gained the scheme parameter from this service).
  `selectionMeasurements` reports aggregate count/area/length/bounds. The deprecated
  `selectedFace`, `selected` and `selectionSummary` were removed in 2.0.0.
  `load(_:id:transform:)` / `loadFile(from:id:progress:)` / `loadFromData(_:filename:id:progress:)`
  display several parts or assembly occurrences as distinct, addressable **entities**
  (`loadedShapes`, `shape(id:)`, `entityID(forBodyID:)`, `visibility`, `remove(id:)`, `removeAll()`,
  `focus(on:)`); the deprecated single-shape `loadFile(from:)`/`loadShape(_:id:)`/
  `loadFromData(_:filename:)` were removed in 2.0.0.
  `setScalarField(_:forBody:)` paints a `ScalarField` (deviation,
  curvature, wall thickness, confidence, anything per-face or per-triangle) onto a body by
  rebuilding it (currently a full re-upload, not just the GPU style buffer, see the method's own
  doc comment for a confirmed upstream `OCCTSwiftViewport` caching limitation this works around);
  `scalarFieldLegend` reports the range/unit/color stops for the most-recently-set field. Caller
  geometry (stock boxes, toolpaths, flat-pattern outlines, annotations) is staged via
  `setOverlay(id:bodies:)` / `clearOverlay(id:)`.
- **`CADViewportView`**: SwiftUI wrapper around the Metal viewport with a selection-info banner and
  display-mode controls. The controls sit bottom-trailing and rest on the view cube's top edge when
  the cube shares that corner (its default), so they do not cover it (a viewport under about
  150 pt tall keeps them on the bottom edge instead).
- **`EscalationCardView`**: SwiftUI presentation for an `EscalationRequest` (question, candidates,
  context), reporting the answer via closures: same explicit-values-plus-callbacks style as
  `CADViewportView`. One adaptive layout capped to a comfortable phone-width column, usable as a
  floating panel on a larger surface too.
- **`PickedEntity`**: `.face(PickedFaceInfo)` / `.edge(PickedEdgeInfo)` / `.vertex(PickedVertexInfo)`,
  plus `bodyID` and `ref` accessors common to all three (pass `bodyID` to `entityID(forBodyID:)`).
  Deliberately no whole-body case: whole-body selection is a `SubShape.body` in the interactive
  context, where AIS's whole-body fallback and body-level highlight already live.
- **`PickedFaceInfo`, `PickedEdgeInfo`, `PickedVertexInfo`, `FaceBounds`**: metadata returned by
  picking (no CAM- or unfold-specific deps). Each info type's `.shape`/`.uid` are the durable identity
  of the pick, resolved by `OCCTSwiftTools.SubShapePickResolver` since OCCTSwiftInteraction#2 (which
  reads the body's `FaceIdentityTable`/`EdgeIdentityTable`/`VertexIdentityTable`);
  `.faceIndex`/`.edgeIndex`/`.vertexIndex` are ephemeral render-path ordinals only. Since
  OCCTSwiftInteraction#3 each stores a `SubShapeRef` as `ref` and forwards `.shape`/`.uid`/the
  ordinal to it, so identity is the resolver's, not a parallel copy of it. Since
  OCCTSwiftInteraction#7 the tables themselves are not built here either: a file load asks for
  `CADLoadResult.identity` (`includeIdentity: true`) and an in-memory shape goes through
  `OCCTSwiftTools.ShapeIdentity`, both installed by the internal `installIdentity(_:)`.
  `PickedFaceInfo.scalarValue` is the picked face's value from the body's `ScalarField`, if any. The
  clip-plane pre-filter and the descriptive enrichment around each info type stay here on purpose:
  clip planes are this service's state, and enrichment is presentation, so neither belongs in the
  shared resolver.
- **`SelectionMeasurements`**: count by kind, total face area, total edge length, and combined
  bounds over `CADViewportService.selection`. Named `SelectionSummary` until
  OCCTSwiftInteraction#3, renamed to stop colliding with the unrelated public
  `OCCTSwiftUXKit.SelectionSummary` (a UI caption type sharing no field, input or consumer with
  it). The deprecated `SelectionSummary` typealias was removed in 2.0.0.
- **`ScalarField`, `ColorMap`, `ScalarFieldLegend`, `LegendStop`**: a per-face/per-triangle scalar
  value plus how it maps to color (`.viridis`/`.magma`/`.turbo` sequential, `.diverging(center:)` for
  signed values, `.threshold(levels:)` for discrete bands, `.custom(stops:)`), and the legend a UI
  renders alongside it.
- **`ComparisonView`, `ComparisonMode`, `Axis`**: display two already-loaded entities (typically a
  source mesh and a reconstructed solid) against each other via `setComparison(_:)`:
  `.overlay(referenceOpacity:)` ghosts the reference, `.deviation` marks the candidate's
  already-set `ScalarField` as the comparison (CADKit doesn't compute deviation itself),
  `.sideBySide` offsets the candidate next to the reference (one shared camera), `.wipe(axis:
  position:)` spatially splits the two at a plane by filtering each side's triangles (not
  `OCCTSwiftViewport`'s `clipPlanes`, which is viewport-global). Settable/clearable repeatedly
  without reloading either entity. A visibility set on either entity while a comparison is active
  survives clearing or switching it (#48).
- **`ClippingPlane`**: clipping/section planes via `clippingPlanes`/`addClippingPlane(origin:
  normal:showCapSurface:)`/`removeClippingPlane(id:)`/`sectionSweep(axis:position:)`. Hides
  geometry on one side (a fast, global GPU clip); `showCapSurface: true` (default) additionally
  shows the cut as solid material via a genuine B-Rep split and retessellation per affected body.
  Real geometry work, not a shader trick, since `OCCTSwiftViewport` has no shader-level capping.
  Multiple planes compose. Picking respects active planes even though the GPU pick pass itself
  doesn't. A visibility set on a capped entity survives every cap recompute and is what removing
  the plane restores (#46).
- **`EscalationRequest`, `EscalationCandidate`, `EscalationResponse`**: human-in-the-loop
  escalation: `pendingEscalation` / `present(_:) async -> EscalationResponse` asks a bounded
  question grounded in specific geometry (`EscalationRequest.entities`, highlighted automatically
  when presented) and suspends until answered: `.chose(candidateID:)`, `.picked([PickedEntity])`
  (the human answered by picking instead), `.deferred`, or `.rejected(reason:)`. `respond(_:)` /
  `respondWithCurrentSelection()` resolve it. Removing (or reloading) referenced geometry, or a
  full `removeAll()`, auto-resolves a pending escalation `.rejected` rather than leaving it
  suspended forever.
- **`CADViewportError`**: `unsupportedFormat`, `emptyFile`, `loadFailed`, `sidecarHostAlreadyRunning`.
- **`startSelectionSidecar(directory:hostName:hostVersion:)` / `stopSelectionSidecar()`**
  (OCCTSwiftInteraction#16, `CADViewportService+AgentBridge.swift`): the agent-viewport
  selection bridge. Writes `selection.json` on every `interactiveContext.$selection` change,
  watches `<directory>/highlight_requests/` (`OCCTSwiftIO.DirectoryWatcher`, macOS-only) for
  a request an MCP-side agent dropped, and applies each well-formed one via
  `select(_:scheme:)` or `present(_:)` (when it carries a `question`), moving it to
  `highlight_requests/handled/<id>.json` with an outcome. Full wire format:
  `okf/decisions/agent-viewport-selection-bridge.md`. Highlights applied this way render
  with `OCCTSwiftAIS.PresentationStyle.agentHighlight`'s distinct hollow treatment instead of
  the ordinary selection color.
- **`setDrawingSelection(_:)` / `drawingSelection` / `DrawingEntityPick`**
  (OCCTSwiftInteraction#45, `CADViewportService+DrawingSelection.swift`): how a host publishes a
  pick on a 2D drawing entity through the same `selection.json`, as a `drawing-entity` entry
  (`bodyId` names the drawing case, `entity` is SwiftDXF's `Identity.id`, `entityType` is advisory)
  under the same revision as the model picks. The drawing and model sets are independent and each
  write carries both. `schemaVersion` is not bumped: a new kind is additive, a reader skips a kind
  it does not know. An agent cannot highlight a drawing entity; such a request is rejected.
