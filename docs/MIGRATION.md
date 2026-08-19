# Migrating from OCCTSwiftTools, OCCTSwiftAIS and OCCTSwiftCADKit

This package replaces three repositories. The migration is a manifest change and nothing else.

## Your `import` lines do not change

The module names are deliberately unchanged. `import OCCTSwiftTools`, `import OCCTSwiftAIS` and
`import OCCTSwiftCADKit` all still work, because each is still its own SwiftPM target. Only the
package that vends them moved.

## What to change

Replace up to three dependency entries with one:

```swift
// before
occtDep("OCCTSwiftTools", from: "1.6.4"),
occtDep("OCCTSwiftAIS",   from: "1.3.2"),
occtDep("OCCTSwiftCADKit", from: "1.1.2"),

// after
occtDep("OCCTSwiftInteraction", from: "0.1.0"),
```

Then update the `package:` label on each product you use. The product names are unchanged; only the
package they come from moved:

```swift
// before
.product(name: "OCCTSwiftTools", package: "OCCTSwiftTools"),
.product(name: "OCCTSwiftAIS",   package: "OCCTSwiftAIS"),

// after
.product(name: "OCCTSwiftTools", package: "OCCTSwiftInteraction"),
.product(name: "OCCTSwiftAIS",   package: "OCCTSwiftInteraction"),
```

If you use the shared `occtDep` sibling helper, a local checkout at `../OCCTSwiftInteraction` is
found the same way the old ones were.

## You still only compile what you name

Depending on this package does not pull SwiftUI into a headless build. SwiftPM compiles only the
targets reachable from the products you actually name, so a CLI or server taking
`.product(name: "OCCTSwiftTools", package: "OCCTSwiftInteraction")` builds the `OCCTSwiftTools`
target alone. That target imports no UI framework at all, the same as before the merge.

This is the property that made the merge safe, and it is worth not breaking: if you add a UI
dependency to the `OCCTSwiftTools` target, every headless consumer pays for it.

## Versioning

The merged package starts at `0.x` and reaches `1.0.0` once the picking consolidation
([ecosystem#43](https://github.com/SecondMouseAU/ecosystem/issues/43)) has landed and settled. The
three old version lines (`OCCTSwiftTools` 1.6.4, `OCCTSwiftAIS` 1.3.2, `OCCTSwiftCADKit` 1.1.2) do
not continue here; continuing any one of them would have silently absorbed the other two histories
under the wrong line.

The old repositories are archived, not deleted. Their tags remain resolvable, so an unmigrated
consumer keeps building until it chooses to move.

## Who needs to do this, and in what order

**These are not independent manifest edits.** SwiftPM enforces target-name uniqueness across the entire transitive package graph, before pruning by which products a consumer uses, so a graph containing both this package and any package still pinning the old `OCCTSwiftTools` / `OCCTSwiftAIS` / `OCCTSwiftCADKit` fails outright:

```
error: multiple packages ('occtswiftais', 'occtswiftinteraction') declare targets with a
conflicting name: 'OCCTSwiftAIS'; target names need to be unique across the package graph
```

That is a hard resolution error, not a version-range conflict, and it fires even when the consumer never reaches the offending target. **A repo can migrate only once every package in its transitive graph has.**

| Wave | Repo | Uses | Behind |
|---|---|---|---|
| 1 | **OCCTSwiftScripts** | Tools, AIS | nothing. **This is the gate**, four consumers sit behind it |
| 1 | **OCCTSwiftUX** | Tools, AIS | nothing. OCCTStudio sits behind it |
| 1 | PadCAM | Tools, AIS, CADKit | nothing |
| 1 | Unfolder | CADKit | nothing |
| 2 | OCCTMCP | Tools, AIS | OCCTSwiftScripts |
| 2 | OCCTParts | Tools | OCCTSwiftScripts |
| 2 | OCCTDesignLoop | Tools | OCCTSwiftScripts |
| 3 | OCCTStudio | Tools, AIS | OCCTSwiftUX |

`OCCTSwiftPartsAgent` does **not** pin the old packages directly. It reaches them only through `gsdali/OCCTSwiftScripts` at `0.8.1`, a pre-org URL, so it is the stale-pin problem rather than this migration. `Unfolder` is in the same family and still pins pre-org URLs for its other dependencies; it needs modernising alongside rather than as part of this.

**Partial migration is not a safe intermediate state** for anything depending on a repo that has not yet moved. Plan for the whole set, not one repo at a time.
