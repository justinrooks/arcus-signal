---
title: Serialize enrollment and all device writes at installation authority
author: Justinrooks
date: 2026-10-28
branch: issue-386
touches:
  - Sources/App/Controllers/DeviceController.swift
  - Sources/App/Services/InstallationCredentialStore.swift
  - Sources/App/Migrations/CreateInstallationCredentials.swift
  - docs/device-enrollment.md
---

## Decided
Use ArcusCore 0.6.0 enrollment DTOs. Keep credential verifiers in a separate UUID-keyed table so token-free enrollment does not create delivery metadata. Enrollment and every v1/v2 device mutation hold the same PostgreSQL transaction-scoped advisory lock, including for missing rows; authorization and mutation use that connection. Claimed UUIDs reject v1 writes, while v2 requires the matching bearer secret. Legacy compatibility is explicitly configurable.

## Tried and ruled out
Checking authority before the mutation transaction leaves a claim/write race. A delivery-row lock alone cannot protect a UUID before that row exists. Creating placeholder APNs rows at enrollment would invent notification state. APNs token matching is not historical ownership proof; temporary UUID-only first claims are the approved trust-on-first-use migration.

## Watch out
Drain every old API process before clients enroll, and never roll back claimed installations to a binary that ignores credential authority. Preserve verifier records across recovery. Tests must verify existing-state overwrite rejection, successful reconciliation handoff, and actual cross-connection lock contention, not only response codes. The enrollment credential accepts canonical padded or unpadded base64url for exactly 32 decoded bytes; no plaintext is persisted or echoed.
