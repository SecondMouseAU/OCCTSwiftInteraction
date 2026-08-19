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
([ecosystem#42](https://github.com/SecondMouseAU/ecosystem/issues/42)) has landed and settled. The
three old version lines (`OCCTSwiftTools` 1.6.4, `OCCTSwiftAIS` 1.3.2, `OCCTSwiftCADKit` 1.1.2) do
not continue here; continuing any one of them would have silently absorbed the other two histories
under the wrong line.

The old repositories are archived, not deleted. Their tags remain resolvable, so an unmigrated
consumer keeps building until it chooses to move.

## Who needs to do this

Eight repositories depend on at least one of the three:

| Repo | Uses |
|---|---|
| OCCTMCP | Tools, AIS |
| OCCTSwiftUX | Tools, AIS, CADKit |
| OCCTSwiftScripts | Tools, AIS |
| PadCAM | Tools, AIS, CADKit |
| OCCTParts | Tools, AIS |
| OCCTDesignLoop | Tools |
| OCCTSwiftPartsAgent | Tools |
| Unfolder | CADKit |

`OCCTSwiftPartsAgent` and `Unfolder` still pin pre-org `gsdali/` URLs and are stale for unrelated
reasons; they need modernising before this migration rather than as part of it.
