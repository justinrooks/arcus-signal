---
title: Diagnose duplicate notification subject migration column
author: Justinrooks
date: 2026-10-14
branch: main
touches:
  - Sources/App/configure.swift
---

## Decided
The migration failure reports a pre-existing subject_kind column while Fluent considers AddNotificationSubjectIdentity pending. The migration is registered once and its prepare path is transaction-wrapped; the log alone cannot distinguish schema drift from concurrent application instances.

## Tried and ruled out
Duplicate registration in Sources/App/configure.swift is not the cause.

## Watch out
Before repairing production migration state, compare Fluent migration history with all four target tables, constraints, and indexes. Do not drop columns or mark the migration complete based only on subject_kind; the migration also backfills NWS identity and creates constraints and partial unique indexes.
