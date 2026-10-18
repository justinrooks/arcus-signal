# Arcus Signal

Arcus Signal is the notification backend for Project Arcus / SkyAware. It runs as two Vapor executables:

- `Run`: API process for HTTP endpoints
- `RunWorker`: worker process for queue consumption + ingestion scheduling

## Overview

Arcus Signal ingests active NWS CAP alerts from `api.weather.gov`, stores immutable revision records, maintains a canonical alert series snapshot, and dispatches downstream targeting work through queue lanes.

Current ingestion flow:

- Persist revision records idempotently by CAP message URN.
- Resolve/merge referenced revisions into a canonical series.
- Compute and persist geolocation coverage (`GeoShape` JSONB + H3 cells/hash).
- Use a durable outbox table for ingest -> target queue handoff.
- Keep queue processing split across named lanes (`ingest`, `target`, `send`).

## Local SwiftPM

```bash
swift build
swift run Run migrate --yes
swift run Run serve --hostname 0.0.0.0 --port 8080
swift run RunWorker serve --hostname 0.0.0.0 --port 8081
swift test
```

`REDIS_URL` is required outside development/testing environments.
`DATABASE_URL` is required outside development/testing environments.
Optional tuning:

- `QUEUE_WORKER_COUNT` (default `1` for worker runtime)
- `REDIS_POOL_MAX_CONNECTIONS` (default `8`)
- `REDIS_POOL_CONNECTION_TIMEOUT_SECONDS` (default `30`)
- `WORKER_STARTUP_GRACE_SECONDS` (default `5`)

Current AQI endpoint configuration:

- `AIRNOW_API_KEY` (EPA AirNow API key; required on the API service to enable `GET /api/v1/air-quality/current`)

Meso notification rollout configuration:

- `MESO_NOTIFICATIONS_ENABLED` is shared by the API and worker and defaults to `false`.
- Enabling meso delivery requires valid sandbox and production APNs credential pairs on the worker. Worker startup fails with a configuration error if either environment is incomplete or invalid.
- The API receives only the rollout flag; APNs credentials and private keys remain worker-only.

Worker APNs configuration:

- `APNS_TEAM_ID` (Apple Team ID)
- `APNS_TOPIC` (APNs topic, usually the app bundle identifier)
- `APNS_SANDBOX_KEY_ID` (Apple Key ID for sandbox APNs auth)
- `APNS_SANDBOX_PRIVATE_KEY_PATH` (absolute path to mounted sandbox `.p8`)
- `APNS_PROD_KEY_ID` (Apple Key ID for production APNs auth)
- `APNS_PROD_PRIVATE_KEY_PATH` (absolute path to mounted production `.p8`)

APNs startup behavior:

- `development`/`testing`: missing or invalid APNs config logs a warning and disables APNs client setup.
- non-dev environments (including `production`): missing or invalid APNs config fails worker startup.

Development/testing Postgres fallback (when `DATABASE_URL` is absent):

- `DATABASE_HOST` (default `127.0.0.1`)
- `DATABASE_PORT` (default `5432`)
- `DATABASE_USERNAME` (default `arcus`)
- `DATABASE_PASSWORD` (default `arcus`)
- `DATABASE_NAME` (default `arcus_signal`)

Current migration set includes series/revision persistence, geolocation (`arcus_geolocation`), and target dispatch outbox (`target_dispatch_outbox`).

## Docker Compose

```bash
ARCUS_SIGNAL_IMAGE_TAG=development docker compose up --build
```

Compose requires an explicit `ARCUS_SIGNAL_IMAGE_TAG`; missing or empty values fail
configuration instead of selecting `latest`. Use `development` for local builds.

Compose sets defaults for queue tuning env vars (`QUEUE_WORKER_COUNT`, `REDIS_POOL_MAX_CONNECTIONS`, `REDIS_POOL_CONNECTION_TIMEOUT_SECONDS`, `WORKER_STARTUP_GRACE_SECONDS`) and the shared `MESO_NOTIFICATIONS_ENABLED` rollout gate (`false`).

