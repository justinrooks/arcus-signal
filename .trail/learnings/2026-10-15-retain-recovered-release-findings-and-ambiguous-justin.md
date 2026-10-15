---
title: Retain recovered release findings and ambiguous rollout delivery
author: Justin
date: 2026-10-15
branch: skill-enhancement
touches:
  - install
  - tools/lib/release-observe.jq
  - tools/release-observe.sh
  - tools/release-snapshot.sh
  - tools/sql/release-delivery-evidence.sql
  - tools/tests/test_release.py
---

## Decided
- PR 341 review requires final release reports to retain operational conditions detected at every snapshot. Group findings with timestamps and offsets, mark recovered versus unresolved, and include baseline context. Recovery can allow a passing final status without erasing the incident.
- Begin ledger evidence at application replacement, with a separate high-resolution worker image verification boundary. Preserve completions in the overlap as ambiguous counts; only later completions establish observed new-version delivery. Quiet traffic remains unobserved.
- Older deployment records can use applicationStartAt and conservatively use finishedAt for attribution. Include their earlier overlap without claiming its sender version.
- Remove the incidental package-lock.json as explicitly requested; this repository does not need it for release tooling.

## Tried and ruled out
- Looking only at the last sample loses conditions that recover during the observation window.
- Starting evidence collection when installation finishes excludes valid completions during image and HTTP checks.
- Whole-second cutoffs can misattribute a completion from the verification second. Preserve fractional timestamp precision and compare normalized UTC boundaries.

## Watch out
- The ledger does not store a sender image identity, so overlap counts must not establish observed delivery. Successful Compose replacement and matching image verification precede the attribution boundary.
- Deterministic tests cover simultaneous transient NWS/backlog/claim/SPC conditions, early attributed and ambiguous completions, conservative older-record behavior, and fractional boundary validation. The delivery SQL also passes a read-only CTE fixture check without reading or writing delivery rows.
- Earlier trail check wording matches between production freshness and test fixture ordering remain unrelated; documentation prohibiting privilege escalation follows the existing release learning rather than reversing it.
