// The imports a consumer writes after moving to 3.0.0 (OCCTSwiftInteraction#61): the public
// `OCCTSwiftAIS` surface, deliberately not `@testable`, plus `OCCTSwiftTools` for the three
// selection types that live there.
import OCCTSwift
import OCCTSwiftAIS
import OCCTSwiftTools
import OCCTSwiftViewport
import Testing

/// `InteractiveObject`, `SubShapeRef` and `SubShape` reached the way 3.0.0 supports.
///
/// The three names are spelled unqualified on purpose, each at least once as a type annotation:
/// there a second declaration of the name is an ambiguity error, where a call such as
/// `SubShapeRef(...)` is quietly settled by overload resolution. Everywhere else in this target
/// they are qualified, so this is the file here that stops compiling if `OCCTSwiftAIS` or another
/// imported module ever declares a different type under one of these names.
@Suite("Moved selection types, named the 3.0.0 way")
struct MovedSelectionTypesTests {
    @MainActor
    @Test("AIS API takes and returns the OCCTSwiftTools types under their plain names")
    func plainNamesRoundTripThroughPublicAPI() throws {
        let context = InteractiveContext(viewport: ViewportController())
        context.selectionMode = [.face]
        let box = try #require(Shape.box(width: 2, height: 2, depth: 2))

        let object: InteractiveObject = context.display(box)
        let ref = SubShapeRef(
            shape: try #require(box.subShape(type: .face, index: 0)), ordinal: 0)
        let face: SubShape = .face(object, ref: ref)
        context.select(face, scheme: .replace)

        let selected: Set<SubShape> = context.selection.subshapes
        let bodies: Set<InteractiveObject> = context.selection.bodies
        let refs: [SubShapeRef] = selected.compactMap(\.ref)
        #expect(selected == [face])
        #expect(bodies == [object])
        #expect(refs == [ref])
        #expect(context.selection.faces.count == 1)
    }
}
