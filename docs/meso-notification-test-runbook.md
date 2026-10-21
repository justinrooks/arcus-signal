# Development Meso Notification Test Runbook

Use this procedure to validate the authenticated synthetic TEST meso path on the isolated `dev.skyaware.app` deployment and one registered Debug iPhone. The endpoint accepts a synthetic discussion through canonical meso persistence; with the meso rollout gate enabled, the existing event-first worker path performs matching, claims, queue retries, and APNs delivery. `installationId` is only a registration check and correlation value. It does not restrict recipients, so the development database must contain only the intended test installation before enabling delivery.

The route is `POST /v1/dev/notification-test` (the legacy `/api/v1/dev/notification-test` alias also exists). It is registered only when Vapor runs in `development`, `ARCUS_MESO_NOTIFICATION_TEST_ENABLED=true`, and `ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET` contains at least 32 UTF-8 bytes. The request's `type` must be `meso`, and `h3Cell` must be a signed decimal Int64 encoding a valid resolution-8 H3 cell.

## Preconditions and configuration

1. Confirm this is the isolated development API/worker deployment with its own database and Redis. Do not run this procedure against production or TestFlight infrastructure.
2. Confirm the API and worker use the same isolated development database and Redis, and that the worker consumes the `send` queue.
3. Set the API process to `VAPOR_ENV=development`, `ARCUS_MESO_NOTIFICATION_TEST_ENABLED=true`, and a dedicated `ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET` of at least 32 random bytes. Store the secret in the deployment secret manager; never put it in this repository, a URL, a ticket, or a captured terminal transcript. The root `docker-compose.yml` intentionally does not forward the test endpoint settings. For a Compose-based development deployment, use a temporary development-only override to pass them to the API container; host `.env` values alone are not container environment variables.
4. Set `MESO_NOTIFICATIONS_ENABLED=true` on both API and worker only for the test window. The worker's startup readiness currently requires complete sandbox and production APNs credential pairs, plus `APNS_TEAM_ID` and `APNS_TOPIC`. The test iPhone must be registered with `apns_environment='sandbox'`, so its actual send uses sandbox APNs. Keep production credentials in the secret manager and do not register production installations in this development database.
5. Ensure the development database contains only the intended Debug iPhone installation. Fanout is deliberately event-first and unfiltered; any other normally eligible installation whose H3 is covered can receive a TEST notification.
6. Confirm the Debug iPhone has notifications enabled, has recently uploaded H3 resolution-8 presence, has location authority accepted by the app, is subscribed, and has meso notifications explicitly enabled. Unknown meso preference and opt-out are ineligible.

For a Compose-based development deployment, inject the secret into a Bash shell from the deployment secret manager (or enter it with a hidden prompt), then create a temporary override containing no secret value:

```bash
read -s -r -p 'Development endpoint bearer secret: ' ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET
printf '\n'
export ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET
export VAPOR_ENV=development
DEV_COMPOSE_OVERRIDE="$(mktemp)"
chmod 600 "$DEV_COMPOSE_OVERRIDE"
cat > "$DEV_COMPOSE_OVERRIDE" <<'YAML'
services:
  api:
    environment:
      VAPOR_ENV: development
      ARCUS_MESO_NOTIFICATION_TEST_ENABLED: "true"
      ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET: ${ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET:?Inject the development endpoint secret into this shell}
YAML

docker compose -f docker-compose.yml -f "$DEV_COMPOSE_OVERRIDE" up -d api
docker compose -f docker-compose.yml -f "$DEV_COMPOSE_OVERRIDE" exec -T api sh -c \
  'test "$ARCUS_MESO_NOTIFICATION_TEST_ENABLED" = true && test "${#ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET}" -ge 32 && echo "development test endpoint configuration present"'
```

