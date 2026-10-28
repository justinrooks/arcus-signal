---
title: Refuse credential migration rollback after enrollment
author: Justinrooks
date: 2026-10-28
branch: issue-386
touches:
  - Sources/App/Migrations/CreateInstallationCredentials.swift
  - Tests/AppTests/InstallationCredentialControllerTests.swift
  - docs/device-enrollment.md
---

## Decided
Credential migration reversal is permitted only when installation_credentials is empty. Hold a PostgreSQL ACCESS EXCLUSIVE table lock for the emptiness query and schema deletion in one transaction. Reject a populated reversal without losing any verifier or weakening subsequent request authority.

## Tried and ruled out
An unconditional destructive revert leaves the recovery invariant dependent on operator documentation. A separate emptiness query without a table lock permits a concurrent claim to be erased between the query and deletion.

## Watch out
Preserve both regression boundaries: empty-table reversal must continue to work, and populated reversal must fail with verifiers retained. After a refused reversal, verify same-secret retry succeeds, competing-secret claim fails, and v1 mutations remain unauthorized.
