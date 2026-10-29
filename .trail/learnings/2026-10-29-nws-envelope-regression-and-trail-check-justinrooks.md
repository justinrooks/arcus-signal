---
title: NWS envelope regression and trail check context
author: Justinrooks
date: 2026-10-29
branch: issue-384
touches:
  - Tests/AppTests/NWSInvalidEnvelopeIntegrationTests.swift
  - Tests/AppTests/NwsEventDTOTests.swift
---

## Decided
NWS envelope regression tests can verify failed sweep recording and dashboard freshness with synthetic input and an issue-specific database.
## Tried and ruled out
The release observation timing learning does not apply to NWS collection decoder tests; trail check can match those words lexically.
## Watch out
The focused lane summary may undercount passed tests; inspect the native Swift Testing lane summaries.