The check prints only a fixed confirmation after verifying the flag and minimum secret length; do not inspect or print the container environment, run `docker compose config`, or enable shell tracing while the secret is present. Keep using the same two `-f` arguments for subsequent Compose commands that inspect or restart the API. After the test, disable the endpoint in the API deployment, restart it without this override, remove the temporary override with `rm -f "$DEV_COMPOSE_OVERRIDE"`, and unset the shell variable with `unset ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET`. The dedicated test flag and bearer authentication are independent of `ARCUS_DEBUG_ENDPOINTS_ENABLED`; that general switch does not enable or authenticate this route. For a non-Compose deployment, set the same three values directly in the isolated development API service's environment through its secret manager and use an equivalent in-container presence/length check that never prints the secret.

Enable the rollout gate only after the route secret and worker credentials are installed. After configuration, verify the API health endpoint and worker health endpoint, then check that the authorized route is present in the development API logs or can be called with the secret. An unauthorized call should return `401`; do not use a real fixture request while validating the secret.

Check route authentication without creating a fixture by sending an empty JSON object with a deliberately invalid secret. A registered route must return `401`; a `404` means the development route is not enabled. The handler checks authorization before decoding the body or reading the database, so this probe creates no product or notification records.

```bash
curl --silent --show-error --include \
  --request POST 'https://dev.skyaware.app/v1/dev/notification-test' \
  --header 'Authorization: Bearer deliberately-invalid-test-secret' \
  --header 'Content-Type: application/json' \
  --data '{}'
```

## Read the registered installation and H3

Run this query against the isolated development database. It intentionally omits `apns_device_token` and shows only the values needed for matching and correlation.

```sql
SELECT
    i.installation_id,
    i.apns_environment,
    i.is_active,
    i.is_subscribed,
    i.meso_notifications_enabled,
    i.location_auth,
    p.h3_cell,
    p.h3_resolution,
    p.captured_at,
    p.received_at
FROM device_installations AS i
JOIN device_presence AS p USING (installation_id)
ORDER BY p.received_at DESC;
```

Select the single Debug iPhone row with `apns_environment = 'sandbox'`, active and subscribed state, `meso_notifications_enabled = true`, an accepted location authorization, a non-null `h3_cell`, `h3_resolution = 8`, and presence captured within the last 24 hours. Record its `installation_id` and `h3_cell` in the private test record. Never query or copy the device token.

Choose a valid resolution-8 H3 cell whose center is safely distant from the device for the negative case. Use an approved local H3 tool or known test fixture to derive the cell; do not change or spoof device presence. Confirm the cell is valid at resolution 8 before sending. A distant cell should avoid boundary ambiguity from H3 center-based polygon coverage.

## Positive and negative requests

In a private shell, load the bearer secret without echoing it. Keep `API_BASE` set to `https://dev.skyaware.app`, and replace the two identifiers with the values selected above. The JSON file contains no credential and can be removed immediately after the request.

```bash
read -s ARCUS_MESO_TEST_TOKEN
export ARCUS_MESO_TEST_TOKEN
API_BASE='https://dev.skyaware.app'
INSTALLATION_ID='<registered-debug-installation-uuid>'
POSITIVE_H3='<registered-resolution-8-h3-as-signed-decimal-int64>'
NEGATIVE_H3='<valid-distant-resolution-8-h3-as-signed-decimal-int64>'

request_meso_test() {
  local h3_cell="$1"
  local payload_file
  payload_file="$(mktemp)"
  chmod 600 "$payload_file"
  printf '{"installationId":"%s","h3Cell":%s,"type":"meso"}\n' \
    "$INSTALLATION_ID" "$h3_cell" > "$payload_file"
  curl --silent --show-error --include \
    --request POST "$API_BASE/v1/dev/notification-test" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$ARCUS_MESO_TEST_TOKEN") \
    --header 'Content-Type: application/json' \
    --data-binary "@$payload_file"
  rm -f "$payload_file"
}

request_meso_test "$POSITIVE_H3"
request_meso_test "$NEGATIVE_H3"
unset ARCUS_MESO_TEST_TOKEN
```

