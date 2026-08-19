---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTSwiftCADKit
tags: [index, api]
description: OCCTSwiftCADKit public API: one library target wrapping the CAD viewport service and view.
timestamp: 2026-06-22
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
  `selectionMeasurements` reports aggregate count/area/length/bounds. `selectedFace:
  PickedFaceInfo?`, `selected: PickedEntity?` and `selectionSummary` still work as deprecated
  conveniences.
  `load(_:id:transform:)` / `loadFile(from:id:progress:)` / `loadFromData(_:filename:id:progress:)`
  display several parts or assembly occurrences as distinct, addressable **entities**
  (`loadedShapes`, `shape(id:)`, `entityID(forBodyID:)`, `visibility`, `remove(id:)`, `removeAll()`,
  `focus(on:)`); the single-shape `loadFile(from:)`/`loadShape(_:id:)`/`loadFromData(_:filename:)`
  still work as a deprecated convenience, and are safe to mix with the new API: both register in
  the same internal entity registry. `setScalarField(_:forBody:)` paints a `ScalarField` (deviation,
  curvature, wall thickness, confidence, anything per-face or per-triangle) onto a body by
  rebuilding it (currently a full re-upload, not just the GPU style buffer, see the method's own
  doc comment for a confirmed upstream `OCCTSwiftViewport` caching limitation this works around);
  `scalarFieldLegend` reports the range/unit/color stops for the most-recently-set field. Caller
  geometry (stock boxes, toolpaths, flat-pattern outlines, annotations) is staged via
  `setOverlay(id:bodies:)` / `clearOverlay(id:)`.
- **`CADViewportView`**: SwiftUI wrapper around the Metal viewport with a selection-info banner and
  display-mode controls.
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
  ordinal to it, so identity is the resolver's, not a parallel copy of it.
  `PickedFaceInfo.scalarValue` is the picked face's value from the body's `ScalarField`, if any. The
  clip-plane pre-filter and the descriptive enrichment around each info type stay here on purpose:
  clip planes are this service's state, and enrichment is presentation, so neither belongs in the
  shared resolver.
- **`SelectionMeasurements`**: count by kind, total face area, total edge length, and combined
  bounds over `CADViewportService.selection`. Named `SelectionSummary` until
  OCCTSwiftInteraction#3, renamed to stop colliding with the unrelated public
  `OCCTSwiftUXKit.SelectionSummary` (a UI caption type sharing no field, input or consumer with
  it). The old name remains as a deprecated typealias.
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
  without reloading either entity.
- **`ClippingPlane`**: clipping/section planes via `clippingPlanes`/`addClippingPlane(origin:
  normal:showCapSurface:)`/`removeClippingPlane(id:)`/`sectionSweep(axis:position:)`. Hides
  geometry on one side (a fast, global GPU clip); `showCapSurface: true` (default) additionally
  shows the cut as solid material via a genuine B-Rep split and retessellation per affected body.
  Real geometry work, not a shader trick, since `OCCTSwiftViewport` has no shader-level capping.
  Multiple planes compose. Picking respects active planes even though the GPU pick pass itself
  doesn't.
- **`EscalationRequest`, `EscalationCandidate`, `EscalationResponse`**: human-in-the-loop
  escalation: `pendingEscalation` / `present(_:) async -> EscalationResponse` asks a bounded
  question grounded in specific geometry (`EscalationRequest.entities`, highlighted automatically
  when presented) and suspends until answered: `.chose(candidateID:)`, `.picked([PickedEntity])`
  (the human answered by picking instead), `.deferred`, or `.rejected(reason:)`. `respond(_:)` /
  `respondWithCurrentSelection()` resolve it. Removing (or reloading) referenced geometry, or a
  full `removeAll()`, auto-resolves a pending escalation `.rejected` rather than leaving it
  suspended forever.
- **`CADViewportError`**: `unsupportedFormat`, `emptyFile`, `loadFailed`.