Compose APNs wiring (worker only):

- `APNS_TOPIC` defaults to `com.skyaware.app`.
- `APNS_SANDBOX_PRIVATE_KEY_PATH` defaults to `/run/secrets/apns/AuthKey-sandbox.p8` inside the worker container.
- `APNS_PROD_PRIVATE_KEY_PATH` defaults to `/run/secrets/apns/AuthKey-prod.p8` inside the worker container.
- `APNS_SANDBOX_P8_HOST_PATH` controls the host-side sandbox `.p8` bind mount path (default `./.secrets/apns/AuthKey-sandbox.p8`).
- `APNS_PROD_P8_HOST_PATH` controls the host-side production `.p8` bind mount path (default `./.secrets/apns/AuthKey-prod.p8`).
- `APNS_SANDBOX_KEY_ID`, `APNS_PROD_KEY_ID`, `APNS_TEAM_ID`, and `APNS_TOPIC` are read from environment and passed only to the worker service.
- The shared `MESO_NOTIFICATIONS_ENABLED` value is passed to both API and worker; when true, the worker requires both APNs environments to be configured.

Example:

```bash
mkdir -p .secrets/apns
# copy your real keys to .secrets/apns/AuthKey-sandbox.p8 and .secrets/apns/AuthKey-prod.p8
APNS_SANDBOX_KEY_ID=ABC123SANDBOX \
APNS_PROD_KEY_ID=XYZ789PROD \
APNS_TEAM_ID=TEAM123456 \
APNS_TOPIC=com.skyaware.app \
ARCUS_SIGNAL_IMAGE_TAG=development docker compose up --build
```

For production deployments, prefer Docker secrets or an external secret manager over direct bind mounts.

Services:

- `api` on `:8080` (`GET /health`)
- `worker` on `:8081` (`GET /health`)
- `redis` on `:6379`
- `postgres` on `:5432`

The worker uses Vapor Queues scheduled jobs to dispatch `IngestNWSAlertsJob` every 60 seconds (`minutely().at(0)`).

## Releases

Arcus Signal server versions use stable SemVer tags in the form `vMAJOR.MINOR.PATCH` (for example, `v1.1.0`). Publishing a non-prerelease GitHub Release is the production container build boundary; pull requests, merges to `main`, and raw tag pushes do not publish production images.

Each release builds the exact release tag and publishes one image containing both the `Run` API and `RunWorker` worker. The immutable `vMAJOR.MINOR.PATCH` image tag is authoritative. The same image is also tagged with its source revision for traceability, while `latest` is only a convenience pointer to the most recently published stable release.

The release version and full source revision are stored in the runtime image as `ARCUS_SIGNAL_VERSION` and `ARCUS_SIGNAL_REVISION`, along with corresponding OCI image labels. Local Compose builds retain the Dockerfile defaults `development` and `unknown` when release metadata is absent.

Publishing an image does not deploy it. Production deployment remains a separate, explicit operation.

### Production deployment

After publishing a stable GitHub Release and waiting for its versioned GHCR image to succeed:

1. SSH to the Arcus Signal server.
2. Run `./install v1.1.0` with the release version to deploy.
3. Verify API and worker health.

The installer pulls the requested version before starting the application and uses that same image tag for both API and worker. After image and HTTP health checks pass, it atomically saves a final `ARCUS_SIGNAL_IMAGE_TAG=<tag>` assignment in `.env`, preserving other contents, ownership, and permissions. Later successful releases replace that final assignment. This keeps ordinary Compose recreations on the deployed version. Earlier failed phases leave the previous saved tag unchanged. Preflight blocks downgrades. Recovery with an older image requires a separately approved procedure compatible with the already migrated database; changing images does not revert schema or data.

### Agent-guided deployments