Each request should return `202 Accepted`, `status: "accepted"`, a unique `productID`, `validEnd`, the submitted `installationId`, and `notificationStatus: "pending"`. `pending` means the durable intent was accepted; it does not mean the worker queued a send, APNs accepted it, or the phone received it. Save each returned product ID and request timestamp in the private evidence record.

Copy the two response `productID` values into `POSITIVE_PRODUCT_ID` and `NEGATIVE_PRODUCT_ID`; each public request allocates a new identity.

For each product ID, read the canonical API product and geometry:

```bash
PRODUCT_ID="$POSITIVE_PRODUCT_ID"
curl --silent --show-error \
  "$API_BASE/v1/mesos?id=${PRODUCT_ID}"

PRODUCT_ID="$NEGATIVE_PRODUCT_ID"
curl --silent --show-error \
  "$API_BASE/v1/mesos?id=${PRODUCT_ID}"
```

Expect a `TEST` title, synthetic source URL, short validity window, and non-empty polygon coordinates. For the positive case, the canonical geometry's stored resolution-8 H3 cover must contain `POSITIVE_H3`; for the negative case, it must contain `NEGATIVE_H3`. The endpoint validates this before returning acceptance.

## Evidence matrix

Use the same product ID to correlate all server evidence. The operator dashboard at `/dashboard/mesos` confirms canonical active products and `/dashboard/delivery` exposes aggregate delivery activity. Dashboard totals are contextual; the SQL below provides product-specific evidence. The worker's existing logs can show a queue handoff error or send failure, but a log line or queue enqueue alone does not prove delivery.

```sql
-- Canonical identity, validity, source, and stored H3 cover.
SELECT s.product_key, s.source_url, s.valid_start, s.valid_end,
       g.h3_resolution, g.h3_cells
FROM spc_mesos AS s
JOIN spc_meso_geolocation AS g ON g.meso_id = s.id
WHERE s.product_key = '<PRODUCT_ID>';

-- Durable event-first handoff state; done means the send job was enqueued.
SELECT subject_kind, subject_id, subject_revision_id, state, attempts,
       available_at, last_error
FROM notification_outbox
WHERE subject_kind = 'spc-meso' AND subject_id = '<PRODUCT_ID>';

-- Candidate resolution, atomic claims, and APNs outcomes recorded by the job.
SELECT outcome, no_op_reason, candidate_resolution_reached, candidate_count,
       claimed_count, sent_count, failed_count, attempted_at
FROM notification_send_attempts
WHERE subject_kind = 'spc-meso' AND subject_id = '<PRODUCT_ID>'
ORDER BY attempted_at;

-- Per-installation claim and APNs completion status; no token is selected.
SELECT subject_id, installation_id, status, apns_error_code, created, completed_at
FROM notification_ledger
WHERE subject_kind = 'spc-meso' AND subject_id = '<PRODUCT_ID>'
ORDER BY created;

-- TEST copy associated with a candidate or a zero-candidate preview.
SELECT subject_id, installation_id, record_kind, title, subtitle, body, created
FROM notification_debug
WHERE subject_kind = 'spc-meso' AND subject_id = '<PRODUCT_ID>'
ORDER BY created;
```

Record the observations independently:

| Boundary | Positive case | Safely distant negative case |
| --- | --- | --- |
| Request accepted | `202`; record product ID and timestamp | `202`; record product ID and timestamp |
| Canonical read | Product and polygon returned; H3 cover contains device cell | Product and polygon returned; cover does not overlap device cell |
| Candidate resolution | `candidate_count = 1` for the single registered test device | `candidate_count = 0`; `no_op_reason = 'zero_candidates'` |
| Outbox and queue | One `spc-meso` intent; `state = 'done'` after send queue handoff | Intent may also reach `done`; this alone is not a candidate or send |
| Ledger claim | Exactly one row for the test installation and product ID | No ledger row for the test installation and product ID |
| APNs result | Record the ledger result: `status = 'sent'` means APNs accepted the request; `failed` or `retrying` plus `apns_error_code` records a server-side failure | A diagnostic attempt row records `candidate_count = 0`; zero claims and zero APNs sends (`sent_count = 0`, `failed_count = 0`, no ledger row) |
| Physical device | Record receipt time and that the notification opens this exact TEST product | Observe no notification for a bounded 5-minute interval after worker processing completes |

