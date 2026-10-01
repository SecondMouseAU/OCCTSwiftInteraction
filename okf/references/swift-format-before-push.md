---
type: reference
title: Run swift-format lint --strict before every push
resource: https://github.com/SecondMouseAU/OCCTSwiftInteraction/blob/main/okf/references/swift-format-before-push.md
tags: [style, swift-format, ci, workflow]
description: Every Swift file in a change must pass `swift-format lint --strict` before it is pushed; CI blocks on it. How to run it locally, and the traps that made PR #30 fail it three times.
timestamp: 2026-10-01
---

# Run `swift-format lint --strict` before every push

**Everything must pass `swift-format lint --strict`.** The `code-style` CI job is blocking, so a
violation fails the PR. Run it over every Swift file the change touches, tests included, before
pushing, not after CI reports. The policy itself is
[code-style](../policies/code-style.md); this page is the practice.

```bash
swift-format lint --strict $(git diff --name-only origin/main -- '*.swift')
```

## Traps

- **A local `swift-format` can reject the repo's `.swift-format`** with `missing key
  orderedImports.shouldGroupImports`. Lint with a temp copy of the config that adds the key as
  `true` (CI's behaviour) rather than skipping the check. With it `false`, `format -i` orders
  `@testable import` lines differently from CI and fails `OrderedImports`.
- **Do not run `format -i` on files you did not change.** It reformatted `Package.swift` once.
- **Doc comments need a one-line summary, then a blank `///`**, before any further sentence
  (`BeginDocumentationCommentWithOneLineSummary`). A two-sentence first paragraph fails.
- **Inside `#if`, indent the body one level** (`Indentation`), including a lone `import`.
- **Lines are 100 columns**, tests too (`LineLength`), and no trailing whitespace.
- A clean `swift build` or `swift test` says nothing about any of this.
