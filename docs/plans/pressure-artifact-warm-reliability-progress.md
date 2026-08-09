# Pressure Artifact Warm Reliability Progress

## Overview

This ledger tracks the bounded-execution and queue-recovery campaign defined by `docs/plans/pressure-artifact-warm-reliability-runbook.md`.

**Epic status:** Active

**Primary GitHub epic:** [#190](https://github.com/justinrooks/arcus-signal/issues/190)

## Global decisions

- Fix the single-consumer stall rather than masking it with more workers.
- Apply both per-request and whole-attempt deadlines.
- Keep the whole-attempt deadline below the catalog lease duration.
- Treat timeout as a deterministic owned failure; preserve external cancellation semantics.
- Retry only classified transient acquisition failures with a bounded attempt count.
- Characterize Redis processing recovery before implementing startup mutation.
- Keep operational dashboard work separate from execution behavior.
- Target `5.4 mini medium` with one sequential review unit per issue.

## Current state summary

- On 2026-08-04, job `C23BBB70-4C90-495A-9A62-85AB4A70873A` claimed the `2026-08-04T08:00Z/FH3` artifact at `11:45:28Z`.
- It fetched a 711-line IDX and selected 185 pressure ranges, but never logged cache preparation, validation, completion, or failure.
- Network failures began minutes earlier and affected other worker HTTP traffic.
- The production HTTP wrapper set no GET deadline; AsyncHTTPClient therefore had no read timeout.
- The only `model-artifacts` consumer remained occupied for more than four hours.
- Redis showed one processing job and 28 waiting jobs; the database showed one expired `warming` lease and five `pending` artifacts.
- Restarting the worker released execution capacity and the queue began draining.
- Focused probe, downloader, and warm-job tests passed, but none modeled a never-completing HTTP read or worker restart with an abandoned processing entry.

## Existing code map

| Behavior | Files |
|---|---|
| HTTP abstraction and Vapor client | `Sources/App/Infrastructure/Networking/HTTPDataDownloader.swift` |
| Range loop | `Sources/App/StormSetup/HrrrPressureByteRangeDownloader.swift` |
| Warm lifecycle | `Sources/App/StormSetup/PressureArtifactWarmingService.swift` |
| Queue job | `Sources/App/Jobs/PressureArtifactWarmJob.swift` |
| Probe dispatch | `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift` |
| Catalog transitions | `Sources/App/Models/Data/PressureArtifactCatalogStore.swift` |
| Worker startup | `Sources/App/Worker/WorkerRuntime.swift`, `Sources/App/configure.swift` |
| Dashboard | `Sources/App/lib/OperatorDashboardSnapshotRefresher.swift`, dashboard DTO/renderer |

## Issue sequence

| Seq. | GitHub issue | Title | Dependencies | Status |
|---:|---|---|---|---|
| 01 | [#191](https://github.com/justinrooks/arcus-signal/issues/191) | Add pressure-artifact HTTP request deadlines | None | Pending |
| 02 | [#192](https://github.com/justinrooks/arcus-signal/issues/192) | Bound warm attempts and complete timed-out claims | 01 | Pending |
| 03 | [#193](https://github.com/justinrooks/arcus-signal/issues/193) | Retry transient warm failures with bounded backoff | 01, 02 | Pending |
| 04 | [#194](https://github.com/justinrooks/arcus-signal/issues/194) | Characterize abandoned model-artifact processing jobs | None | Pending |
| 05 | [#195](https://github.com/justinrooks/arcus-signal/issues/195) | Recover abandoned model-artifact jobs at worker startup | 04 | Pending |
| 06 | [#196](https://github.com/justinrooks/arcus-signal/issues/196) | Surface stuck pressure-artifact backlog health | 02 | Pending |
| 07 | [#201](https://github.com/justinrooks/arcus-signal/issues/201) | Add durable fenced failure-completion retries | 01, 02 | Implemented — ready for publication |

## Investigation notes

- A healthy 185-range warm immediately before the incident downloaded approximately 124 MB in 21 seconds.
- The stuck attempt crossed IDX parsing and range planning, narrowing the stall to cache load/fetch work, overwhelmingly the unbounded range GET path given concurrent network failures.
- The recovery lease is a database ownership fence, not an execution deadline. Expiry cannot cancel a running task or free a queue consumer.
- Stale probes can enqueue additional work while the consumer is blocked, creating duplicate backlog pressure.
- The installed Redis queue driver moves jobs into `vapor_queues[model-artifacts]-processing`; interrupted processing entries are not automatically returned to the waiting list.

## Status ledger

### Issue #191 - 01: Add pressure-artifact HTTP request deadlines

- **Status:** Pending
- **Goal:** Give IDX and range GET operations explicit positive deadlines without changing unrelated HTTP callers.
- **Likely files:** HTTP wrapper, Storm Setup configuration, range downloader/warming service, focused configuration/downloader tests.
- **Stop condition:** A never-completing pressure GET fails within the configured bound and focused tests prove timeout propagation.

### Issue #192 - 02: Bound warm attempts and complete timed-out claims

- **Status:** Pending
- **Goal:** Enforce an overall warm deadline shorter than the lease and mark the owned row failed on timeout while preserving external cancellation behavior.
- **Likely files:** warming service, catalog store only if a named timeout transition is needed, warm-job tests.
- **Stop condition:** A stalled attempt releases the job, clears its owned claim, and records a concise timeout failure.

### Issue #193 - 03: Retry transient warm failures with bounded backoff

- **Status:** Pending
- **Goal:** Retry only classified transport/timeouts with a small bounded count and deterministic backoff.
- **Likely files:** warm job, probe dispatcher, warming error classification, focused queue tests.
- **Stop condition:** Transient failures retry and can succeed; validation/selection failures remain non-retryable; no unbounded duplicate dispatch is introduced.

### Issue #194 - 04: Characterize abandoned model-artifact processing jobs

- **Status:** In progress — awaiting human review
- **Goal:** Add tests and a narrow recovery seam that describe current Redis waiting/processing/job-data behavior without mutating production startup.
- **Likely files:** new model-artifact queue recovery type/protocol and focused tests; no production lifecycle wiring.
- **Stop condition:** Tests pin valid, missing-data, unknown-job, duplicate, and already-waiting cases using isolated Redis keys.
- **Recovery transition for Issue #195:** In one Redis script, inspect each `vapor_queues[model-artifacts]-processing` entry. Preserve and report entries with malformed identifiers, missing or malformed job data, or unknown job names. For known warm, failure-completion, and cleanup jobs, add the identifier to `vapor_queues[model-artifacts]` only when absent, then remove all matching processing entries. The script must keep that check/add/remove sequence atomic so recovery cannot create a second waiting membership.

### Issue #195 - 05: Recover abandoned model-artifact jobs at worker startup

- **Status:** Pending
- **Goal:** Atomically return known abandoned model-artifact jobs to the waiting queue before consumers start.
- **Likely files:** recovery implementation, worker lifecycle/configuration, characterization tests.
- **Stop condition:** Restart recovery is idempotent, preserves unknown entries, avoids duplicate list membership, logs a summary, and starts consumers only after reconciliation.

### Issue #196 - 06: Surface stuck pressure-artifact backlog health

- **Status:** Pending
- **Goal:** Show expired warming leases, pending count, and oldest actionable age in dashboard JSON and HTML.
- **Likely files:** dashboard snapshot metric/refresher, response DTO/renderer, dashboard pressure-artifact tests.
- **Stop condition:** Operators can distinguish unavailable source data from a stuck warm pipeline without seeing claim tokens, Redis payloads, or local paths.

### Issue #201 - 07: Add durable fenced failure-completion retries

- **Status:** Implemented — ready for publication
- **Behavior:** A thrown owned `markFailed` write dispatches a pressure-specific completion payload containing only artifact identity, the original claim token, and a bounded sanitized summary. The job reuses the existing fenced store transition and treats stale tokens as successful no-ops.
- **Retry contract:** The first completion attempt is immediate. Vapor Queues owns up to three configured delayed retries on `model-artifacts`, defaulting to 15, 60, and 300 seconds.
- **Exhaustion:** The completion job records explicit queue/log failure, leaves the warming claim and lease unchanged, and relies on the existing lease/probe recovery path.
- **Review:** Human review completed. Independent defect and test audits reached `READY` after path-safe queue errors, configurable retry policy, and canonical documentation were verified.
- **Sequencing:** Land this issue before resuming #193. Add the completion job name to #195's known model-artifact recovery set when that work begins.
- **Focused verification:** `swift test --filter PressureArtifactFailureCompletionJobTests`; `swift test --filter PressureArtifactWarmJobTests`; `swift test --filter StormSetupConfigurationTests`; `swift test --filter PressureArtifactDiagnosticsTests`; strict-concurrency build; `git diff --check`.

## Verification ledger

| Issue | Required focused verification | Result |
|---|---|---|
| 01 | `swift test --filter HrrrPressureByteRangeDownloaderTests`; `swift test --filter StormSetupConfigurationTests` | Pending |
| 02 | `swift test --filter PressureArtifactWarmJobTests`; `swift test --filter PressureArtifactDiagnosticsTests` | Pending |
| 03 | Focused warm-job retry tests; probe dispatch tests | Pending |
| 04 | Focused model-artifact queue recovery characterization tests | Pending |
| 05 | Recovery tests plus worker bootstrap tests and strict-concurrency build | Pending |
| 06 | `swift test --filter OperatorDashboardPressureArtifactTests` | Pending |
| 07 | Completion-job queue/PostgreSQL tests; warm and diagnostics regressions; strict-concurrency build | Passed |

## Handoff notes

- Execute issues sequentially unless dependencies explicitly allow otherwise.
- Update only the active issue entry with files, behavior, validation, risks, and next handoff.
- Do not manually generalize this campaign to ingest, target, send, or notification retry behavior.
- If Redis recovery cannot be implemented without relying on unstable driver internals, stop after Issue 04 and document the supported alternative before changing dependencies or queue topology.
