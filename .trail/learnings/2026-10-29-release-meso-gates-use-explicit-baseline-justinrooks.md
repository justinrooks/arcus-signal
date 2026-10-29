---
title: Release meso gates use explicit baseline and target expectations
author: Justinrooks
date: 2026-10-29
branch: issue-399
touches:
  - install
  - tools/release-preflight.sh
  - tools/release-snapshot.sh
  - tools/release-observe.sh
  - tools/lib/release-snapshot.jq
---

## Decided
Issue #399 evolves the release policy from unconditional meso=false to explicit baselineMesoGate and expectedMesoGate string values. Both CLI expectations default false. Preflight validates running API/worker against baseline and resolved Compose against target; installation records both, snapshots validate the selected expectation, and observation uses the recorded target. Legacy deployment records lacking both fields mean false; partial or invalid fields fail. Keep target configuration in the existing durable .env; flags validate it and never rewrite it.

## Tried and ruled out
Observed enabled containers do not establish approval. Clearing gate checks would hide parity/configuration failures. A shell-only gate export is insufficient for saved configuration verification. The old blanket false policy is intentionally superseded for approved selections; existing image, backup, migration, freshness, and delivery attribution safeguards remain.

## Watch out
This is mock-validated release tooling, not production cutover evidence. #289 retains enablement/device ownership and #400 readiness. Trail check can lexically match release words to unrelated DB isolation, debug endpoints, row locking, and NWS fixture learnings; those contracts are unchanged. Use a modern Python interpreter for existing fractional timestamp fixtures.
