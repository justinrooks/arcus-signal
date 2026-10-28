# Installation enrollment and authenticated device writes

Signal #386 adopts ArcusCore **0.6.0**, revision `d648e2c91c687511daf9a1f7cecaf9c52b283713`, and its `InstallationEnrollmentRequest` and `InstallationEnrollmentAcceptedResponse`. The owner-approved contract is tracked in Signal #377 and ArcusCore #10. Client integration belongs to SkyAware #796; consent ordering remains Signal #379; legacy retirement belongs to Signal #387.

## Wire contract

Use HTTPS for all enrollment and device writes. The deployment's TLS terminator owns HTTPS enforcement; do not expose the internal HTTP listener directly to clients. Neither credentials nor Authorization headers may be included in proxy/application request-body or header logging.

`POST /v2/devices/enroll` accepts `installationId` (UUID string) and `credential` (base64url encoding of 32 cryptographically random bytes). Canonical unpadded encoding and its single trailing `=` padding are accepted and bind the same decoded credential. SkyAware generates and persists the secret in Keychain before its first request and retries the same credential after a lost acknowledgment. New UUIDs, first claims of unclaimed legacy UUIDs, and same-credential retries return HTTP 200 with `{"status":"accepted"}`. Malformed requests return 400; an existing claim with a different credential returns 409. Enrollment does not require an APNs token or notification permission.

The protected routes are `POST /v2/devices/location-snapshots`, `POST /v2/devices/preferences`, and `POST /v2/devices/foreground-activity`. Each requires `Authorization: Bearer <credential>` for the installation UUID in the existing payload. Missing, malformed, wrong-owner, or unregistered credentials return 401. Payloads and successful responses retain their existing device-write contracts (foreground activity returns 204). Every route is also available under `/api/v2`.

## Persistence and compatibility boundary

The additive `CreateInstallationCredentials` migration creates `installation_credentials`, keyed uniquely by UUID, containing only a SHA-256 verifier of the decoded 256-bit secret. It deliberately has no device-installation foreign key: enrollment establishes authority without creating delivery state or activity facts. Enrollment does not modify existing APNs bindings, consent, presence, reconciliation intents, or notification ledger state. A second secret cannot replace a claim; rotation and recovery are deferred.

Enrollment and all v1/v2 device mutations take the same transaction-scoped PostgreSQL advisory lock derived from the canonical UUID. Authorization and mutation use that transaction's connection. This serializes first claims even for UUIDs without rows and prevents a legacy write from passing authorization before a concurrent claim and committing afterward. Rejected writes cannot change presence, installation metadata, daily activity, or reconciliation intent state. Reconciliation handoff retains its existing post-commit behavior.

Legacy `/v1/devices/...` and `/api/v1/devices/...` writes are accepted only for unclaimed UUIDs while `DEVICE_LEGACY_WRITES_ENABLED=true` (default). Claimed UUIDs always return 401 on v1, including when a bearer credential is supplied; clients must use v2 after enrollment. `DEVICE_LEGACY_WRITES_ENABLED=false` disables all legacy device mutations while retaining enrollment and authenticated v2 routes. Other values fail API startup. Startup logs identify the selected compatibility state. The setting is read from the API process environment; an operator using Compose must pass it into that container explicitly. No fixed retirement date is implied.

The approved temporary legacy first claim uses possession of the UUID alone, without proof of historical ownership or APNs matching. This accepted trust-on-first-use risk remains until the separately approved retirement step. Enrollment remains available when legacy writes are disabled.

## Deployment order and recovery

1. Publish Core 0.6.0 (complete), then build and deploy compatible Signal before releasing SkyAware v2.
2. Apply the additive migration before serving this API version. Keep legacy compatibility enabled for the initial overlap. Replace/drain **all old API processes** before enabling client enrollment: old binaries do not enforce the new credential boundary. A mixed old/new API fleet is unsafe once claims are possible.
3. Verify enrollment/retry status, protected writes, alias parity, and rejection of v1 writes after claim in a non-production environment. Release the Keychain-persisting client only after the server fleet is compatible. No deployment is performed by this change.
4. Observe the overlap before separately authorizing #387. Disable legacy writes only as an explicit rollout decision; preserve credential records permanently across ordinary releases and backups.

After any credential is claimed, rolling back to an API binary that predates this boundary reopens unauthenticated writes. Recover by rolling forward or by keeping device writes unavailable until a compatible binary is restored. Do not revert/drop the credential migration or erase verifier records as a routine rollback. The migration refuses to revert while any credential rows exist. Empty-table reversal remains available for pre-rollout/test environments; its emptiness check and drop share an exclusive table lock and transaction to prevent concurrent enrollment from losing authority.