Run the negative request after the positive one and record its own product ID. Do not infer device receipt from HTTP `202`, outbox `done`, a queue record, APNs acceptance, or dashboard aggregate counts. The positive tap must open `/v1/mesos?id=<that product ID>` in the app and show the matching synthetic TEST discussion.

The normal negative run proves nonmatching H3 behavior. Preference, capability, subscription, stale-presence, and rollout-gate exclusions are covered deterministically by `MesoNotificationTestControllerTests` and `MesoEventNotificationTests`; keep the single registered iPhone's settings unchanged during the physical run. The event-first suite specifically covers unknown capability, opt-out, denied location authority, wrong resolution, inactive and unsubscribed installations, and nonmatching H3. These cases should not be simulated by editing the only device's production-like registration row.

For a live gate-off check, temporarily set `MESO_NOTIFICATIONS_ENABLED=false` on both development processes, then submit one valid request using the same registered installation and positive H3. Expect `202 Accepted` with `notificationStatus: "disabled"`; the canonical TEST product should exist, but no `notification_outbox`, ledger, debug candidate, or send-attempt row should exist for its returned product ID. Re-enable the gate on both processes before the positive/negative delivery run, or leave it disabled as part of final rollback. The focused tests also verify this path without requiring a live delivery.

## Same-identity replay and dedupe

The public endpoint always allocates a new synthetic product identity, so sending the HTTP request twice is not a replay test. To verify dedupe without adding a public request parameter, replay the existing product's outbox intent only in the isolated development database, after the first positive send has completed. This routes the same `(spc-meso, productID, initial)` identity through the ordinary scheduled outbox drain and send job; never call an APNs sender directly.

First confirm the product has one sent ledger row and the outbox is `done`. Then re-arm only that completed synthetic row:

```sql
UPDATE notification_outbox
SET state = 'ready', attempts = 0, available_at = NOW(), last_error = NULL, updated = NOW()
WHERE subject_kind = 'spc-meso'
  AND subject_id = '<POSITIVE_PRODUCT_ID>'
  AND subject_revision_id = 'initial'
  AND mode = 'h3'
  AND state = 'done'
RETURNING subject_id, state, attempts;
```

Require exactly one returned row, then wait for the existing worker's scheduled meso outbox drain. The subsequent send attempt should record `all_candidates_previously_claimed`; the ledger must still contain exactly one row and APNs attempt count for that product must remain one. If the SQL returns no row or more than one row, stop and inspect the deployment before proceeding.

## Rollback and expiry

Immediately after the evidence window, set `MESO_NOTIFICATIONS_ENABLED=false` on API and worker and disable the test endpoint flag on the API. Remove the endpoint bearer secret from the deployment environment and secret exposure surface. Confirm the route rejects requests and the worker no longer drains meso intents. Preserve the private evidence record without credentials or device tokens.

Synthetic products are valid for 15 minutes so the tap/open path can be checked. Their canonical rows remain for a 24-hour retention window; later synthetic requests lazily remove older expired test products, while retaining the newest current-year identity as a dedupe/allocation watermark. Expiry prevents further sends and display as active weather; it does not immediately delete the product. Do not manually delete notification ledger or outbox history. If immediate data removal is required, use the repository's reviewed retention operation in a separate approved maintenance task.

## Record the result

Record the build/deployment revision, test date/time in UTC, the two product IDs, whether each request was accepted, canonical API and H3-cover results, candidate/claim/queue/APNs observations, bounded negative observation interval, and physical positive receipt/tap outcome. Keep installation IDs in the private operational record. State explicitly whether any observation is missing or blocked by device, APNs, or deployment configuration. CI, mocks, and server acceptance cannot substitute for the physical iPhone result.
