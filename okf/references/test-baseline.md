---
type: reference
title: Test baseline
resource: https://github.com/SecondMouseAU/OCCTSwiftInteraction/blob/main/okf/references/test-baseline.md
tags: [tests, baseline]
description: The expected passing test and suite counts for `swift test`, per target. Update it in the PR that changes the count.
timestamp: 2026-10-01
---

# Test baseline

Run `OCCT_SERIAL=1 swift test --parallel --num-workers 1`. All tests pass; the counts to expect:

| Target | Tests | Suites |
|---|---|---|
| OCCTSwiftToolsTests | 75 | 12 |
| OCCTSwiftCADKitTests | 124 | 5 |
| OCCTSwiftAISTests | 206 | 20 |
| **Total** | **405** | **37** |

A count that differs from this is either a test added or lost without this page being updated, or a
suite that failed to run. Treat the second as the default suspicion.
