---
title: Release scripts use direct Docker and 2 7 12 minute observation
author: Justin
date: 2026-10-15
branch: skill-enhancement
touches:
  - install
  - tools/release-preflight.sh
  - tools/release-snapshot.sh
  - tools/release-observe.sh
  - ".agents/skills/arcus-signal-release/SKILL.md"
---

## Decided
- Keep deployment in ./install with a strict explicit vMAJOR.MINOR.PATCH target, direct Docker access, one checkout lock, production migrations, a schema verification gate, and a phase/migration-state result. Never automatically retry or roll back.
- An explicit release request authorizes preflight, one installation, and observation without a second conversational approval. Runtime execution policy still applies.
- Per Justin's requested scope, omit test-process detection and test/migration coordination from release tooling. Leave application test infrastructure unchanged.
- Observe immediately and at 2, 7, and 12 minutes. Confirm post-deployment delivery using timestamped ledger completions; rolling 24-hour counts cannot establish it.
- Discover the newest readable .dump in ~/backups/arcus-signal, allow explicit overrides, verify age and pg_restore archive readability, and disclose that this does not prove a tested restore. Do not create backups implicitly.
- Keep both meso gates false through v1.4.1 and later releases until the separate approved app cutover.

## Tried and ruled out
- sudo Docker access: the agent session has NoNewPrivs while direct Docker works. Swallowing Docker failures previously produced false missing-service reports.
- compose run --no-build: the installed Compose CLI does not support that option. Pull and verify the image first, then use run --pull never --no-deps. Application up supports --no-build.
- A large Bash here-string for raw metrics needs a temporary file under the read-only sandbox. Pipe the response to jq instead.

## Watch out
- Migration command failure can follow committed changes; inspect schema and migration ledger before any separately authorized recovery.
- Archive verification is read-only and not a restore drill. Production deployment was not exercised while implementing the tooling; deployment behavior was validated with isolated Docker/HTTP/time mocks.
- trail check matched the release skill's production NWS freshness guidance against the older dashboard fixture-ordering learning. This is a false positive: no dashboard query or test ordering changed, and the fixture-contamination conclusion remains valid. Production freshness monitoring concerns timestamps, not fixture order. If still flagged at commit time, explain this distinction in the commit message.
