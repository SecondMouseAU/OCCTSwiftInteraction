// CompatibilityAliases.swift
// OCCTSwiftAIS
//
// `InteractiveObject`, `SubShapeRef` and `SubShape` moved down to the OCCTSwiftTools target in
// OCCTSwiftInteraction#2. These aliases keep an `import OCCTSwiftAIS`-only call site compiling;
// the canonical home is `OCCTSwiftTools`, and new code names them there.
//
// Deprecated as of 2.0.0. They were left un-deprecated through 0.x for a measured reason: a
// same-module typealias shadows the imported type it aliases, so deprecating them warned at every
// one of this target's own uses of the three names, not only at a consumer's. That is now fixed at
// the source rather than worked around. OCCTSwiftAIS's own code names the canonical
// `OCCTSwiftTools.*` types directly, at all 72 sites across 7 files, so these aliases are used by
// nobody inside this package and the deprecation reaches only the consumers it is aimed at.
//
// They are deliberately still here rather than removed. The three merged-away packages are not
// being deleted yet either; the migration is signposted rather than forced.

import OCCTSwiftTools

/// Moved to `OCCTSwiftTools.InteractiveObject`.
@available(
    *, deprecated,
    message:
        "Moved to OCCTSwiftTools in 2.0.0. Import OCCTSwiftTools and name it there; this alias will be removed in 3.0.0."
)
public typealias InteractiveObject = OCCTSwiftTools.InteractiveObject

/// Moved to `OCCTSwiftTools.SubShapeRef`.
@available(
    *, deprecated,
    message:
        "Moved to OCCTSwiftTools in 2.0.0. Import OCCTSwiftTools and name it there; this alias will be removed in 3.0.0."
)
public typealias SubShapeRef = OCCTSwiftTools.SubShapeRef

/// Moved to `OCCTSwiftTools.SubShape`.
@available(
    *, deprecated,
    message:
        "Moved to OCCTSwiftTools in 2.0.0. Import OCCTSwiftTools and name it there; this alias will be removed in 3.0.0."
)
public typealias SubShape = OCCTSwiftTools.SubShape
