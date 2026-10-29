# Architectural convergence and production meso runbook

Status: deployment completed; readiness and rollout acceptance remain incomplete, 2026-10-29. Campaign: [#397](https://github.com/justinrooks/arcus-signal/issues/397). GitHub issue state and native dependencies are authoritative; see the [progress ledger](architectural-convergence-progress.md) for the operator-supplied v1.5.0 deployment evidence and its limits.

## Outcome and authority

Complete the bounded corrections from the integration review of #375 and #382, then execute production meso cutover through existing owner [#289](https://github.com/justinrooks/arcus-signal/issues/289). Preserve installation authority, monotonic consent, accepted presence, durable outbox recovery and the per-installation delivery-claim boundary.

Read the current issue, repository AGENTS.md and docs/architecture.md before implementation. Use the accepted shared contract and current dependency pin. docs/epics-stories.md remains historical planning, not an exactly-once delivery contract. The reviewed source baseline is `5df90b54ff2791626d4ab79d5d58fa0611bc9780`; reverify the affected code before implementation.

Justin approved the production meso cutover direction on 2026-10-29. Do not request that same approval again. Technical readiness, an explicitly selected release, and controlled device evidence remain necessary. This planning campaign does not itself deploy, restart services, send notifications or retire v1.

## Execution order

| Issue | Responsibility | Completion evidence |
| --- | --- | --- |
| [#391](https://github.com/justinrooks/arcus-signal/issues/391) | Require usable accepted presence before v3 meso ownership acknowledgment | Focused deterministic presence/consent tests and reviewed server correction |
| [#398](https://github.com/justinrooks/arcus-signal/issues/398) | Align coverage eligibility counts with accepted sharing consent | Opt-out/re-enable regression; denominator and candidate-query semantics preserved |
| [#399](https://github.com/justinrooks/arcus-signal/issues/399) | Validate explicit expected meso state throughout release tooling | Mocked off/on transitions, parity, missing/invalid states and legacy-record behavior |
| [#400](https://github.com/justinrooks/arcus-signal/issues/400) | Verify integrated deployment readiness | Exact release/client identities, test and operational evidence, bounded Ready/Not ready verdict |
| [#289](https://github.com/justinrooks/arcus-signal/issues/289) | Enable production meso for cutover-ready clients | Enabled gate parity, controlled receipt/open, duplicate-prevention, observation and rollback evidence |

#391, #398 and #399 were independent correction slices and are now closed, merged and deployed in v1.5.0. The original dependency order was corrections → #400 readiness → #289 rollout acceptance. The operator reports production meso gates already enabled with a true→true v1.5.0 deployment; #400 and #289 remain open for their outstanding evidence, rather than describing deployment as pending. #391/#398/#399/#400 are native children of #397. #289 keeps its native parent #274.

## Implementation and validation

Use Issue Lifecycle Orchestrator for one correction at a time. Keep each change within its issue acceptance criteria and reviewable file budget; do not bundle consent, targeting and release refactors. Preferred implementation effort is Sol/high for #391 and #399, Sol/medium for #398. Require independent review of ownership and release-state changes.

Run focused Swift database lanes through tools/test_lane.sh with an issue-scoped disposable database and explicit DATABASE_URL/DATABASE_NAME. Release tests must use the mocked harness in a supported environment. Do not treat missing tooling, a stalled lane or historical CI as a newly passed test. Preserve inspectable evidence.

The coverage correction changes eligibility numerators, not the active-subscribed denominator or the deliberate distinction between candidate-query eligibility and later delivery policy. The ownership correction reuses accepted presence/freshness authority. Neither creates a second eligibility policy.

The release correction carries one explicitly selected expected gate through preflight, install and observation. Validate the baseline separately from the target transition. Preserve strict API/worker parity, missing/invalid-state rejection, image identity and backup/migration guards. Do not infer authorization from an already-enabled running process or globally change the default gate.

## Readiness and cutover

#400 records exact Signal tag/commit/images, shared contract, client build and evidence timestamps. Resolve material uncertainties rather than treating merged PRs as deployment proof. Current ingestion/recovery freshness and legitimate zero-work states matter; /health alone is insufficient. The v1.5.0 deployment and healthy 12-minute observation are recorded in the progress ledger. Remaining boundaries are the #378 access disposition, detailed handoff classifications and controlled-client evidence. The identified recovery→opt-out→worker composition test remains unexecuted; #400 records this bounded follow-up without manufacturing runtime implementation work.

#289 executes the normal release/config path with the selected version and consistent API/worker MESO_NOTIFICATIONS_ENABLED state. Production remains limited to capable, opted-in installations meeting authoritative current consent and presence gates. Do not use the development-only meso test endpoint in production or record real device secrets in artifacts.

Select the gate durably in the deployment `.env`; CLI expectations validate configuration and do not rewrite it. An approved off→on deployment uses `./install <tag> --baseline-meso-gate false --expected-meso-gate true`; an already-enabled baseline uses true/true. The completed v1.5.0 deployment used true/true. Preserve legacy device writes at their default enabled state; meso receiving capability does not require adoption of the newest client write protocol. Do not infer client eligibility from an app-version comparison.

Separate durable claims, APNs attempts, provider acceptance and actual device receipt/open in the evidence. Never claim exactly-once external delivery. Gate-off rollback requires a concrete config procedure and controlled-client ownership-refresh evidence; a disabled server gate alone does not prove local delivery has resumed.

For gate-off rollback, retain the compatible v1.5.0 image, set `MESO_NOTIFICATIONS_ENABLED=false` in the deployment `.env`, and use `./install v1.5.0 --baseline-meso-gate true --expected-meso-gate false` through the normal authorized workflow. Observe the completed deployment record and verify API/worker parity. Refresh ownership on the controlled client and verify the intended local behavior. This is a documented procedure, not evidence that rollback was performed or authorization to execute it now; do not downgrade to a pre-authority server binary or erase credential/consent state.

## Retained owners and stop condition

[#378](https://github.com/justinrooks/arcus-signal/issues/378) owns operator authorization. Readiness needs a factual deployed-boundary disposition, not an assumption of either protection or exposure. Do not duplicate or reparent that work. [#387](https://github.com/justinrooks/arcus-signal/issues/387) owns separately approved v1 retirement; meso cutover approval does not authorize retirement.

Stop when the bounded corrections and readiness evidence are complete and #289 satisfies production acceptance. Do not expand into another broad security, reliability or client architecture campaign. The epic remains open until the linked cutover evidence exists, even if all its native children are closed.
