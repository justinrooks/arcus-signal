---
title: Guarded development meso test endpoint contract
author: Justinrooks
date: 2026-10-21
branch: issue-344
touches:
  - Sources/App/Controllers/MesoNotificationTestController.swift
  - Sources/App/Extensions/DebugEndpointsConfiguration.swift
  - Sources/App/apiRoutes.swift
  - Tests/AppTests/MesoNotificationTestControllerTests.swift
---

## Decided
- Keep the meso notification test route absent unless Vapor runs in development and an explicit enable flag plus a bearer secret of at least 32 UTF-8 bytes are configured. Require exact bearer authorization, literal `meso`, a signed decimal Int64 H3 resolution-8 cell, and an existing installation.
- Stop valid requests at a `not-yet-wired` response until the dedicated synthetic meso operation is implemented. Do not persist the submitted coverage cell as installation presence or enqueue an alert.

## Tried and ruled out
- The general debug-endpoints flag is not endpoint authentication and cannot substitute for the dedicated development gate.
- An arbitrary integer is not a suitable H3 test fixture. Generate a valid resolution-8 cell through `H3LatLng.cell(at: .res8)`.

## Watch out
- Endpoint tests that reach installation lookup need an isolated Postgres database. Test environment helpers must preserve an explicitly supplied `DATABASE_URL` for development runs.
- Trail check can lexically match ordinary route/controller terms to unrelated release learnings. For this route, its collection/installation and app/build matches were unrelated; explain the scope distinction in the commit message if they recur.