The repository-local Codex skill at `.agents/skills/arcus-signal-release/SKILL.md` accepts an explicit request such as `release v1.4.2` as authorization to install that version once and observe the result. It uses direct Docker access; no `sudo` is required when the invoking account can reach the Docker daemon. Runtime execution approvals still apply.

`./install vMAJOR.MINOR.PATCH` runs preflight, saves a baseline, pulls and verifies the requested image, checks packaged binaries, runs production migrations, verifies the schema, and replaces only API/worker. Existing PostgreSQL and Redis must already be healthy. The checkout must have no tracked modifications. Python 3 and a writable regular `.env` file and parent directory are required; symlinked `.env` files are rejected before deployment. The installer writes a private run directory under `${TMPDIR:-/tmp}` and prints its `deployment.json` path, including the failed phase, migration state, and `persistedTag`. A save or saved-configuration verification failure after rollout remains a failed deployment; inspect the record before any approved recovery. It never retries or rolls back automatically.

Preflight checks a published stable GitHub release and accessible GHCR image. It requires an existing readable PostgreSQL custom/tar archive: by default the newest readable `*.dump` in `~/backups/arcus-signal`. Override with `ARCUS_RELEASE_BACKUP_FILE` or `ARCUS_RELEASE_BACKUP_DIR`; `ARCUS_RELEASE_BACKUP_MAX_AGE_HOURS` defaults to 24. A readable archive is not proof of a tested restore. `./tools/release-preflight.sh vMAJOR.MINOR.PATCH` checks readiness independently without pulling or starting anything.

The final installer phase verifies both application images with its temporary image-tag
override removed. Independently verify the saved selection after the installer exits:

```bash
env -u ARCUS_SIGNAL_IMAGE_TAG docker compose --env-file .env config --images
```

Both application references must use the requested release. Avoid a conflicting
`ARCUS_SIGNAL_IMAGE_TAG` in your shell when recreating services: shell values take
precedence over `.env`. Immediately after a successful install, run:

```bash
./tools/release-observe.sh --deployment /absolute/path/to/deployment.json
```

The observer captures sanitized snapshots immediately and at **2, 7, and 12 minutes** after observation starts, writing a unique observation directory alongside the deployment record. It compares ingestion, dispatch backlogs, stuck claims, metrics freshness, and post-deploy APNs completions. Delivery evidence starts when application replacement begins. Completions before the new worker image is verified are retained in `ambiguousSentCount`/`ambiguousFailedCount`; later completions populate `sentCount`/`failedCount`, including those before installer HTTP checks finish. Overlap-only traffic is `ambiguous`; a quiet delivery window is `unobserved`. Rolling 24-hour counts alone do not establish new-version delivery. The final report retains timestamped findings from every snapshot, labels each recovered or unresolved, and identifies conditions already present in the baseline. Recovered warnings remain visible even when the final status passes. An age-only SPC warning near its ten-minute ingest interval calls for a recheck.

`./tools/release-snapshot.sh --json` remains available for standalone read-only evidence; add `--expected-tag vMAJOR.MINOR.PATCH`, `--since YYYY-MM-DDTHH:MM:SSZ` (optional fractional seconds), `--attributable-since UTC_TIMESTAMP` to retain overlapping deliveries separately, or `--output /existing/private/directory/snapshot.json`. Docker access/inspection errors are collection failures, not missing services. `/health` alone does not verify downstream ingestion or delivery. Helpers return 0 for passed, 1 for attention, 2 for invalid invocation, 3 for unavailable prerequisites/collection, and 4 for unsafe/failed state.

`MESO_NOTIFICATIONS_ENABLED` must remain explicitly false on both API and worker through v1.4.1 and later releases until the separately approved app cutover. This workflow does not publish releases, create backups, enable meso delivery, or perform automatic rollback/schema repair.

## Endpoint Docs

Detailed endpoint behavior, validation rules, and examples are documented in [docs/api-endpoints.md](docs/api-endpoints.md).
