---
title: Require issue-scoped test databases for migration tests
author: Justinrooks
date: 2026-10-21
branch: issue-344
touches:
  - Tests/AppTests/MesoNotificationTestControllerTests.swift
---

## Decided
- Database-backed test helpers that run migrations must reject missing or shared database configuration before app setup. For issue-scoped focused suites, require a database URL whose name begins `arcus_issue<number>_test_` or `arcus_issue<number>_validation_`.
- Production-environment route tests must reuse the explicitly selected isolated test database rather than installing a fallback URL.
- Delete seeded rows on both successful and throwing test paths.

## Tried and ruled out
- Rejecting only the literal `arcus_signal` name is too weak: arbitrary names with words like `test` or `issue` can still identify shared or production databases.

## Watch out
- Trail check matches some test and route phrases lexically to unrelated product learnings. Confirm semantic conflict before changing behavior; document false positives in the commit message.
