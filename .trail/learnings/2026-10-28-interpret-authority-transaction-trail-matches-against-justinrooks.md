---
title: Interpret authority transaction Trail matches against the actual lock scope
author: Justinrooks
date: 2026-10-28
branch: issue-386
touches:
  - Sources/App/Controllers/DeviceController.swift
  - docs/architecture.md
---

## Decided
The #386 implementation acquires the installation lock and loads the verifier inside each mutation transaction. The complete mutation uses that same connection. Keep this placement when maintaining the enrollment boundary.

## Tried and ruled out
No alternate implementation was needed after independent review.

## Watch out
Trail 0.22 reports lexical conflicts against the earlier enrollment learning when the code correctly mentions authority, mutation, and transaction together. These matches do not indicate the rejected pre-transaction authorization design. Verify the actual lock/read/write scope, and record the false-positive disposition in publication evidence.
