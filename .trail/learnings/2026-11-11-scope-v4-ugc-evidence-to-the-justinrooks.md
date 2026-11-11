---
title: Scope V4 UGC evidence to the accepted capture
author: Justinrooks
date: 2026-11-11
branch: issue-414
touches:
  - AGENTS.md
  - Sources/App/Controllers/DeviceController.swift
  - Tests/AppTests/DeviceV3ControllerTests.swift
  - docs/architecture.md
---

## Decided
Signal #414 makes every strictly newer V4 capture retire prior UGC codes and labels before applying supplied fields, even in the same H3 cell. Use the same PostgreSQL microsecond comparison as tie acceptance. Compatible equal-tick retries preserve enrichment; V1–V3 keep patch behavior. No DTO or schema migration. Deploy all API instances before the dependent LOC-16 client release.

## Tried and ruled out
The authenticated PostgreSQL reproduction showed that retaining same-H3 UGC lets a newer minimal upload refresh inherited codes, rejects changed equal-time enrichment, and suppresses reconciliation. H3 identity does not prove UGC identity.

## Watch out
UGC-only and unsupported-geometry matching waits for current enrichment; H3 matching continues. Already-active alerts are discovered after enrichment, but alerts expired before then cannot be recovered. Preserve consent fences, capture watermark, advisory locks and delivery guards. The issue414 trail check reported lexical conflicts about deleting presence, backup restore tests, placeholder APNs enrollment, meso configuration approval, stale product ordering and delivery locks; none describes this change. Presence is updated in place, tests use isolated seeded notification fixtures, and all existing safeguards remain.
