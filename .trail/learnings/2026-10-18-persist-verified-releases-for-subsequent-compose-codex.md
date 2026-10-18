---
title: Persist verified releases for subsequent Compose commands
author: Codex
date: 2026-10-18
branch: fix/persist-deployed-release-version
touches:
  - install
  - tools/lib/release-pin.py
  - tools/release-preflight.sh
  - docker-compose.yml
  - ".agents/skills/arcus-signal-release/SKILL.md"
  - tools/tests/test_release.py
  - tools/tests/test_release_pin.py
---

## Decided
- User requested a PR to close the release-selection persistence gap. Save a stable image tag only after the requested images and HTTP health pass. Record persistedTag and a separate saved_configuration_verification phase, resolving Compose with ARCUS_SIGNAL_IMAGE_TAG removed from the installer environment.
- Compose requires an explicit image tag instead of silently defaulting to latest. Local builds explicitly use development. The release skill independently verifies image references after the installer exits.
- Atomically write a final canonical image-tag assignment in .env, replacing that final assignment on later releases. Preserve unrelated bytes, multiline values, line endings, ownership and permissions. Preflight requires Python 3 and a writable regular .env file and directory; reject symlinks.
## Tried and ruled out
- Exporting a tag during install does not persist deployment configuration. Pulling a versioned image does not update a separately cached local latest tag.
- Do not replace every key-looking line in .env: multiline secrets can contain the same text. Appending a final assignment preserves those values; real Compose interpolation tests verify final-definition precedence.
- Do not treat cached release images or shell install invocations as proof of historical deployment success. The exact past command selecting the September image remains unproven.
## Watch out
- A persistence or saved-configuration failure after rollout is still a partial failed deployment; schema and containers may already have changed. Do not retry or roll back automatically. Earlier migration/schema/HTTP failures leave the previous saved tag intact.
- Shell image-tag overrides still take precedence over .env. Test fresh Compose configuration without that override and simulate subsequent recreation using mocks. Real Compose tests run only config in temporary directories and never access the production daemon, database or .env.
- The two earlier local legacy-bootstrap commits remain on local main; this focused PR starts from freshly fetched origin/main and does not include them.
