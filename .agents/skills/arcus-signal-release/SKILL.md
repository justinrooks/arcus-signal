---
name: arcus-signal-release
description: Deploy and observe an explicitly approved Arcus Signal production release with the repo installer, NWS regression checks, bounded monitoring, and a human-readable report.
---

# Arcus Signal release deployment

Operate from the Arcus Signal checkout **on the deployment host**. This skill does not publish GitHub releases, merge PRs, or provision infrastructure. If you cannot execute commands on the host, explain what remains to be performed; never claim deployment or monitoring occurred.

**Source of truth:** `install` owns deployment mechanics, `tools/release-snapshot.sh` captures sanitized operational evidence, `docs/architecture.md` defines runtime and notification invariants, and `release/RELEASE_NOTES.md` describes the selected version.

## Mandatory safeguards

- Target only a **published, stable `vMAJOR.MINOR.PATCH` release** with an available GHCR versioned image. Never deploy `latest` or an unreviewed branch build.
- **Get explicit human approval immediately before running `./install`.** Show target/current versions, migration considerations, backup status, NWS baseline, meso gate, and rollback target. Preflight does not imply deployment approval.
- For the **v1.4.0 infrastructure release**, `MESO_NOTIFICATIONS_ENABLED` must be **explicitly false** on API and worker. Do not enable it; activation belongs to #289 after the app cutover.
- No automatic rollback, migration reversal, editing production configuration, test APNs sends, synthetic NWS alerts, queue draining, Redis flushing, ledger edits, or data cleanup.
- Never display or copy `.env`, APNs keys/tokens, credentials, installation IDs, precise locations, raw dashboard JSON, or unredacted logs. Store sanitized evidence outside the repo.
- A successful `/health` only proves HTTP response, **not** Redis, Postgres, NWS ingestion, or APNs health.
- Do not promise continued background monitoring beyond the bounded observation session.

## Preflight, read-only

1. Read `AGENTS.md`, `install`, `docker-compose.yml`, the relevant `docs/architecture.md` delivery sections, and the version section in `release/RELEASE_NOTES.md`. Consult `docs/Sql/NotificationProcessing.sql` and `docs/Sql/NotificationDebug.sql` for troubleshooting clues, **not** as scripts to run wholesale.
2. Verify deployment host, repository remote, clean `main` checkout, upstream, and available `.env` without showing its contents. The installer uses `git pull --ff-only`; unexpected branch, dirty tracked changes, or divergent history requires operator resolution.
3. Verify the stable GitHub Release is published (not draft/prerelease), its GHCR image can be accessed, and API/worker are currently on the same version. Review migrations for compatibility with the intended fallback image.
4. Inspect only the two resolved meso gate values, not all Compose environment values: `sudo env ARCUS_SIGNAL_IMAGE_TAG="<tag>" docker compose --env-file .env config --format json | jq -r '[.services.api.environment.MESO_NOTIFICATIONS_ENABLED, .services.worker.environment.MESO_NOTIFICATIONS_ENABLED] | join(" / ")'`. They must agree; both must be false for v1.4.0.
5. Confirm a restorable recent PostgreSQL backup exists and deployment conditions are sensible given any active severe weather. This skill does not create or restore backups.
6. Capture a coarse baseline: `./tools/release-snapshot.sh --json --output /tmp/arcus-release-before.json`. Its nonzero exit means attention/failed state; investigate and disclose that baseline, not overwrite it or call it healthy.
7. Present a concise go/no-go summary and **request explicit deployment approval**. Stop if approval is missing.

## Deployment, approved write boundary

Run `./install <tag>` once, from repo root. Do not independently reimplement its pull, migration, startup, or health steps. On a partial failure, stop and report which operation completed; do not retry migrations or initiate rollback without separate approval.

## Post-deployment observation, read-only

1. Capture `./tools/release-snapshot.sh --expected-tag <tag> --json --output /tmp/arcus-release-after-1.json`. Check both images and both HTTP health endpoints, Docker service status, PostgreSQL/Redis health, matching meso gate values, and dashboard availability.
2. Continue a **bounded 10–15 minute observation**, taking at least two more snapshots separated in time. Check `generatedAt` advances, and inspect the existing operator dashboard (`/dashboard`, `/dashboard/delivery`, `/dashboard/mesos`).
3. Compare baseline vs post-deploy: NWS ingest status/success age/failures; target and notification outbox backlog counts/ages; stuck claimed rows; APNs sent/failed counts and failure reasons; no-op decisions; SPC meso ingest. The dashboard has rolling windows and staggered refresh cadences. A quiet period with no pushes is **inconclusive**, not proof that delivery works or fails.
4. Review bounded local logs only when relevant, e.g. `sudo docker compose --env-file .env logs --since 10m --tail 150 api worker`. Do not upload unredacted output. Look for new startup/migration errors, Postgres or Redis failures, repeated APNs failures, and exhausted retries.
5. Trace suspected failures through the real boundaries: ingest → target/outbox → queue handoff → ledger claim → APNs completion. Distinguish **preexisting vs new**, **NWS vs meso**, **no traffic vs failed traffic**, and **stale dashboard vs stale upstream ingest**. Diagnostic SQL, if truly necessary, must be narrow, read-only, and privacy-preserving; never run a bundled query file wholesale.
6. Escalate on mismatched images, unhealthy containers, missing/stale metrics, newly stale NWS ingestion, growing backlogs, new stuck claims, repeated new DB/Redis/APNs errors, or an unexpectedly enabled meso gate. Do not automatically rollback on a rate fluctuation or missing activity.

## Rollback and report

Any rollback requires **separate approval** and confirmed compatibility of the previous binary with the **already-migrated** database. `./install <previous-tag>` selects older images but also invokes migrations; it does **not** revert schema or data. Do not run Fluent revert or schema-modifying SQL automatically.

Report: target tag/revision, previous image, migration outcome, gate, API/worker status, snapshot times, NWS ingest/queue/APNs comparison, relevant sanitized errors, and confidence in notification delivery (`observed` / `unobserved` / `degraded`). Record unresolved concerns and explicit next actions; never assert APNs is healthy solely because `/health` returned 200.
