// multibody-fixture.swift
//
// Generates the multibody STEP fixture for OCCTSwiftInteraction's camera-framing tests
// (OCCTSwiftInteraction#13). Run with:
//
//   occtkit run multibody-fixture.swift --format step --output <dir>
//
// Three separated solids, deliberately chosen so a test can tell "framed everything" from
// "framed the first body" by arithmetic rather than by eyeballing a render:
//
//   origin   4x4x4 box   centred at (  0, 0, 0)   spans x -2 ..  2
//   middle   cylinder    centred at ( 30, 0, 0)   spans x 27 .. 33
//   far      6x6x6 box   centred at ( 60, 0, 0)   spans x 57 .. 63
//
// The whole assembly spans x -2 .. 63, so its combined bounds are ~16x the first body's
// 4mm width. A camera framing only body 0 cannot accidentally satisfy an assertion about
// the union, which is exactly the failure mode that survived a previous fix: two triangles
// of the same box are indistinguishable from each other, so a fixture whose bodies overlap
// or sit close together proves nothing.
//
// Distinct sizes as well as distinct positions, so a test can also identify WHICH body it
// resolved rather than only how many there are.

import Foundation
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()

guard let origin = Shape.box(width: 4, height: 4, depth: 4) else {
    fatalError("origin box")
}
// (added below as one compound)

guard
    let cylinder = Shape.cylinder(radius: 3, height: 8),
    let middle = cylinder.translated(by: SIMD3(30, 0, -4))
else {
    fatalError("middle cylinder")
}
// (added below as one compound)

guard
    let farBox = Shape.box(width: 6, height: 6, depth: 6),
    let far = farBox.translated(by: SIMD3(60, 0, 0))
else {
    fatalError("far box")
}
// One BREP compound, not three separately-added shapes.
//
// ScriptContext.emit writes a STEP assembly when given three shapes: a root product with three
// children. OCCTSwiftIO's STEP path then returns FOUR bodies for it, the assembly root plus its
// three children, and the root's triangles duplicate the children's exactly. A fixture shaped
// that way cannot discriminate a camera that frames every body from one that frames only the
// first, because the first body would already span the whole assembly.
//
// A BREP compound has no product structure, so it splits into exactly the three solids it holds.
guard let assembly = Shape.compound([origin, middle, far]) else {
    fatalError("compound")
}
try ctx.add(assembly, id: "assembly", color: [0.70, 0.70, 0.75, 1.0])

try ctx.emit(description: "Three separated solids for multibody import and camera-framing tests")
