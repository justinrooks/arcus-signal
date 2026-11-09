---
title: Interpret revocation fence Trail conflicts against actual behavior
author: Justinrooks
date: 2026-11-09
branch: issue-410
touches:
  - AGENTS.md
  - Sources/App/Controllers/DeviceControllerV3.swift
  - Sources/App/Models/Device/DeviceInstallationModel.swift
  - Sources/App/Models/Notification/NotificationCandidateStore.swift
  - Sources/App/configure.swift
  - Tests/AppTests/DeviceV3ControllerTests.swift
  - Sources/App/Migrations/AddLocationEvidenceFence.swift
---

## Decided
The #410 trail check produces lexical conflicts at the retained capturedAt watermark and regression fixtures. The implementation preserves capturedAt, stores a separate transition floor, clears geography, and retains the existing installation advisory-lock transaction. Regression fixtures enable meso only in their local test Application and seed NWS watches so queued reconciliation and the shared NWS/meso post-claim eligibility gate are exercised.

## Tried and ruled out
Changing correct source merely to silence token-overlap diagnostics would weaken the regression. These matches do not change runtime rollout gates, delivery-row locking, or release evidence collection.

## Watch out
Keep the trail check conflict explanation in the commit or PR. The negative findings in the companion revocation learning describe the old behavior the regression reproduces, rather than a reason to remove capture metadata or consent tests.
