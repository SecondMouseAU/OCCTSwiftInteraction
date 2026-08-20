---
title: Cookbook
nav_order: 2
has_children: true
---

# Cookbook

Short, task-oriented recipes for the OCCTSwiftTools bridge layer. Every example
uses the real public API. The converters are namespacing enums of `static
func`s, so you call them directly with no instance to construct. Each recipe
starts with `import OCCTSwiftTools` (and `import OCCTSwift` when it touches
kernel types).

- [Shape to ViewportBody](shape-to-body): mesh + picking metadata for a solid, with mesh-quality presets and edge-density knobs.
- [Point clouds](point-clouds): turn a `[SIMD3<Float>]` into a point-sprite `ViewportBody` with per-point colours.
- [Curves, surfaces, and wires](curves-surfaces-wires): edge-only bodies from `Curve2D` / `Curve3D` / `Wire`, and isoparametric grids from `Surface`.
- [Loading a CAD file](loading-cad-files): load STEP / IGES / STL / OBJ / BREP into renderable bodies via `CADFileLoader`.
- [Durable identity and GraphUIDs](topology-graph-uids): turning a render-path ordinal back into a `Shape` and a `BRepGraph.GraphUID`, and what face identity means.
