---
title: Fence presence across observed location consent revocation
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
Issue #410 uses the existing installation advisory-lock transaction to persist location_evidence_not_before on observed sharing/authorization eligibility transitions. The floor is the maximum of server transition time, prior fence, and accepted capturedAt, including allowed future skew. Clear H3/UGC targeting and labels while preserving capture metadata. V3/V4 writes at or before the floor are stale; the shared post-claim NWS/meso consent check also rejects held candidates at or before it. Duplicate consent acknowledgments do not advance the floor; ordinary subscription, token, meso preference, and granted-to-granted authorization changes preserve eligible geography.

## Tried and ruled out
Consent/freshness alone allows old presence and queued reconciliation to revive after preference-only restoration. Clearing geography alone cannot prevent replay from restoring it. Deleting presence loses the existing capture watermark. A server-time-only floor misses previously accepted future-skewed timestamps.

## Watch out
The additive migration fences currently revoked V3 installations and clears their geography; rollback refuses populated fences. Whole-second client captures may need to advance beyond the transition second. The server cannot reconstruct unretained consent history or recall an APNs request already started. Keep API and worker binaries aware of this boundary. Tests use isolated issue-scoped PostgreSQL databases and force both real transaction commit orders.
