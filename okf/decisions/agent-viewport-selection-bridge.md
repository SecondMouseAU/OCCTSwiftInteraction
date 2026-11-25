---
type: decision
title: Agent-viewport selection bridge file formats
resource: https://github.com/SecondMouseAU/OCCTSwiftInteraction/blob/main/okf/decisions/agent-viewport-selection-bridge.md
tags: [decision, adr, selection, viewport, agent, mcp, bridge, json, sidecar, atomicity, drawing, schema-versioning]
description: The wire format for a human's live viewport selection (a model sub-shape or a drawing entity) and an agent's highlight requests, exchanged as plain files in the shared scene directory.
timestamp: 2026-11-25
---

# Agent-viewport selection bridge file formats

## Status

Accepted. This repo's `CADViewportService` sidecar is the reference host-side implementation (the
writer of `selection.json`, `host.json` and `handled/<id>.json`, and the reader of
`highlight_requests/`); the MCP-side client lives in OCCTMCP. Each implementation is tracked
separately, per repo, and each of those issues cross-references this doc rather than restating its
content:

- This repo's own sidecar work: [OCCTSwiftInteraction#16](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/16)
- The MCP-side client (`get_selection` / `highlight_selection`):
  [OCCTMCP#189](https://github.com/SecondMouseAU/OCCTMCP/issues/189) /
  [OCCTMCP#190](https://github.com/SecondMouseAU/OCCTMCP/issues/190)
- ACADStudio, the host built on it: D-124 and ACADStudio#154 for drawing picks
- Drawing-entity picks (the `drawing-entity` kind, and the rule for adding a kind without a
  `schemaVersion` bump):
  [OCCTSwiftInteraction#45](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/45),
  asked for by ACADStudio's D-124 (ACADStudio#154). The reader side is
  [OCCTMCP#277](https://github.com/SecondMouseAU/OCCTMCP/issues/277).

## Context

An agent driving `OCCTMCP` and a human driving a live viewport (`CADViewportService`, or a host
built on it such as ACADStudio) need to agree on one wire format for two things that cross the
process boundary: the human's current selection, and a highlight the agent wants drawn (including
an escalation question). The two processes only share a directory of plain files: the same scene
directory `manifest.json` already lives in, watched today by `OCCTSwiftViewport`'s
`ScriptWatcher`.

This package is where the decision belongs, not a docs-only repo, because it already owns the
durable identity and picking primitives the bridge is built from (`SubShapeRef`, `SubShape`,
`InteractiveObject`, `SubShapePickResolver`) and every consumer of this bridge already depends on
it (`OCCTMCP`, `ACADStudio`, and, via `OCCTSwiftUX`, anything built on top of it). An earlier pass
filed this as `ecosystem#53`, a docs-only repo with no stake in the primitives; that was a mistake
against this doc's own placement and `ecosystem#53` is closed as a duplicate of
[OCCTSwiftInteraction#17](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/17), the
issue this doc closes.

`ACADStudio`'s `SceneDirectoryManager` is the precedent for the atomic-write and single-writer
discipline formalized below. `OCCTMCP`'s `SelectionRegistry` / `TopologyAnchor` already define an
analogous `{bodyId, kind, index, uid}` shape for agent-side selections; the entry shape decided
here is kept consistent with it on purpose, so a `get_selection` implementation can mint a
`TopologyAnchor` directly from a model entry of `selection.json` rather than converting through a
third shape. (A `drawing-entity` entry names a drawing entity, not a topology node, and mints no
anchor.)

## Decision

### Shared scene directory layout

All of the files below live in the same scene directory as `manifest.json`:

```
<scene-directory>/
  manifest.json                    # existing: execute_script / occtkit output
  selection.json                   # host-owned: the human's current live selection
  host.json                        # host-owned: liveness descriptor, written once at startup
  host.lock                        # host-owned: exclusive flock for the host's lifetime
  highlight_requests/
    <id>.json                      # client-owned: a pending highlight/escalation request
    handled/
      <id>.json                   # host-owned: the outcome of a processed request
```

### `selection.json`

The host's current live selection, one object per file:

```json
{
  "revision": 42,
  "updatedAt": "2026-08-21T10:15:32Z",
  "selections": [
    { "bodyId": "part1", "kind": "face", "index": 3, "uid": "b7e2f6a1-..." }
  ]
}
```

- **`selections`**: an array of `{bodyId: String, kind: String, index: Int, uid: String?}` entries,
  one per currently-selected sub-shape, body or drawing entity, where `kind` is one of
  `"face"|"edge"|"vertex"|"body"|"drawing-entity"`. The `drawing-entity` kind adds the `entity`
  and `entityType` keys (see "The `drawing-entity` kind" below), absent from every other kind. The
  `"body"` kind represents `SubShape.body` (whole-body selection) and has no corresponding
  `PickedEntity` case; for `"body"`, `index` is ignored (writers emit `0`). Empty array, not a
  missing key, when nothing is selected. The array is the whole current selection, model picks and
  drawing picks together: every write replaces the whole set, never a patch to the previous one.
- **`revision`**: `Int`, monotonic, incremented by exactly 1 on every write of this file, whether or
  not the selection set actually changed. A consumer polling for freshness compares `revision`
  values, never file mtimes.
- **`updatedAt`**: `String`, ISO 8601 UTC (`2026-08-21T10:15:32Z`), the timestamp of the write that
  produced this `revision`.

The host creates this file at startup (`revision: 0`) alongside its `host.json` write, so a reader
never has to treat "file absent" as "nothing selected": file absent means the host has not started,
or is stale (see `host.lock` below); file present with an empty array means the host is live and
nothing is selected. The startup write carries whatever the host already holds, so `selections` is
empty unless a pick, model or drawing, was held before the sidecar started.

#### The `drawing-entity` kind

A pick on a 2D drawing entity (a line, a dimension, a text) travels in the same `selections` array
as a model pick, under the same `revision` and `updatedAt`, so one read of the file tells an agent
"this dimension" and "this face" together
([OCCTSwiftInteraction#45](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/45),
ACADStudio D-124):

```json
{
  "revision": 43,
  "updatedAt": "2026-11-18T10:15:40Z",
  "selections": [
    { "bodyId": "part1", "kind": "face", "index": 3, "uid": "b7e2f6a1-..." },
    { "bodyId": "6575N383", "kind": "drawing-entity", "index": 0,
      "entity": "2C1", "entityType": "DIMENSION" }
  ]
}
```

- **`kind`**: `"drawing-entity"`.
- **`bodyId`**: names the drawing case (the folder the host holds the drawing in, `6575N383`), not
  a scene body. A case and a scene body can share a name, so a reader keys on `kind` before it
  looks `bodyId` up anywhere. A reader that resolves `bodyId` against the scene first reports a
  drawing pick as "body not found" and drops its `entity`.
- **`index`**: `0`, and ignored, as for `"body"`.
- **`uid`**: absent. A `GraphUID` names `BRepGraph` nodes and a drawing has none.
- **`entity`**: `String`, required for this kind. SwiftDXF's `Identity.id` as one string
  (OCCTSwiftIO#57): the handle (group 5) where the file has one (`2C1`), else the section and
  position (`ENTITIES:12`), after the block references an expanded entity came through,
  outermost first (`8E/31`). Opaque to this contract: a reader compares it as a string and a
  writer never parses it. A `drawing-entity` entry without it names nothing, and a reader treats
  it as unusable, like an unknown kind.
- **`entityType`**: `String?`, optional and advisory. The DXF record type (`DIMENSION`, `LINE`).
  Nothing may depend on it; it is there so an agent can describe the pick without re-reading the
  drawing.

`entity` and `entityType` appear on a `drawing-entity` entry only. A model entry never carries
them, so a `selection.json` that holds no drawing pick is byte-for-byte what it was before this
kind existed.

The two kinds of pick are independent sets inside the one document. A write that follows a change
to either set carries both, so a model pick does not drop a drawing pick and a drawing pick does
not drop a model pick. Clearing one kind is the host's decision (a host that wants a click in the
viewport to clear the drawing pick clears it itself), and an empty set of one kind leaves the other
as it was. Entry order carries no meaning; the writer in this repo emits the model entries first,
as before, then the drawing entries ordered by `bodyId` then `entity`.

Because a drawing pick is part of the document, a change to it advances `revision` exactly as a
change to a model pick does, and an `ifRevision` composed before it is `superseded` after it. The
rule that every write bumps `revision`, changed or not, is unchanged. The writer in this repo
chooses not to write at all when the host re-asserts the drawing picks it already holds. A reader
that republishes a document only when it differs from the one it last applied (an echo guard, as
ACADStudio's `SelectionStore` does) would otherwise see `revision` and `updatedAt` change on every
re-assertion and treat it as a new selection.

### Adding a kind or a field: no `schemaVersion` bump

This is the rule for every future addition of the same shape as the `drawing-entity` kind, stated
once:

**A new `kind` string, or a new optional field on an existing entry, is additive and does not bump
`schemaVersion`.** A reader that meets a `kind` it does not know skips that entry, which it may
report as unusable in its own per-entry way (OCCTMCP's `get_selection` returns an error row), and
it keeps every other entry in the document. It never refuses the document, and it never drops its
other entries because of one it cannot use. A reader ignores a field it does not know.

`schemaVersion` is for a change that cannot be read as additive: removing or renaming a field,
changing a field's type or meaning, or changing the revision, atomicity or single-writer rules.

The reason is the `host.json` rule below: a client that reads a `schemaVersion` it does not know
refuses to interpret the rest of the directory. A bump for the `drawing-entity` kind would
therefore have cut every older reader off from the model picks it can read perfectly well, to
protect it from one entry kind it would skip anyway.

A reader's ordering is the catch. A reader that loads an entry's body before it looks at the
entry's kind turns a new kind into a "body not found" for that entry, which is why a writer of a
new kind waits for the readers (for this kind: OCCTMCP#277, then the writer, then the host's pane).

### `highlight_requests/<id>.json`

A pending highlight (or escalation) request, one file per request, named by its own `id`:

```json
{
  "id": "hl-8f2c1d",
  "bodyId": "part1",
  "kind": "face",
  "index": 3,
  "scheme": "replace",
  "question": null,
  "target": "attention",
  "ifRevision": 7
}
```

- **`id`**: `String`. Always equal to the filename stem (`highlight_requests/<id>.json`); a reader
  that finds a mismatch treats the file as foreign or corrupt and ignores it.
- **`bodyId` / `kind` / `index`**: identical fields and types to a `selection.json` entry for a
  model pick, naming the single sub-shape (or body) this request targets. `kind` is `"face"`,
  `"edge"`, `"vertex"` or `"body"` here; `"drawing-entity"` is not a highlight target (see
  "Not included"), and a request carrying it is `rejected` (after the `ifRevision`, `target` and
  `scheme` checks every request gets). No `uid` field: a request is authored
  by the MCP-side client, which mints a request against its own graph, not the host's; the host
  resolves `bodyId`/`kind`/`index` against its own scene independently. See "Index is per-process
  advisory" below.
- **`scheme`**: `"replace" | "add" | "remove" | "xor"`, the same four-scheme vocabulary this
  package's own `InteractiveContext.select(_:scheme:)` already uses. How the requested entity
  combines with whatever the host currently has highlighted.
- **`target`**: `"attention" | "selection"`, optional, default `"attention"`
  ([OCCTSwiftInteraction#29](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/29)).
  Where the request lands. `"attention"` is the host's agent-owned marker, one entity at a time,
  and leaves the human's selection and `selection.json` untouched: an agent pointing at face 3
  must not unselect the human's face 7. `scheme` then applies to the attention slot only
  (`replace`/`add` set it, `remove` clears it if it matches, `xor` toggles it). `"selection"` is the
  explicit ask to change the human's selection, and the only case where `scheme` combines with it.
  Absent means `"attention"`, a deliberate change of default: the old behaviour silently destroyed
  the human's pick and nothing recorded or restored it. Attention marks a face, edge or vertex; a
  `kind` of `"body"` with attention is `rejected`, since there is no whole-body marker. A request
  carrying a `question` (one with a visible character; see `question`) is the "show me the one I
  mean and let me confirm" flow and always lands in the selection, whatever `target` says. An
  unknown `target` is `rejected`.
- **`label`**: `String?`, optional
  ([OCCTSwiftInteraction#35](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/35)).
  Free-text caption for the attention marker ("this fillet"), at most 80 characters (Swift
  `Character`s, as OCCTMCP counts them) and at most 4096 UTF-8 bytes, the second a host-side bound
  OCCTMCP does not apply. The host cuts a longer one to the whole characters that fit both bounds
  with `…` after them, less any blank ones at the cut and a Prepend character the `…` would join
  (U+0600 before a tab), plus `…`, rather than rejecting the request. It treats a label that draws
  nothing (only whitespace, control or default-ignorable characters, or a few named blanks such as
  U+2800) as no label, and likewise one whose cut leaves nothing visible in front of the `…`
  ([OCCTSwiftInteraction#54](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/54)).
  A cut or dropped label is reported in the handled file's `reason` on `applied`; an empty one is
  ignored without a `reason`. Lands in `agentAttentionLabel` together with `agentAttention`, and
  is cleared whenever the marker is cleared or replaced. Ignored on a request that does not land in
  attention (`target: "selection"`, or one carrying a `question` with a visible character).
- **`question`**: `String?`. Present only when this request is escalation-shaped: the host renders
  it exactly as it would render one of its own `EscalationRequest.question` values, and the request
  maps onto a single-entity `EscalationRequest` (`entities: [the one targeted PickedEntity]`,
  `candidates: []`, `context: nil`) rather than this doc inventing a parallel escalation shape.
  `nil` (or the key omitted) for a plain "highlight this" request with no question attached.
  The host reads three spellings as no question: `nil` or the key omitted, the empty string, and a
  string that draws nothing by the rule `label` uses (only whitespace, control or default-ignorable
  characters, or the named blanks such as U+2800)
  ([OCCTSwiftInteraction#62](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/62)).
  A request carrying no question opens no escalation, lands where `target` puts it, and gets the
  `kind: "body"` check and the `label` handling that a request without the key gets. A dropped
  non-empty question is reported in the handled file's `reason` on `applied`
  (`question dropped: it has no visible character`); an empty one is dropped without a `reason`,
  as an empty `label` is. A question with a visible character is shown exactly as sent, untrimmed.
  A writer omits the key to send no question. OCCTMCP's `highlight_selection` still counts any
  non-nil `question` as a question, so it skips its attention-side checks for an empty or blank one
  ([OCCTMCP#293](https://github.com/SecondMouseAU/OCCTMCP/issues/293)).
- **`ifRevision`**: `Int?`. The `selection.json` revision this request was composed against, when
  the requester wants the apply to be conditional on it. Compare-and-swap.

  The race it closes is one the rest of the protocol cannot see. An agent reads `selection.json`,
  decides what to highlight from what it read, and by the time its request lands the human has
  selected something else. The request still applies, against a premise that is no longer true,
  and reports `applied`. Nothing anywhere records that the premise moved.

  When present, the host writes `{"outcome": "superseded"}` with a reason naming both revisions,
  and applies nothing, if its current revision is **strictly greater** than `ifRevision`. Strictly
  greater rather than unequal, deliberately: a request naming the *current* revision is exactly the
  one still valid, and a request naming a revision *ahead* of the host is not stale but impossible,
  since the only way to author one is to have read a `selection.json` this host did not write. That
  case falls through and applies rather than being reported as staleness it is not.

  Absent (or the key omitted) means unconditional, which is the right default: a request that
  genuinely does not care what the human did in the meantime, clearing a highlight say, should not
  have to pretend it does. The check runs before the target is resolved, so a stale request never
  reports a geometry rejection that would send the requester looking in the wrong place.

For `kind == "body"`, `index` carries no meaning (this package's own `SubShape.body` carries no
`SubShapeRef` at all, for the same reason): writers emit `0`, readers ignore it.

### `highlight_requests/handled/<id>.json`

Written once the host has processed a request, same `<id>` as the request it answers:

```json
{ "outcome": "applied", "reason": null }
```

- **`outcome`**: `"applied" | "rejected" | "superseded"`.
  - `applied`: the host changed its viewport highlight to match the request.
  - `rejected`: the host chose not to apply it (a bad `bodyId`, an out-of-range `index`, a user
    dismissing an escalation question); `reason` should say why.
  - `superseded`: a newer request arrived before the host got to this one, so the host applied the
    newer one instead and never actually processed this request's own content.
- **`reason`**: `String?`. Free text, present when it adds something `outcome` alone doesn't
  already say; `nil` for the ordinary `applied` case. An `applied` attention request whose `label`
  the host did not hold as sent carries one (`label cut from N to M characters`,
  `label cut from N to M bytes`, `label dropped: it has no visible character`, or
  `label dropped: no visible character fits within 80 characters and 4096 bytes`), so a client
  learns what happened to its label. An `applied` request whose `question` the host dropped as
  blank carries `question dropped: it has no visible character`, so a client that meant to
  escalate learns why no card appeared. When both apply, they are joined with `; `, the question's
  first.

- **`target`**: `String?`. On `applied`, where the request landed (`"attention"` or
  `"selection"`), so a client that omitted `target` can tell which default it got. Absent on
  `rejected` and `superseded`.

The handled file does not repeat `id`, `bodyId`, `kind`, or `index`: the filename is the join key
back to the request it answers. The host deletes the request file once the handled file is
written, never before, so a client that wants the full picture keeps its own copy of what it sent
and does not read `highlight_requests/<id>.json` back
([OCCTSwiftInteraction#63](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/63)). A
file the host cannot use (one that does not decode, or whose `id` is not its filename stem) gets no
handled file and is left in place.

### `host.json`

Written once, at host startup, never rewritten while the host is live:

```json
{
  "pid": 4821,
  "startedAt": "2026-08-21T09:58:01Z",
  "hostName": "ACADStudio",
  "hostVersion": "1.4.2",
  "schemaVersion": 1
}
```

- **`pid`**: `Int`, the host process id, cross-checked against `host.lock`'s holder.
- **`startedAt`**: `String`, ISO 8601 UTC, this host process's own start time.
- **`hostName`**: `String`, the host application's name (`"ACADStudio"`, `"OCCTStudio"`, ...).
- **`hostVersion`**: `String`, the host application's own version string.
- **`schemaVersion`**: `Int`, the version of *this* file-format contract the host was built
  against. Starts at `1` for the contract this doc defines. A client reading a `schemaVersion` it
  does not recognize refuses to interpret the rest of the directory rather than guessing. Because
  the refusal covers the whole directory, only a change that cannot be read as additive bumps it;
  see "Adding a kind or a field: no `schemaVersion` bump" above.

### `host.lock`

An empty file. The host opens (creating if absent) and holds an exclusive `flock(2)` on it for its
entire process lifetime; the lock is released by the kernel the instant the host process exits or
crashes, with no explicit unlock needed. A client checks liveness by attempting a non-blocking
shared lock: if that lock is obtainable, no host currently holds `host.lock`, and `host.json`'s
`pid`/`startedAt` (and by extension `selection.json`) are stale. `host.lock` carries no content and
is never rewritten; the atomicity rule below does not apply to it, only to the JSON files.

### The atomicity rule

Stated once here, and it governs every JSON file above: **every write is a temp-name-then-`rename(2)`,
never an in-place write.** Concretely: write the new content to a temp file in the same directory
(so the rename stays on one filesystem), then rename it over the target path. Foundation's
`Data.write(to:options:.atomic)` already does exactly this. A reader never observes a
partially-written file, because it either sees the old inode (mid-rename) or the new one, never a
truncated in-progress write.

This applies to `selection.json`, `host.json`, every `highlight_requests/<id>.json`, and every
`highlight_requests/handled/<id>.json`. It does not apply to `host.lock`, whose atomicity comes from
`flock(2)` itself, not from a rename.

### The single-writer rule

Exactly one side writes each path:

| Path | Sole writer |
|---|---|
| `selection.json` | the host |
| `host.json` | the host |
| `host.lock` | the host (holds the lock; does not rewrite content) |
| `highlight_requests/<id>.json` (excluding `handled/`) | the MCP-side client |
| `highlight_requests/handled/<id>.json` | the host |

A host's own panes are the host here. A drawing pane that has a pick to publish hands it to the
host's sidecar, which writes `selection.json`; the pane never writes the file, so the
`drawing-entity` kind adds no row to this table.

Nothing here is ever written by both sides. A request file and its handled file are the one
two-writer conversation this contract has, and it stays race-free because each side only ever
writes the path the other side only ever reads: the client creates `<id>.json`, never writes it
again, and never touches `handled/<id>.json`; the host reads `<id>.json`, writes
`handled/<id>.json` exactly once, and then deletes `<id>.json`. That deletion is the host's only
touch of a path the client writes, and it races nothing: it writes no content a reader could see
half-done, and it comes after the client's one write (see the handled file above).

## Design notes

**Index is per-process advisory; `uid` is the durable identity, when present.** This mirrors
`SubShapeRef`'s own documented split in this package: **the shape is the identity and the ordinal
is advisory, not the other way round.** `index` in every shape above is an ordinal in whichever
process wrote it (the host's tessellation-time ordinal for `selection.json`, the MCP-side client's
own graph-node index for a `highlight_requests/<id>.json` it authored), and the two are not
guaranteed to be the same index space. A consumer resolves by `uid` first whenever one is present,
and treats `index` as a best-effort fallback scoped to whichever side minted it, never as a value
safe to compare across the two processes directly. A `drawing-entity` entry is outside this: its
identity is `entity`, a string both sides read from the same drawing file, `index` is `0` and
ignored, and there is no `uid`.

**`uid`, when present, is a `BRepGraph.GraphUID` (from OCCTSwift) and inherits its persistence
caveat.** `BRepGraph.GraphUID` is `Codable` but instance-scoped: it does not survive a graph
rebuild or a process restart, so a `uid` written by one host process lifetime is not guaranteed to
resolve against a graph rebuilt in a later one. A reader that gets a `uid` miss falls back to
`bodyId`/`kind`/`index`, exactly the rung-2/rung-3 fallback `OCCTMCP`'s own `remap_selection`
already uses for the equivalent problem one layer up.

## Not included

- The Swift implementation of any reader or writer: see the issues cross-referenced under
  "Status" above.
- A heartbeat/staleness threshold for a non-local (network- or sync-backed) scene directory. Out of
  scope until that case is real; `host.lock` plus `host.json`'s `pid` covers the single-machine case
  this bridge is built for.
- A versioning/migration strategy for the schema itself, beyond the `schemaVersion` field and the
  additive-change rule specified above.
- An agent highlighting a drawing entity for the person. `highlight_requests` keeps its model kinds
  (`face`, `edge`, `vertex` and `body`), and a request with `kind: "drawing-entity"` is `rejected`
  with a reason. Cross-highlighting between a drawing and the model has its own
  open questions and is decided elsewhere, not here. The nearest related work is OCCTDesignLoop#91
  (a ledger row naming the model geometry it measured) and OCCTDesignLoop#92 (a ledger row keying
  its entity by the DXF handle).
- The agent writing a drawing pick. As for every other entry, `selection.json` is the host's alone.

## References

- [OCCTSwiftInteraction#17](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/17), the
  issue this doc closes.
- [OCCTSwiftInteraction#16](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/16), this
  repo's own `CADViewportService` sidecar issue.
- [OCCTMCP#189](https://github.com/SecondMouseAU/OCCTMCP/issues/189) /
  [OCCTMCP#190](https://github.com/SecondMouseAU/OCCTMCP/issues/190), the MCP-side
  `get_selection` / `highlight_selection` tools this contract backs.
- [OCCTSwiftInteraction#45](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/45), the
  `drawing-entity` kind and the additive-change rule; ACADStudio's D-124 asked for it, and
  [OCCTMCP#277](https://github.com/SecondMouseAU/OCCTMCP/issues/277) is the reader that has to
  tolerate it first.
- `Sources/OCCTSwiftTools/SubShape.swift`, `SubShapeRef` / `SubShape` / `InteractiveObject`: the
  identity primitives this doc's entry shapes are kept consistent with.
- `Sources/OCCTSwiftCADKit/EscalationRequest.swift`, the local escalation shape a
  question-carrying highlight request maps onto once the host renders it.
