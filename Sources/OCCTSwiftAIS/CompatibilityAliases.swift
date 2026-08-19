// CompatibilityAliases.swift
// OCCTSwiftAIS
//
// `InteractiveObject`, `SubShapeRef` and `SubShape` moved down to the OCCTSwiftTools target in
// OCCTSwiftInteraction#2. These aliases keep every `import OCCTSwiftAIS`-only call site compiling
// verbatim; the canonical home is `OCCTSwiftTools`, and new code should name them there.
//
// Deliberately NOT marked `@available(*, deprecated:)`, though the issue asked for that. A
// same-module typealias shadows the imported type it aliases, so deprecating these would emit a
// deprecation warning at all ~75 of this target's own uses of the three names, not just at a
// consumer's. Measured, not assumed. The doc comments carry the migration signal instead.

import OCCTSwiftTools

/// Moved to `OCCTSwiftTools.InteractiveObject`, aliased here for source compatibility.
public typealias InteractiveObject = OCCTSwiftTools.InteractiveObject

/// Moved to `OCCTSwiftTools.SubShapeRef`, aliased here for source compatibility.
public typealias SubShapeRef = OCCTSwiftTools.SubShapeRef

/// Moved to `OCCTSwiftTools.SubShape`, aliased here for source compatibility.
public typealias SubShape = OCCTSwiftTools.SubShape
