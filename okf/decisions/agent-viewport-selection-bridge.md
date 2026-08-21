---
type: decision
title: Agent-viewport selection bridge file formats
resource: https://github.com/SecondMouseAU/OCCTSwiftInteraction/blob/main/okf/decisions/agent-viewport-selection-bridge.md
tags: [decision, adr, selection, viewport, agent, mcp, bridge, json, sidecar, atomicity]
description: The wire format for a human's live viewport selection and an agent's highlight requests, exchanged as plain files in the shared scene directory.
timestamp: 2026-08-21
---

# Agent-viewport selection bridge file formats

## Status

Accepted. Documentation only: no reader or writer for any of the files below ships in this repo.
The Swift implementation is tracked separately, per repo, and each of those issues cross-references
this doc rather than restating its content:

- This repo's own sidecar work: [OCCTSwiftInteraction#16](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/16)
- The MCP-side client (`get_selection` / `highlight_selection`):
  [OCCTMCP#189](https://github.com/SecondMouseAU/OCCTMCP/issues/189) /
  [OCCTMCP#190](https://github.com/SecondMouseAU/OCCTMCP/issues/190)
- ACADStudio's connecting issue (not yet filed as of this writing)

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
`TopologyAnchor` directly from a `selection.json` entry rather than converting through a third
shape.

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

- **`selections`**: an array of `{bodyId: String, kind: "face"|"edge"|"vertex"|"body", index: Int,
  uid: String?}` entries, one per currently-selected sub-shape (or body). The `"body"` kind
  represents `SubShape.body` (whole-body selection) and has no corresponding `PickedEntity` case;
  for `"body"`, `index` is ignored (writers emit `0`). Empty array, not a missing key, when
  nothing is selected.
  uid: String?}` entries, one per currently-selected sub-shape (or body). Empty array, not a
  missing key, when nothing is selected.
- **`revision`**: `Int`, monotonic, incremented by exactly 1 on every write of this file, whether or
  not the selection set actually changed. A consumer polling for freshness compares `revision`
  values, never file mtimes.
- **`updatedAt`**: `String`, ISO 8601 UTC (`2026-08-21T10:15:32Z`), the timestamp of the write that
  produced this `revision`.

The host creates this file at startup (`revision: 0`, empty `selections`) alongside its `host.json` write, so a reader never has to treat "file absent" as "nothing selected":
`host.json` write, so a reader never has to treat "file absent" as "nothing selected": file absent
means the host has not started, or is stale (see `host.lock` below); file present with an empty
array means the host is live and nothing is selected.

### `highlight_requests/<id>.json`

A pending highlight (or escalation) request, one file per request, named by its own `id`:

```json
{
  "id": "hl-8f2c1d",
  "bodyId": "part1",
  "kind": "face",
  "index": 3,
  "scheme": "replace",
  "question": null
}
```

- **`id`**: `String`. Always equal to the filename stem (`highlight_requests/<id>.json`); a reader
  that finds a mismatch treats the file as foreign or corrupt and ignores it.
- **`bodyId` / `kind` / `index`**: identical fields and types to a `selection.json` entry, naming
  the single sub-shape (or body) this request targets. No `uid` field: a request is authored by the
  MCP-side client, which mints a request against its own graph, not the host's; the host resolves
  `bodyId`/`kind`/`index` against its own scene independently. See "Index is per-process advisory"
  below.
- **`scheme`**: `"replace" | "add" | "remove" | "xor"`, the same four-scheme vocabulary this
  package's own `InteractiveContext.select(_:scheme:)` already uses. How the requested entity
  combines with whatever the host currently has highlighted.
- **`question`**: `String?`. Present only when this request is escalation-shaped: the host renders
  it exactly as it would render one of its own `EscalationRequest.question` values, and the request
  maps onto a single-entity `EscalationRequest` (`entities: [the one targeted PickedEntity]`,
  `candidates: []`, `context: nil`) rather than this doc inventing a parallel escalation shape.
  `nil` (or the key omitted) for a plain "highlight this" request with no question attached.

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
  already say; `nil` for the ordinary `applied` case.

The handled file does not repeat `id`, `bodyId`, `kind`, or `index`: the filename is the join key
back to the request it answers, and the original request file stays in `highlight_requests/` (it
is not moved or deleted), so a client that wants the full picture reads both files by the same
`<id>`.

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
  does not recognize refuses to interpret the rest of the directory rather than guessing.

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

Nothing here is ever written by both sides. A request file and its handled file are the one
two-writer conversation this contract has, and it stays race-free because each side only ever
writes the path the other side only ever reads: the client creates `<id>.json` and never touches
`handled/<id>.json`; the host reads `<id>.json`, may delete it once handled (implementation detail,
not part of this contract) and writes `handled/<id>.json` exactly once.

## Design notes

**Index is per-process advisory; `uid` is the durable identity, when present.** This mirrors
`SubShapeRef`'s own documented split in this package: **the shape is the identity and the ordinal
is advisory, not the other way round.** `index` in every shape above is an ordinal in whichever
process wrote it (the host's tessellation-time ordinal for `selection.json`, the MCP-side client's
own graph-node index for a `highlight_requests/<id>.json` it authored), and the two are not
guaranteed to be the same index space. A consumer resolves by `uid` first whenever one is present,
and treats `index` as a best-effort fallback scoped to whichever side minted it, never as a value
safe to compare across the two processes directly.

**`uid`, when present, is a `BRepGraph.GraphUID` and inherits its persistence caveat.**
**`uid`, when present, is a `BRepGraph.GraphUID` (from OCCTSwift) and inherits its persistence caveat.
`BRepGraph.GraphUID` is `Codable` but instance-scoped: it does not survive a graph rebuild or a
process restart, so a `uid` written by one host process lifetime is not guaranteed to resolve
against a graph rebuilt in a later one. A reader that gets a `uid` miss falls back to
`bodyId`/`kind`/`index`, exactly the rung-2/rung-3 fallback `OCCTMCP`'s own `remap_selection`
already uses for the equivalent problem one layer up.
process restart, so a `uid` written by one host process lifetime is not guaranteed to resolve
against a graph rebuilt in a later one. A reader that gets a `uid` miss falls back to
`bodyId`/`kind`/`index`, exactly the rung-2/rung-3 fallback `OCCTMCP`'s own `remap_selection`
already uses for the equivalent problem one layer up.

## Not included

- The Swift implementation of any reader or writer: see the issues cross-referenced under
  "Status" above.
- A heartbeat/staleness threshold for a non-local (network- or sync-backed) scene directory. Out of
  scope until that case is real; `host.lock` plus `host.json`'s `pid` covers the single-machine case
  this bridge is built for.
- A versioning/migration strategy for the schema itself, beyond the `schemaVersion` field already
  specified above.

## References

- [OCCTSwiftInteraction#17](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/17), the
  issue this doc closes.
- [OCCTSwiftInteraction#16](https://github.com/SecondMouseAU/OCCTSwiftInteraction/issues/16), this
  repo's own `CADViewportService` sidecar issue.
- [OCCTMCP#189](https://github.com/SecondMouseAU/OCCTMCP/issues/189) /
  [OCCTMCP#190](https://github.com/SecondMouseAU/OCCTMCP/issues/190), the MCP-side
  `get_selection` / `highlight_selection` tools this contract backs.
- `Sources/OCCTSwiftTools/SubShape.swift`, `SubShapeRef` / `SubShape` / `InteractiveObject`: the
  identity primitives this doc's entry shapes are kept consistent with.
- `Sources/OCCTSwiftCADKit/EscalationRequest.swift`, the local escalation shape a
  question-carrying highlight request maps onto once the host renders it.
