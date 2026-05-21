# API Endpoint Reference

This document reflects the currently registered routes in `Sources/App/apiRoutes.swift`, `Sources/App/Controllers/*`, and worker-only route wiring in `Sources/App/configure.swift`.

## Runtime split

- API process (`Run`, default `http://localhost:8080`): all endpoints below except worker health.
- Worker process (`RunWorker`, default `http://localhost:8081`): `GET /health` only.

## `GET /health` (API)

- Runtime: API
- Purpose: basic liveness check
- Response: `200 OK` with empty body

Example:

```bash
curl -i http://localhost:8080/health
```

## `GET /health` (Worker)

- Runtime: Worker
- Purpose: worker liveness check
- Response: `200 OK` body `ok`

Example:

```bash
curl -i http://localhost:8081/health
```

## `GET /api/v1/devices`

- Runtime: API
- Purpose: placeholder device endpoint
- Response: `200` with custom reason phrase `fetch the devices`

Example:

```bash
curl -i http://localhost:8080/api/v1/devices
```

## `POST /api/v1/devices/location-snapshots`

- Runtime: API
- Purpose: upsert device installation + latest location presence
- Success response: `200 OK`

```json
{
  "status": "ok",
  "receivedAt": "2026-05-09T22:00:00Z"
}
```

Required body schema (`application/json`):

- `capturedAt` (ISO8601 date)
- `locationAgeSeconds` (`>= 0`)
- `horizontalAccuracyMeters` (`>= 0`)
- `cellScheme` (`h3` or `ugc-only`)
- `apnsDeviceToken` (non-empty)
- `installationId` (UUID string)
- `source` (`foreground|backgroundRefresh|significantChange|manual|unknown`)
- `auth` (`always|whenInUse|denied|restricted|notDetermined|unknown`)
- `appVersion` (non-empty)
- `buildNumber` (non-empty)
- `platform` (`iOS|watchOS`)
- `osVersion` (non-empty)
- `apnsEnvironment` (`prod|sandbox`)

Optional:

- `h3Cell` and `h3Resolution` (must be provided together)
- `county`, `zone`, `fireZone`, `countyLabel`, `fireZoneLabel`, `isSubscribed`

Validation rules:

- `installationId` must be a valid UUID.
- `h3Cell` must be `> 0` when provided.
- `h3Resolution` must be in `0...15` when provided.
- `capturedAt` cannot be more than 5 minutes in the future.
- If `cellScheme = h3`, then both `h3Cell` and `h3Resolution` are required.

Common errors:

- `400 Bad Request` on enum mismatch, UUID parse failure, bounds issues, pair mismatch.

## `GET /api/v1/alerts`

- Runtime: API
- Query params:
  - `ugc` (optional)
  - `fire` (optional)
  - `h3` (optional, must be `> 0` when present)
- At least one of `ugc`, `fire`, `h3` is required.
- Response: `200 OK` JSON array of alert payloads.
- Error: `400 Bad Request` when no filter is provided or `h3 <= 0`.

Example:

```bash
curl -i "http://localhost:8080/api/v1/alerts?ugc=COC001"
```

## `GET /api/v2/alerts`

- Runtime: API
- Query params:
  - `id` (optional, Arcus series UUID; maps to `arcus_series.id` / APNs hot-alert `arcusAlertId`)
  - `sent` (optional; currently ignored for lookup behavior)
  - `county` (optional)
  - `forecast` (optional)
  - `fire` (optional)
  - `h3` (optional, must be `> 0` when present)
- Lookup modes:
  - Targeted lookup: provide `id` only (plus optional `sent`) to fetch exactly one current alert by `arcus_series.id`.
  - Collection lookup: provide one or more of `county`, `forecast`, `fire`, `h3`.
  - `id` is mutually exclusive with `county`, `forecast`, `fire`, `h3`.
- Response: `200 OK` JSON array of alert payloads.
- Error:
  - `400 Bad Request` when no valid filter is provided.
  - `400 Bad Request` when `h3 <= 0`.
  - `400 Bad Request` when `id` is malformed or combined with location filters.
  - `404 Not Found` when targeted `id` does not match an existing series.

Example:

```bash
curl -i "http://localhost:8080/api/v2/alerts?county=COC001&forecast=COZ041"
```

Targeted example:

```bash
curl -i "http://localhost:8080/api/v2/alerts?id=11111111-1111-1111-1111-111111111111"
```

## `GET /api/v1/notifications`

- Runtime: API
- Query param:
  - `status` optional
  - Allowed values: `all`, `claimed`, `sent`, `failed`
- Behavior:
  - no `status`: returns all rows
  - `status=all`: returns all rows
  - otherwise filters by exact status
- Response: `200 OK` JSON array
- Error: `400 Bad Request` for unsupported status

Example:

```bash
curl -i "http://localhost:8080/api/v1/notifications?status=sent"
```

## `POST /api/v1/dev`

- Runtime: API
- Purpose: enqueue fixture replay ingest job (non-production only)
- Request body:

```json
{
  "fixtureName": "nws-series-geometry-v1",
  "runLabel": "manual-replay-001"
}
```

Behavior by environment:

- `production`: returns `404 Not Found`
- non-production: validates payload and enqueues `IngestNWSAlertsJob`

Success response (non-production): `202 Accepted`

```json
{
  "status": "accepted",
  "source": "fixture",
  "fixtureName": "nws-series-geometry-v1",
  "runLabel": "manual-replay-001",
  "queuedAt": "2026-05-09T22:00:00Z"
}
```

Validation:

- `fixtureName` is required and must be non-empty after trimming.

## `GET /v1/metrics`

- Runtime: API
- Purpose: return operator dashboard snapshot JSON
- Success: `200 OK` with `OperatorDashboardSnapshotResponse`
- If no snapshot exists yet: `503 Service Unavailable` with reason `Operator dashboard snapshot unavailable.`

Example:

```bash
curl -i http://localhost:8080/v1/metrics
```

## `GET /dashboard`

- Runtime: API
- Purpose: return operator dashboard HTML
- Response:
  - `200 OK` HTML when snapshot exists
  - `503 Service Unavailable` HTML unavailable page when snapshot missing

Example:

```bash
curl -i http://localhost:8080/dashboard
```

## Postman collection

Use:

- `docs/postman/arcus-signal.postman_collection.json`

It includes happy-path and negative-path coverage for all routes above.
