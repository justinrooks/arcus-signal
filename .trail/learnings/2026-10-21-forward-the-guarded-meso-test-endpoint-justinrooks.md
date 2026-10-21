---
title: Forward the guarded meso test endpoint into Compose API
author: Justinrooks
date: 2026-10-21
branch: issue-347
touches:
  - docs/meso-notification-test-runbook.md
---

## Decided
- Keep the dedicated development enable flag and bearer secret out of shared production Compose defaults; document a temporary development-only override that forwards both only to the API container.
- Verify the container has the explicit flag and a sufficiently long secret using a fixed success message; never print the secret or dump rendered Compose configuration.

## Tried and ruled out
- Setting values only in the host .env does not put them in a service container unless the Compose service configuration forwards them.
- The general ARCUS_DEBUG_ENDPOINTS_ENABLED switch does not enable or authenticate the guarded meso test route.

## Watch out
- Run Compose with the development override and development Vapor environment for the isolated test API, then disable the endpoint and remove the temporary override after testing.
- Trail check may report unrelated lexical overlaps from this runbook's existing database, Docker, and evidence instructions; assess each against the actual finding before changing scope.
