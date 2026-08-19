---
title: Selection Filters
parent: API Reference
---

# Selection Filters

`SelectionFilter` and the built-in filter types, installed on `InteractiveContext` to restrict what's
pickable/hoverable beyond `selectionMode`. Mirrors OCCT's `SelectMgr_Filter` /
`StdSelect_FaceFilter` / `StdSelect_EdgeFilter` / `StdSelect_ShapeTypeFilter` family.

## Topics

- [SelectionFilter](#selectionfilter) · [SurfaceTypeFilter](#surfacetypefilter) · [CurveTypeFilter](#curvetypefilter) · [ShapeTypeFilter](#shapetypefilter) · [AllOfFilter / AnyOfFilter / NotFilter](#allioffilter--anyoffilter--notfilter) · [PredicateFilter](#predicatefilter) · [InteractiveContext filter management](#interactivecontext-filter-management)

---

## SelectionFilter

The protocol every filter conforms to. A conformer is a `class` (not a `struct`) so
`InteractiveContext.removeFilter(_:)` can identify a specific installed instance by reference —
the same reason `Dimension` conformers are removed by identity rather than value.

```swift
public protocol SelectionFilter: AnyObject, Sendable {
    func accepts(_ candidate: SubShape) -> Bool
}
```

- **`accepts(_:)`:** return `true` to keep `candidate` selectable/hoverable.
- Installed filters gate `InteractiveContext.handlePick` and `handleHover` — **never** programmatic
  `select(_:)`, which is an intentional override by app code (same as `selectionMode`).

---

## SurfaceTypeFilter

Restricts `.face` candidates to faces whose surface classifies as one of `kinds`
(`OCCTSwift.Face.SurfaceType`: `.plane`, `.cylinder`, `.cone`, `.sphere`, `.torus`,
`.bezierSurface`, `.bsplineSurface`, `.surfaceOfRevolution`, `.surfaceOfExtrusion`,
`.offsetSurface`, `.other`). Every other case is accepted unconditionally.

```swift
public final class SurfaceTypeFilter: SelectionFilter {
    public let kinds: Set<Face.SurfaceType>
    public init(_ kinds: Set<Face.SurfaceType>)
}
```

- **Example:**

```swift
ais.addFilter(SurfaceTypeFilter([.cylinder, .cone]))
```

---

## CurveTypeFilter

Restricts `.edge` candidates to edges whose 3D curve classifies as one of `kinds`
(`OCCTSwift.Edge.CurveType`: `.line`, `.circle`, `.ellipse`, `.hyperbola`, `.parabola`,
`.bezierCurve`, `.bsplineCurve`, `.offsetCurve`, `.other`). Every other case is accepted
unconditionally.

```swift
public final class CurveTypeFilter: SelectionFilter {
    public let kinds: Set<Edge.CurveType>
    public init(_ kinds: Set<Edge.CurveType>)
}
```

- **Example:**

```swift
ais.addFilter(CurveTypeFilter([.circle]))
```

---

## ShapeTypeFilter

Restricts candidates to one of the given sub-shape kinds. Functionally overlaps
`InteractiveContext.selectionMode` (which gates which kinds are resolved from a pick at all) but
composes with other filters.

```swift
public final class ShapeTypeFilter: SelectionFilter {
    public let modes: Set<SelectionMode>
    public init(_ modes: Set<SelectionMode>)
}
```

- **Example:** faces, but not planar ones:

```swift
ais.addFilter(AllOfFilter([ShapeTypeFilter([.face]), NotFilter(SurfaceTypeFilter([.plane]))]))
```

---

## AllOfFilter / AnyOfFilter / NotFilter

Composition, mirroring OCCT's AND / OR filters and a plain negation.

```swift
public final class AllOfFilter: SelectionFilter {
    public let filters: [any SelectionFilter]
    public init(_ filters: [any SelectionFilter])
}

public final class AnyOfFilter: SelectionFilter {
    public let filters: [any SelectionFilter]
    public init(_ filters: [any SelectionFilter])
}

public final class NotFilter: SelectionFilter {
    public let filter: any SelectionFilter
    public init(_ filter: any SelectionFilter)
}
```

- **`AllOfFilter`:** accepts only if every one of `filters` does.
- **`AnyOfFilter`:** accepts if at least one of `filters` does.
- **`NotFilter`:** inverts `filter`.
- **Example:**

```swift
let cylindersOrSpheres = AnyOfFilter([SurfaceTypeFilter([.cylinder]), SurfaceTypeFilter([.sphere])])
```

---

## PredicateFilter

Closure escape hatch for app-specific predicates a built-in filter doesn't express — e.g. a radius
threshold.

```swift
public final class PredicateFilter: SelectionFilter {
    public init(_ predicate: @escaping @Sendable (SubShape) -> Bool)
}
```

- **Example:**

```swift
let smallCylinders = AllOfFilter([
    SurfaceTypeFilter([.cylinder]),
    PredicateFilter { sub in
        // `Face.bounds` is Optional: a face with no bounding box has no size
        // to compare, so it fails the filter rather than reading as size zero.
        guard case .face(_, let ref) = sub, let face = Face(ref.shape),
            let bounds = face.bounds
        else { return false }
        return bounds.max.x - bounds.min.x < 20
    },
])
```

---

## InteractiveContext filter management

```swift
@Published public private(set) var filters: [any SelectionFilter]

public func addFilter(_ filter: any SelectionFilter)
public func removeFilter(_ filter: any SelectionFilter)   // by reference identity
public func removeAllFilters()
```

- **Combination semantics — a deliberate departure from OCCT.** OCCT's
  `AIS_InteractiveContext::AddFilter` combines multiple installed filters with OR (a candidate is kept
  if *any* installed filter accepts it) — a surprising default for narrowing what's selectable, since
  the second filter you add can only ever *widen* what's pickable. Here, `filters` combine with
  **AND**: a candidate must pass every installed filter. Use `AnyOfFilter` explicitly for OR.
- A candidate a filter rejects is treated exactly like an empty-space pick by `handlePick` — the
  current selection is left unchanged, not cleared. `handleHover` similarly reports no hover for a
  rejected candidate.
- **Example:**

```swift
ais.addFilter(SurfaceTypeFilter([.cylinder]))
// ... pick a planar face: no selection, no hover highlight ...
ais.removeAllFilters()
// ... unrestricted picking again ...
```
