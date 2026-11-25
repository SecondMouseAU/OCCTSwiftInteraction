---
title: Changelog (CADKit)
nav_order: 6
---

# Changelog

Most recent first. Breaking changes and deprecations documented here.

Started at OCCTSwiftInteraction#3, the first change to this target that a consumer has to read
before upgrading. Earlier history is in the pre-merge `OCCTSwiftCADKit` repository.

## Unreleased

### Breaking: `SelectionChangeSource` has a new case, `bodyRecut(bodyID:)`

Part of [OCCTSwiftInteraction#77](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/77),
below. When a cap recut remaps the selection on a body, `selectionChanges` publishes the change with
this source, one change per body whose selection changed. Like `bodyRemoved(bodyID:)`, it says
that a pick stored from before the change no longer names anything on that body: the recut
renumbered its sub-shapes and minted its durable uids afresh.

**Migration.** A `switch` over `SelectionChangeSource` with no `default` needs the new case.
Handle it as you handle `bodyRemoved(bodyID:)` if you keep picks per body, as a selection history
does.

### Fixed: a cap recut left the selection naming the uncut body's sub-shapes

Closes [OCCTSwiftInteraction#77](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/77).
When a cap-enabled clipping plane cut a body, moved, or was removed, the body got a new mesh and
new identity tables, but the selection kept the ordinals and uids of the old ones. Outside a
comparison a selected face stayed lit over the part the cap removed; during one its highlight was
cut by the old ordinal from the new mesh, lighting whichever face now held it; and `selection`,
`PickedFaceInfo.uid` and `selection.json` reported the old graph's uid. The selection on a recut or
restored body is now remapped onto the new tables before the highlight is cut again, using OCCT's
own record of the split: a selected face, edge or vertex the cut leaves alone stays selected, one it
divides becomes its pieces, a piece becomes the whole sub-shape again when the cap is removed, and
the cap face, or an edge or vertex where the plane crossed the body, becomes what the plane makes
from the same sub-shape when it moves. **A selected sub-shape the cap removes entirely leaves the
selection**, as does the cap face once the cap is removed, and it does not come back if the cap
moves away again. A body a plane hides entirely is not recut, so its selection is untouched. A face
the agent highlighted keeps the agent's highlight through the remap. The cap itself is cut by the
same OCCT calls as before, now run so as to keep the splitter's history.

### Fixed: a vertex highlight stayed lit where a wipe draws nothing

Closes [OCCTSwiftInteraction#79](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/79).
A `.wipe` draws no vertex points on either side, but a vertex highlight was drawn at the vertex's
own position rather than copied from the body, so a selected vertex stayed lit through any wipe,
including on the half the wipe cut away. It is now copied from the points the body draws, as an
edge highlight is copied from its segments, so a vertex selected before or during a wipe is not lit
while the wipe lasts and is lit again when it ends, which is what an edge already did. All three
kinds of highlight now light only what the body draws. No API change.

### Fixed: a hidden entity's selection highlight was still drawn

Closes [OCCTSwiftInteraction#78](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/78).
Hiding an entity with `visibility[id] = false` hid its bodies but not their selection highlight,
which is drawn as separate bodies, so a selected face, edge or vertex stayed lit where the hidden
entity had been. The same happened to a body that a cap plane clipped away entirely. A highlight now
lights only what is drawn: a hidden body keeps its selection, and `selection` still lists it, but
none of it is lit until the body is shown again, by `visibility`, by an escalation preview naming
the body, or by the plane no longer clipping it, when it is lit again. Selecting a sub-shape of a
hidden body works the same way. No API change.

### Fixed: a highlight on a side-by-side candidate was drawn where the candidate was not

Closes [OCCTSwiftInteraction#73](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/73).
`.sideBySide` moves the candidate through its bodies' transform, but a selection highlight copies the
selected geometry out of the candidate's own vertex data, which the transform leaves alone, and the
highlight carried no transform of its own. A face, edge or vertex selected on the candidate was
therefore highlighted where the candidate would be without the offset, beside the reference rather
than on the candidate. Each highlight now copies its geometry in world space, placed by the
transform of the body it came from, and with the fix below it follows the offset as it appears,
moves (a cap that narrows either side changes the gap) and goes. No API change.

### Fixed: a selection highlight went stale when a comparison changed the bodies under it

Closes [OCCTSwiftInteraction#72](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/72).
The selection highlight is copied out of the model bodies as drawn, but it was rebuilt only when
the selection changed, while `setComparison(_:)` changes the bodies themselves. A face selected
before a `.wipe` stayed lit over the part the wipe cut away. A face selected during a wipe stayed lit
only on the part the wipe had left, after the wipe moved, was cleared, switched to another mode, or
ended because the other entity was removed. The highlight is now rebuilt from the bodies as drawn
whenever a comparison is applied or undone, which includes the undo and reapply that a
clipping-plane change or a scalar field write runs during a comparison. It is rebuilt once per
viewport update, not once per step. An edge highlight is rebuilt the same way, so an edge selected
before a wipe is not lit while the wipe lasts, since a wiped body draws no edges, and is lit again
when the wipe ends; before, it stayed lit across the whole edge. A vertex highlight does the same
since the fix for #79 above. No API change.

## 3.0.0-beta.8 (2026-11-25)

### Breaking: `Axis` is renamed `ComparisonAxis`

Closes [OCCTSwiftInteraction#60](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/60).
The axis a `.wipe` comparison splits along was a top-level `Axis`, and `OCCTSwiftAIS` declares a
top-level `Axis` too (its scene-object class, after OCCT's `AIS_Axis`). A file importing both
modules could not write a bare `Axis`: the compiler reported "'Axis' is ambiguous for type lookup
in this context" in a type position, and "ambiguous use of 'Axis'" in an expression such as
`Axis.self`, until it was module-qualified. CADKit's is now `ComparisonAxis`, so a bare `Axis`
means `OCCTSwiftAIS.Axis` wherever both are imported.

**Migration:** write `ComparisonAxis` wherever code names CADKit's type, including as
`OCCTSwiftCADKit.Axis`. A call site that never names it, such as `.wipe(axis: .x, position: 0)`,
compiles unchanged. Code left on the old name fails to compile rather than changing meaning: with
AIS imported, `Axis` is a class with no `x`, `y` or `z` and is not the type `.wipe` takes.

There is no deprecated `Axis` typealias. A top-level alias of that name keeps the name, and with it
the ambiguity the rename removes: tried, it fails the new `AxisNameCollisionTests` with the same
"ambiguous for type lookup" error. No consumer in the fleet names the type today.

### Docs: the bridge ADR now says a handled request file is deleted

Closes [OCCTSwiftInteraction#63](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/63).
The selection bridge ADR said in one place that a request file stays in `highlight_requests/`
after it is handled, "not moved or deleted", so a client could read it back beside its outcome,
and in another that the host may delete it as an implementation detail. The sidecar has always
deleted it once `handled/<id>.json` is written. Both passages now say that, as part of the
contract: the outcome is written first, the request file is deleted after, and a client keeps its
own copy of what it sent. Neither OCCTMCP nor ACADStudio reads a request back. No behaviour
change.

### Fixed: a blank question opened an escalation card with nothing to read

Closes [OCCTSwiftInteraction#62](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/62).
The sidecar treated a `highlight_requests` request as an escalation whenever its `question` was not
the empty string, so a question of only spaces, or only characters that draw nothing (a zero-width
space, U+3164 HANGUL FILLER, U+2800 BRAILLE PATTERN BLANK), opened an escalation card with a blank
question, and selected the entity whatever `target` said. A question is now no question when it is
absent, empty, or draws nothing by the rule a label is judged by (#54). A request carrying one opens
no escalation and lands exactly where a request without a question lands: in the attention marker
by default, with its `label` held, or in the selection under `target: "selection"`, where a whole
body is selected rather than rejected. On `applied`, a non-empty question dropped this way is
reported in the handled file's `reason` (`question dropped: it has no visible character`), joined
with `; ` ahead of any label reason; an empty one is dropped without a reason, as before. A
question with a visible character still escalates, shown exactly as sent. No API change. OCCTMCP's
`highlight_selection` still treats an empty or blank question as a question, so it skips its
attention-side checks for one, writes no `label` and lets `kind: "body"` through to the host;
filed as [OCCTMCP#293](https://github.com/SecondMouseAU/OCCTMCP/issues/293).
Contract: `okf/decisions/agent-viewport-selection-bridge.md`.

### Fixed: a pick on a body cut by a wipe comparison named the wrong face

Closes [OCCTSwiftInteraction#58](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/58).
Under a `.wipe` comparison each compared body draws only the triangles on its side of the plane, so
a GPU pick names a triangle of that subset, but the pick was looked up in the face table of the whole
body. Every pick on a triangle after the first one the wipe dropped resolved to another face, with
no error: a candidate wiped at X = 1 and picked on its first drawn triangle, on the +X face, resolved
to the -X face. `PickedFaceInfo.scalarValue` for a `.perTriangle` field was read at the same wrong
position, so it could disagree with the colour under the cursor, and selecting a face on a wiped
body highlighted triangles of other faces. The wipe now records which of the body's own triangles
each drawn triangle is, and the pick, its scalar value and the highlight all translate through
that, so a pick names the face under the cursor and reports the value painted there. No API change.
Edge and vertex picks were not affected, since a wiped body draws no edges or points, and nor was
the clip-plane check on a pick, which already tested the triangle as drawn.

### Fixed: ending a deviation comparison left the heatmap on a candidate loaded from a file

Closes [OCCTSwiftInteraction#59](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/59).
Ending a `.deviation` comparison (`setComparison(nil)`, switching to another mode, or removing the
reference) is meant to clear the candidate's scalar field, but it cleared the field stored under the
candidate's entity id, while `setScalarField(_:forBody:)` stores fields by body id. That only worked
for an entity whose one body shares its id, which is what `load(_:id:)` makes. A candidate loaded
with `loadFile(from:id:)` or `loadFromData(_:filename:id:)`, whose bodies are named `<id>-0`,
`<id>-1` and so on even for a single solid, kept its heatmap, and `scalarField(forBody:)` and
`scalarFieldLegend` went on reporting it. Ending the comparison now clears the field on each of the
candidate's bodies. No API change.

### Fixed: an attention label was held at any length, and a blank-drawing one was kept

Closes [OCCTSwiftInteraction#54](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/54).
`setAgentAttention(_:label:)` and a `highlight_requests` payload kept `label` exactly as written,
only an empty string becoming nil. OCCTMCP's `highlight_selection` bounds a label, but a client
writing the request file itself, or a host calling `setAgentAttention` directly, was not held to
that. `setAgentAttention` now applies the bound for both, and the sidecar passes the label straight
through to it. A label over 80 characters (counted as OCCTMCP counts them, `String.count`) keeps
its first 79, less any blank ones at the cut and a Prepend character the `…` would join, plus `…`,
never splitting a grapheme cluster. A label is also held to 4096 UTF-8 bytes, `…` included, since
one character can carry any number of combining marks and OCCTMCP's count takes it as one; no
label of ordinary characters within 80 comes near that bound. A cut that leaves nothing visible in
front of the `…` drops the label rather than holding an ellipsis alone, so a host falls back to
its own caption. A label made only of characters that draw nothing (whitespace,
control characters, default-ignorable code points such as a zero-width joiner or the Hangul
fillers, and a few named ones such as U+2800 BRAILLE PATTERN BLANK) is now no label, where before
anything but the empty string was kept and drew as a blank caption. The marker itself still lands
in both cases. The sidecar reports a cut or dropped label in the handled file's `reason` on
`applied`; an absent or empty label still carries no reason. No API change. A label within 80
characters with any visible character is held exactly as sent. Rule and reasoning:
[CADViewportService reference](reference/CADViewportService.md).

### Fixed: the display-mode controls covered the view cube in the default corner

Closes [OCCTSwiftInteraction#44](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/44).
`CADViewportView` drew its display-mode and standard-view controls in the bottom-trailing corner,
which is also where OCCTSwiftViewport draws the view cube by default
(`ViewportConfiguration.viewCubePosition` is `.bottomTrailing`), so the controls sat over about the
lowest 25 pt of the cube in the macOS layout and could take a tap meant for its bottom faces. The
controls now rest on the cube's top edge when the cube is in that corner and shown: 108 pt higher,
which is the cube's 96 pt side plus its 12 pt margin, with the same 8 pt gap above it. With the cube
in any other corner, or hidden (`controller.showViewCube == false`, followed live), they stay
exactly where they were, so a host that already moved the cube clear (ACADStudio's `.topTrailing`)
sees no change. No API change.

A viewport under about 150 pt tall keeps the controls on its bottom edge instead of lifting them out
of view. A host that laid out around the controls with the default cube corner should expect them
108 pt higher in the trailing column. The cube's size and margin are not public in
OCCTSwiftViewport, so the offset mirrors them (96 pt and 12 pt, unchanged since 1.1.15); a test reads
the resolved source and fails if either moves.

### Fixed: hiding a capped entity was silently undone by the next cap recompute

Closes [OCCTSwiftInteraction#46](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/46).
`visibility[id] = false` on an entity a cap plane had cut was reverted by the next
`updateCapSurfaces()` (a plane moved or added, `clippingPlanes = clippingPlanes`, an unrelated
entity loaded), because that pass restored `isVisible` from a snapshot taken when the body was first
capped. The converse failed too: showing an entity that was hidden when it was first capped was
undone when the plane was removed. `setVisible` (the `visibility` setter) and the escalation
preview show now write the caller's value into that snapshot as well, so a later restore returns the
body to the visibility the caller last set. No API change. A body hidden only because a plane clipped
it away entirely is unaffected: the snapshot keeps its visible state and it comes back when the
plane stops clipping it.

### Fixed: a visibility change made during a comparison was lost when it ended or was recomputed

Closes [OCCTSwiftInteraction#48](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/48),
the same defect class as #46 on the other snapshot. `setComparison(_:)` backs up the reference and
candidate bodies when an `.overlay`, `.sideBySide` or `.wipe` comparison starts and restores them
whole when it is cleared or its mode is switched, so a `visibility[id]` change made in between was
reverted: a hide came back visible, and a show of an entity that was hidden when the comparison began
came back hidden. The same restore runs around every `updateCapSurfaces()` pass, so the change was
also lost while the comparison was still active, whenever a clipping plane was added, moved or
removed, `clippingPlanes` was reassigned, or an unrelated entity was loaded. A body that was both
capped and compared had two snapshots, and in some orders lost the change through the comparison
one even though the cap one was right. `setVisible` (the `visibility` setter) and the escalation
preview show now write the caller's value into the comparison snapshot too, so a restore returns
the body to the visibility the caller last set. No API change; the clear still restores the
reference's opacity, the candidate's offset and the wiped triangles exactly as before.

### Fixed: a scalar field set during a comparison was lost when it ended, and misplaced under a wipe

Closes [OCCTSwiftInteraction#49](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/49),
the same defect class as #46 and #48 on a different field. `setScalarField(_:forBody:)` painted only
the live body, so a field set on the reference or candidate while an `.overlay`, `.sideBySide` or
`.wipe` comparison was active disappeared when the comparison was cleared or its mode switched, and
on any `updateCapSurfaces()` pass meanwhile (a clipping plane added, moved or removed,
`clippingPlanes` reassigned, an unrelated entity loaded), while `scalarField(forBody:)` and
`scalarFieldLegend` went on reporting it as set. Clearing a field during a comparison failed the
other way: the paint came back when the comparison ended. Under `.wipe`, a `.perTriangle` field set
during the comparison was indexed by position in the wiped subset of triangles, so it painted the
wrong ones: a wipe at X = 1 left a 4x4x4 box candidate the two triangles of its +X face and painted
them with `values[0]` and `values[1]`, which belong to the -X face. `setScalarField` now paints the
body as the comparison's snapshot holds it, whole and in its loaded triangle order, and applies the
comparison again over the result, so the field survives the clear, the switch and the recompute,
and a wiped body shows each kept triangle's own value. No API change. Under `.wipe`, setting a field
during the comparison now re-filters both entities' bodies, which costs the same as moving the wipe.

### Fixed: a `startSelectionSidecar` that throws no longer leaves a half-started sidecar

A start that failed partway (for example when `host.json` cannot be written) left `sidecarDirectory`
set and `host.lock` held, with nothing watching or writing, until the next `stopSelectionSidecar()`.
It now stops itself before throwing, so the lock is released and a later start in the same directory
is not refused.

### New: a pick on a drawing entity travels the selection bridge

Closes [OCCTSwiftInteraction#45](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/45).
Additive, and macOS-only like the rest of the sidecar. `selection.json` gains a `drawing-entity`
kind in the same `selections` array: `bodyId` names the drawing case (not a scene body), `index` is
`0` and ignored, `uid` is absent, and two new optional fields carry the pick, `entity` (SwiftDXF's
`Identity.id`: the handle, or section and position) and `entityType` (the DXF record type,
advisory). It sits under the same `revision` and `updatedAt` as the model picks, so one read tells an
agent "this dimension" and "this face" together.

A host publishes a drawing pick with the new `CADViewportService.setDrawingSelection(_:)`, which
takes the whole current set of `DrawingEntityPick` values (`drawing`, `entity`, `entityType`) and
replaces the previous one (an empty array clears it, and adding a pick means passing the current
ones too), just as every write of `selection.json` replaces the whole document. `drawingSelection`
reads it back. The model and drawing sets are independent: a change to either rewrites
`selection.json` carrying both, one revision bump per write, so a model pick does not drop a drawing
pick. Setting a set equal to the one held writes nothing, so an idle pane does not churn the
revision. A pick with an empty drawing or entity is dropped, and a repeated (drawing, entity) pair
is kept once. A held set is included in the startup write. A write that fails leaves the held set as
it was, so the call can be retried.

To clear a drawing pick when the model selection changes, do it from `selectionChanges`, where a
write already carries the new model selection, not from a raw `interactiveContext.$selection`
subscriber. `selectionChanges` does not emit for a whole-body change, so a host that selects whole
bodies clears the drawing pick from its own action there.

**No `schemaVersion` bump, and that is now the rule for any new kind.** The `host.json` rule has a
client refuse the whole directory on a version it does not know, which would cut an older reader off
from the model picks it can still read. A new kind or a new optional field is additive; a reader
skips an entry whose kind it does not know and keeps the rest. The ADR states it once.

A `highlight_requests` payload with `kind: "drawing-entity"` is rejected with a reason: agents
highlight a face, edge, vertex or body, not a drawing entity (that is for cross-highlighting to
decide). `selection.json` stays the host's alone, so the single-writer table gains no row.

**Order of rollout:** readers first (OCCTMCP#277: its `get_selection` looks an entry's body up
before its kind, so until then a drawing pick comes back as "body not found"), then this writer,
then the host's drawing pane.

## 3.0.0-beta.7 (2026-10-24)

**Pre-release, same pins as 3.0.0-beta.6** (OCCTSwift 4.0.0-beta.6 exactly, OCCTSwiftIO 2.0.0-beta.4). A consumer only gets this by naming it; the stable line stays at 2.0.0.

### New: `CADViewportService.meshDeflection`

Closes [OCCTSwiftInteraction#42](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/42).
Additive. `meshDeflection: Double?` (default `nil`, which keeps `CADFileLoader`'s own default) sets
the linear deflection `load(_:id:graph:transform:)` meshes with, so a test or preview of a heavy
assembly can mesh coarsely. It applies to shapes loaded after it is set. File loads
(`loadFile`, `loadFromData`) go through `CADFileLoader.load`, which takes no deflection, so they
and capping's rebuild path are unchanged.

### Docs: removed API no longer described as present

Closes [OCCTSwiftInteraction#40](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/40).
The reference page and getting-started guide documented `loadedShape`, `selected`, `selectedFace`,
`selectionSummary`, the single-shape `loadShape(_:id:)` / `loadFile(from:progress:)` /
`loadFromData(_:filename:progress:)` and the deprecated `CADViewportView.init(...selected:...)` /
`init(...selectedFace:...)` overloads as deprecated but working. 2.0.0 removed all of them. See the
correction under 2.0.0 below.

## 3.0.0-beta.6 (2026-10-17)

**Pre-release, pinned exactly to OCCTSwift 4.0.0-beta.6**, with OCCTSwiftIO 2.0.0-beta.4 (itself pinned to beta.6; beta.3 pins beta.5, beta.2 and earlier pin beta.4, and none resolve alongside this). A consumer only gets this by naming it; the stable line stays at 2.0.0.

No source change: `swift build --build-tests` is clean and the full serial suite passes (405 tests) unmodified. A grep of `Sources/` and `Tests/` finds no use of the OCCTSwift types beta.6 changed (`AssemblyNode.transform`, `GProps.matrixOfInertia`, `ShapeProperties.momentOfInertia`, `DrawingAnnotation.CuttingPlaneLine`) or of `offsetWire`, `OffsetAncestors` and `circularPattern`, so neither the `simd` removal nor the two silent value changes reach this package. The `camera.projectionMatrix` and `viewMatrix` calls are OCCTSwiftViewport's camera, not OCCTSwift's.

## 3.0.0-beta.5 (2026-10-10)

**Pre-release, pinned exactly to OCCTSwift 4.0.0-beta.5**, with OCCTSwiftIO 2.0.0-beta.3 (itself pinned to beta.5; beta.2 and earlier pin beta.4 and no longer resolve alongside this). A consumer only gets this by naming it; the stable line stays at 2.0.0.

No source change: `swift build --build-tests` is clean and the full serial suite passes (405 tests) unmodified. Nothing in OCCTSwift beta.5's three breaks reaches this package. Carries the `agentAttentionLabel` feature from beta.4.

## 3.0.0-beta.4 (2026-10-09)

**Pre-release, same pins as 3.0.0-beta.3.** A consumer only gets this by naming it; the stable line stays at 2.0.0.

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

### Removed (migration for #40)

Commit e00f7ba removed the deprecated surface. Migrate as follows; the `id`-taking loaders do not
auto-focus, so call `focus(on:)`.

| Removed | Use |
|---|---|
| `loadedShape` | `shape(id:)` / `loadedShapes` |
| `selected`, `selectedFace` | `selection` (`[PickedEntity]`) |
| `SelectionSummary` | `SelectionMeasurements` |
| `selectionSummary` | `selectionMeasurements` |
| `loadShape(_:id:)` | `load(_:id:transform:)` |
| `loadFile(from:progress:)` | `loadFile(from:id:progress:)` |
| `loadFromData(_:filename:progress:)` | `loadFromData(_:filename:id:progress:)` |
| `CADViewportView.init(bodies:controller:selected:...)`, `init(...selectedFace:...)` | `init(...selection:...)` |

Adds the two fixes that landed after 2.0.0-rc3 (`CADViewportView` frozen bodies, face highlight
z-fighting). Everything else here shipped earlier: the removal above and the platform narrowing in
2.0.0-rc1, the sidecar in 2.0.0-rc3, #7 in 0.2.0 and #3 in 0.1.0. This changelog's first release
heading is 2.0.0, so they are filed here rather than under those releases.

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

A blocker for the stable line, planned as 1.0.0 at the time and shipped as 2.0.0. `Package.swift` declared `.visionOS(.v1)` and `.tvOS(.v18)`, and both were false. `OCCT.xcframework`'s `Info.plist` carries exactly three slices, `ios-arm64`, `ios-arm64-simulator` and `macos-arm64`, supporting two platforms, and OCCTSwift's own v3.0.0 release notes open with "macOS / iOS (device + simulator)". Anything linking the kernel on visionOS or tvOS cannot link at all, so the manifest promised a build that never existed.

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
way OCCTSwiftViewport's `SelectionFilter` was in phase 1. *Correction (#64): 2.0.0 removed both
aliases (see "Removed" under 2.0.0).*

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

*Correction (#40): `selected`, `selectedFace` and the single-shape loaders were removed in 2.0.0
(see "Removed" under 2.0.0), and this section originally said they were unchanged.*

`selection`, `select(_:scheme:)`, `clearSelection()`, `PickedEntity`
and the whole loading, overlay, clipping, comparison, scalar-field and escalation surface are
unchanged. `PickedEntity` gains no case: whole-body selection is a `SubShape.body` in the
interactive context, not a fourth `PickedEntity`.

#### For the two known consumers

- **PadCAM** reads `viewportService.selectedFace` (three sites) and calls `clearSelection()` (one
  site), and reads only `bounds`, `zLevel` and `description` off it. *Correction (#40): the
  `selectedFace` sites do not keep working, because 2.0.0 removed it; migrate to `selection`.* Its one exposure is item 4: it displays a stock box via
  `interactiveContext.display(_:style:)` and installs a `ManipulatorWidget` on it, so picks
  against that stock body now resolve under `[.face]` rather than `[.body]`.
- **OCCTSwiftUX** does not depend on this target at all, in either direction. Its own
  `SelectionSummary` is untouched and stays where it is.

#### Tests

10 new in `SharedSelectionTests`, covering the shared mode set, both directions of the shared
selection, on-demand enrichment, ordering, the AIS-body pick case, ref forwarding, and cross-body
identity. Package total 330 to 343 in 28 to 30 suites, all passing, none deleted or weakened.
