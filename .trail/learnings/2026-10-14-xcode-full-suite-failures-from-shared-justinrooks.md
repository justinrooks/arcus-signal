---
title: Xcode full-suite failures from shared PostgreSQL test database
author: Justinrooks
date: 2026-10-14
branch: main
touches:
  - AGENTS.md
---

## Decided
- Xcode integration tests share DATABASE_URL or the default arcus_signal database; concurrent configure-and-migrate bootstraps can collide, and accumulated fixture rows contaminate aggregate assertions.
- In full-suite failures, separate PostgreSQL migration/connection failures and data-contaminated expectations from product defects by rerunning against a dedicated test database with test parallelization disabled.

## Tried and ruled out
- Treating the 55 generic PSQLError reports as 55 independent feature regressions; Xcode redacted the shared database errors, while test details exposed a duplicate-column migration race and a later run exposed a PostgreSQL deadlock.

## Watch out
- Xcode may count dynamic parameterized executions differently across device summaries and top-level test summary; report the bundle summary and specific failed tests, not a guessed count.
