---
title: Dashboard touched-series test still sees rows from earlier tests
author: Justinrooks
date: 2026-10-14
branch: main
touches:
  - AGENTS.md
---

## Decided
- A fresh dedicated PostgreSQL database plus serial SwiftPM execution removed the broad migration and connection failure pattern; one touched-series ordering test still failed because other suite rows were present in the same database.
- OperatorDashboardTargetableCoverageTests wraps touched-series fixtures in a rollback transaction but does not isolate arcus_series rows inserted by other tests; its global rolling-window query can therefore evict fixture rows under the 250-row cap.

## Tried and ruled out
- Attributing the remaining NWS 249 versus NWS 188 mismatch to stale product ordering; the database contained committed Tornado Warning rows before the test transaction rolled back.

## Watch out
- Dedicated database isolation prevents contamination between runs, but not fixture leakage between tests inside one full-suite run. Test query fixtures need scoped identities/times or cleanup/rollback discipline shared across suites.
