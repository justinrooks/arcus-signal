---
title: Production meso cutover requires explicit release gate expectations
author: Justinrooks
date: 2026-10-29
branch: main
touches:
  - docs/plans/architectural-convergence-progress.md
  - docs/plans/architectural-convergence-runbook.md
  - tools/release-preflight.sh
  - tools/lib/release-snapshot.jq
---

## Decided

Planning on 2026-10-29 created epic #397. Existing #391 owns accepted-presence-before-v3-ownership, #398 owns consent-aware coverage counts, #399 owns release expected-gate validation, and #400 owns bounded readiness. #289 remains the actual production cutover owner under #274. Justin approved the production meso cutover direction; technical readiness and exact release/device evidence remain necessary.

## Tried and ruled out

At baseline 5df90b54ff2791626d4ab79d5d58fa0611bc9780, tools/release-preflight.sh, install and tools/lib/release-snapshot.jq hard-code meso=false. Simply enabling the Compose flag would contradict installer/observer validation. Removing gate checks or accepting observed enabled state as approval would lose configuration authority. #399 should carry one explicitly selected expected state while validating baseline, target and API/worker parity.

## Watch out

This is planning evidence, not a deployed change or passed release test. Reverify current source and issue status. Gate-off rollback also needs client ownership-refresh evidence; disabled server config alone does not prove local notifications resumed. Keep development-only meso test endpoints out of production. #378 and separately gated #387 retain their existing ownership.
