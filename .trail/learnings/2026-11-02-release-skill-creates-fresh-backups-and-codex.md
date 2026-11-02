---
title: Release skill creates fresh backups and retains the latest after success
author: Codex
date: 2026-11-02
branch: main
touches:
  - ".agents/skills/arcus-signal-release/SKILL.md"
---

## Decided
On November 1, 2026, the user requested that release invocations automatically create a fresh production database backup before installation and remove older backups at the end. The arcus-signal-release skill now requires a private custom-format archive, successful pg_dump and pg_restore list validation, and passes that exact archive to install. Prune only after installation, saved configuration verification, and complete observation pass; retain the newest validated archive. Failed/incomplete runs preserve backups.

## Tried and ruled out
Requiring an already fresh backup caused the v1.6.0 release to stop in preflight. The user authorized backup creation and a retry, then requested this become the skill workflow. Readability is not a restore test. Do not overwrite the previous archive or prune before release success.

## Watch out
This changes skill instructions, not install or standalone preflight behavior. Runtime execution approvals still apply. trail check reported lexical matches about tag persistence, environment forwarding, gates, Docker failures, timestamp precision, and test database names; this change preserves those existing boundaries and does not modify their code or relax their checks. Backup timestamps name files; delivery attribution still uses the existing fractional timestamps. No commit or PR was requested.
