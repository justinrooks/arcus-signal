# Pressure Artifact Warm Reliability Runbook

**Status:** Active

**Applies to:** HRRR pressure-artifact acquisition and `model-artifacts` queue recovery

**Project:** Arcus Signal

**Parent epic:** [#190](https://github.com/justinrooks/arcus-signal/issues/190)

## Related documents

- `AGENTS.md`
- `docs/architecture.md`
- `docs/plans/hrrr-pressure-artifact-warmer-runbook.md`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`
- `docs/plans/pressure-artifact-warm-reliability-progress.md`

## Purpose

Make pressure-artifact warming bounded and self-recovering after stalled HTTP reads or worker termination. The campaign is grounded in the 2026-08-04 incident where one warm job fetched its IDX, selected 185 byte ranges, then stopped before cache completion for more than four hours. With one `model-artifacts` consumer, 28 later jobs accumulated while five catalog rows remained `pending`.

Each child issue is one review unit and normally one pull request. Implement the current issue, run its focused validation, update the progress ledger, and stop.

## Source-of-truth order

1. `AGENTS.md`
2. `docs/architecture.md`
3. This runbook
4. `docs/plans/pressure-artifact-warm-reliability-progress.md`
5. The current GitHub issue
6. Current production code and focused tests

Historical warmer planning remains useful context, but current code and this reliability contract govern timeout, retry, and recovery behavior.

## Required read order

1. Read `AGENTS.md` and `docs/architecture.md`.
2. Read this runbook.
3. Read only the current issue entry in the progress ledger.
4. Read the current GitHub issue.
5. Inspect only the named production and test files.

## Minimal prompt contract

```text
Implement arcus-signal GitHub issue #NN.

Read:
- docs/plans/pressure-artifact-warm-reliability-runbook.md
- the current issue entry in docs/plans/pressure-artifact-warm-reliability-progress.md
- the GitHub issue body

Work only that issue. Preserve request-path degradation and pressure catalog fencing, run the focused verification, update the current progress entry, and stop.
```

## Target reliability contract

- Every IDX and GRIB byte-range request has an explicit, positive deadline.
- A complete warm attempt has a deadline shorter than its catalog lease.
- A timed-out owner releases execution capacity and leaves a deterministic, recoverable catalog state.
- External task cancellation retains the existing fenced-lease behavior unless an issue explicitly changes and tests it.
- Only transient acquisition failures receive bounded retries and backoff; deterministic selection and validation failures do not.
- Worker startup safely recovers abandoned `model-artifacts` processing entries before consumers start.
- Recovery is restricted to known model-artifact jobs and is idempotent.
- The dashboard identifies expired warming leases and growing pending backlogs without exposing claim tokens or local paths.

## Required guardrails

- Preserve API/worker runtime ownership and the dedicated `model-artifacts` lane.
- Preserve exact artifact identity, field-set version, 185-message selection, cache layout, and validation.
- Preserve claim-token fencing for ready and failed completion.
- Keep the normal Storm Setup request path read-only with respect to cold acquisition.
- Keep all timeout and retry values explicit, positive, environment-configurable, and covered by configuration tests.
- Use deterministic stubs or local test infrastructure; never require live NOAA traffic.
- Keep queue recovery atomic and run it before model-artifact consumers start.
- Log counts and job identifiers, but never log Redis credentials, claim tokens, local paths, or payload bodies.

## Forbidden scope

- Increasing `QUEUE_WORKER_COUNT` as the correctness fix.
- Changing pressure levels, variables, product identity, or field-set version.
- Moving acquisition into request handlers or Arcus-Anvil.
- Redesigning all Vapor queue lanes or notification retry policy.
- Deleting arbitrary Redis processing entries or flushing Redis.
- Changing APNs, NWS ingest, targeting, or notification delivery behavior.
- Adding a new third-party dependency when the existing Vapor/Redis stack can provide the needed behavior.

## Current boundaries to preserve

| Concern | Current owner |
|---|---|
| Probe and dispatch | `HRRRPressureArtifactProbeService` |
| Warm orchestration | `PressureArtifactWarmingService`, `PressureArtifactWarmJob` |
| Range acquisition | `HrrrPressureByteRangeDownloader`, `VaporApplicationHTTPClient` |
| Catalog fencing | `PressureArtifactCatalogStore` |
| Worker lifecycle | `WorkerRuntime`, `configure.swift` |
| Dashboard metrics | `OperatorDashboardSnapshotRefresher`, dashboard snapshot DTO/renderer |

## Sequential execution

1. Add explicit per-request acquisition deadlines.
2. Bound the whole warm attempt and define timeout catalog completion.
3. Add bounded retry/backoff for transient warm failures.
4. Characterize abandoned Redis processing behavior without production mutation.
5. Recover abandoned model-artifact processing entries at worker startup.
6. Surface stuck warming and pending backlog health on the dashboard.

Issues 02–03 depend on 01. Issue 05 depends on 04. Issue 06 should follow 02 so its stuck threshold matches the implemented deadline contract.

## Verification defaults

- Run the focused test filters named by the current issue.
- Use controllable stubs for never-completing and transient HTTP behavior.
- For Redis recovery, use the existing local Redis integration boundary and unique test keys; never mutate shared queue keys.
- Run strict-concurrency build checks for timeout, task-group, worker-lifecycle, or Redis recovery changes.
- Run `git diff --check` scoped to the issue files.
- Do not run live HRRR downloads as acceptance tests.

## Quality bar

- One behavior change per issue and pull request.
- Prefer 1–3 production files and under roughly 200 changed lines when practical.
- Make timeout ownership and error classification explicit; do not hide them in generic helpers.
- Tests must prove execution capacity is released, not merely that an error value exists.
- Queue recovery requires atomicity, idempotency, and unknown-job preservation tests.
- A `5.4 mini medium` implementer must be able to complete the slice from the issue and named documents without repository-wide exploration.
