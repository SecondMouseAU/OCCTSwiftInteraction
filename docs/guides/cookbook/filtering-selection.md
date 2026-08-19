---
title: Filtering selection
parent: Cookbook
nav_order: 2
---

# Filtering selection

`selectionMode` restricts what *kind* of sub-shape is pickable. `SelectionFilter` restricts *which*
candidates of an allowed kind are — "only cylindrical faces," "only circular edges," "faces, but not
planar ones." Mirrors OCCT's `StdSelect_FaceFilter` / `StdSelect_EdgeFilter` /
`StdSelect_ShapeTypeFilter` family, minus the C++ handle machinery.

## Installing a filter

```swift
import OCCTSwift
import OCCTSwiftAIS

let ais = InteractiveContext(viewport: ViewportController())
ais.selectionMode = [.face]
ais.addFilter(SurfaceTypeFilter([.cylinder]))
```

With that installed, picking a planar face produces no selection and no hover highlight — the pick
is treated exactly like an empty-space click, leaving whatever was already selected untouched.

## Built-in filters

```swift
// By surface classification (OCCTSwift.Face.SurfaceType).
SurfaceTypeFilter([.cylinder, .cone])

// By 3D curve classification (OCCTSwift.Edge.CurveType).
CurveTypeFilter([.circle])

// By sub-shape kind — functionally overlaps `selectionMode`, but composes.
ShapeTypeFilter([.face, .edge])
```

Each non-matching case (e.g. a `.body` candidate against a `SurfaceTypeFilter`) is accepted
unconditionally — a `SurfaceTypeFilter` only ever narrows faces, never rejects other kinds outright.

## Composition

```swift
// Faces that are NOT planar.
AllOfFilter([ShapeTypeFilter([.face]), NotFilter(SurfaceTypeFilter([.plane]))])

// Cylindrical faces OR spherical faces.
AnyOfFilter([SurfaceTypeFilter([.cylinder]), SurfaceTypeFilter([.sphere])])

// Cylindrical faces under a given size, the closure escape hatch for anything
// no built-in filter expresses. `Face.bounds` is Optional (a face with no
// bounding box has no size to compare), so a face that has none fails the
// filter rather than reading as size zero.
AllOfFilter([
    SurfaceTypeFilter([.cylinder]),
    PredicateFilter { sub in
        guard case .face(_, let ref) = sub, let face = Face(ref.shape),
            let bounds = face.bounds
        else { return false }
        return bounds.max.x - bounds.min.x < 20
    },
])
```

## Multiple installed filters: AND, not OR

```swift
ais.addFilter(ShapeTypeFilter([.face]))
ais.addFilter(SurfaceTypeFilter([.cylinder]))
// A candidate must pass BOTH — equivalent to AllOfFilter([...]) installed as one filter.
```

This is a deliberate departure from OCCT: `AIS_InteractiveContext::AddFilter` combines multiple
installed filters with OR, so a second filter can only ever *widen* what's selectable, never narrow it
further — a surprising default when the whole point of installing a filter is to narrow. Here,
`ais.filters` combine with **AND**. Reach for `AnyOfFilter` explicitly when you want OR.

## Removing filters

```swift
let cylOnly = SurfaceTypeFilter([.cylinder])
ais.addFilter(cylOnly)
ais.removeFilter(cylOnly)   // by reference identity — filters are classes, like Dimension
ais.removeAllFilters()      // back to unrestricted picking
```

## What filters don't gate

- **Programmatic `select(_:)` / `deselect(_:)`** — an intentional override by app code, same as
  `selectionMode` today.
- **Manipulator widget picks** — they route through a separate pick stream
  (`viewport.widgetPickResult`) that never touches `handlePick`/filters at all; installing a
  restrictive filter has no effect on the widget.
