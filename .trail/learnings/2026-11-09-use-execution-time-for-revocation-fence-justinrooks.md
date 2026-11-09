---
title: Use execution time for revocation fence migration backfills
author: Justinrooks
date: 2026-11-09
branch: issue-410
touches:
  - AGENTS.md
  - Sources/App/Migrations/AddLocationEvidenceFence.swift
  - Tests/AppTests/DeviceV3ControllerTests.swift
---

## Decided
PR #411 review identified that PostgreSQL now() is transaction-start time. AddLocationEvidenceFence backfill uses GREATEST(clock_timestamp(), accepted captured_at), so a migration waiting on its ALTER TABLE lock fences observations captured before a concurrent revocation commits. The existing accepted-capture watermark still covers future-skewed evidence.

## Tried and ruled out
A transaction-start timestamp can predate the committed state being backfilled after a DDL lock wait. The focused regression fails both fence >= revocation time and fence > buffered capture with now(), and passes with clock_timestamp().

## Watch out
The regression holds ROW EXCLUSIVE in a pre-migration writer, observes the migration's ungranted AccessExclusiveLock in pg_locks, captures buffered evidence, then releases the writer to commit revocation. Use observed lock state and independent database sessions to prove this ordering; a normal migration run cannot exercise it.
