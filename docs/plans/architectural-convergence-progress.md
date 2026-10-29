# Architectural convergence progress

Reconciled snapshot: 2026-10-29, after Signal v1.5.0 deployment. Epic: [#397](https://github.com/justinrooks/arcus-signal/issues/397). [Runbook](architectural-convergence-runbook.md). GitHub issues remain authoritative; deployment outcomes below are operator-supplied evidence, with independent source verification identified separately.

## Original planning context

- Reviewed Signal baseline: `5df90b54ff2791626d4ab79d5d58fa0611bc9780`.
- Completed implementation reviewed: #386 / PR #388, #389 / PR #390, #383 / PR #394, #384 / PR #395, #385 / PR #396; coordinating #377 and #379.
- New reporting defect: coverage eligibility counts omit accepted sharing consent, while delivery candidates enforce it. No unauthorized-delivery claim follows from this reporting defect.
- Existing #391 owns premature v3 meso ownership before usable accepted presence; no duplicate issue was created.
- Cutover planning found preflight, installer and release snapshots hard-code meso=false. #399 owns replacing that historical policy with explicit expected-state validation while preserving fail-closed checks.
- Justin approved production meso enablement direction on 2026-10-29. Exact deployment and device readiness remain unverified. No production state was changed during planning.
- #378 remains the operator-authorization owner; #387 remains separately gated v1 retirement. #289 remains under #274 and owns production cutover.

## Execution snapshot

| Issue | Reconciled state | Depends on | Evidence / remaining work |
| --- | --- | --- | --- |
| [#391](https://github.com/justinrooks/arcus-signal/issues/391) | Closed; deployed in v1.5.0 | None added | [PR #401](https://github.com/justinrooks/arcus-signal/pull/401), merge `3b69ae2248e13023e0547b2a749fcc07ecdd554e`; 55 tests / five suites passed |
| [#398](https://github.com/justinrooks/arcus-signal/issues/398) | Closed; deployed in v1.5.0 | None | [PR #402](https://github.com/justinrooks/arcus-signal/pull/402), merge `31eed26649e3f1322e523c6b94b797adff1cf7ea`; six tests passed |
| [#399](https://github.com/justinrooks/arcus-signal/issues/399) | Closed; deployed in v1.5.0 | None | [PR #403](https://github.com/justinrooks/arcus-signal/pull/403), merge `c4f5ee20d456d4dd7c3152229003b13b1d046df2`; 40 mocked release and six pin tests passed; two real Compose checks skipped |
| [#400](https://github.com/justinrooks/arcus-signal/issues/400) | Open; readiness reconciliation incomplete | Corrective prerequisites satisfied | Deployment identity and observation recorded; access disposition, detailed handoff classifications and exact controlled-client evidence remain |
| [#289](https://github.com/justinrooks/arcus-signal/issues/289) | Open; production gate enabled, acceptance incomplete | #400 plus existing rollout criteria | Controlled production receipt/open, no local/remote duplicate, dashboard acceptance evidence and gate-off client ownership recovery remain |

The four correction/readiness issues are native children of #397. Dependencies are native GitHub relationships, not just prose. The linked rollout #289 keeps parent #274. Do not close #397 merely because its native children are complete.

## Deployment and observation evidence

The [reconciled #400 record](https://github.com/justinrooks/arcus-signal/issues/400#issuecomment-6506791043) and [#289 deployment handoff](https://github.com/justinrooks/arcus-signal/issues/289#issuecomment-6506804352) supersede the earlier planning assumption that deployment and gate enablement were still pending. Justin requested meso enabled in the next production deployment and attested successful synthetic/pushed-event reception in SkyAware 1.5.0 TestFlight. Meso receiving capability is separate from authenticated v3 write adoption; no new v3-only receiving prerequisite was imposed.

| Identity | Recorded value |
| --- | --- |
| Signal release / previous release | [v1.5.0](https://github.com/justinrooks/arcus-signal/releases/tag/v1.5.0) / v1.4.2 |
| Commit / OCI revision | `0b3be5b8df2974dc0cfb94ee47a6fe723be651bd` |
| API and worker image ID | `sha256:1767116448a17b2ab6aa64d53f156826a699a7ee600ea128c0cb8aa52d8e7340` |
| Registry digest | `sha256:bec24f55b829e91775bed30426e556c81e348f6319c6957d5d870afa2d81a77f` |
| Shared contract | ArcusCore 0.7.0 / `4b8cd2db056cbda14303d6165bf9b73bea4d48c6` |
| Durable image selection | `persistedTag=v1.5.0`; independent Compose resolution selected v1.5.0 for API and worker |
| API/worker meso gates | `true→true`, matching running baseline and durable target; this deployment was not an off→on transition |

The operator reports a fresh PostgreSQL backup with archive readability verified, completed migrations, and successful packaged-binary, notification-schema, image-identity, HTTP-health and saved-configuration checks. Backup readability does not establish a tested restore. The annotated release tag, prerequisite ancestry and contract pin were independently verified through GitHub/local Git; host runtime records were supplied by Justin and were not opened directly in this verification session.

The complete observation sampled **19:19:34 / 19:21:34 / 19:26:34 / 19:31:34 UTC on 2026-10-29**, offsets 0/120/420/720 seconds. Collection, metrics freshness, backlog freshness and infrastructure checks passed at every sample; pending target dispatches, pending notification dispatches and stuck claims remained zero, including baseline. NWS remained healthy. SPC developed an age-only warning at 420 seconds, then recovered by the final sample following successful ingestion at **19:29:26Z**. Retain the recovered finding; no unresolved observation findings remained.

Post-deployment APNs evidence was **zero successful, zero failed and zero ambiguous completions**. Delivery confidence is **unobserved**. The healthy quiet window establishes no device receipt/open or duplicate-prevention outcome.

Host-local artifact references: `/tmp/arcus-release-v1.5.0.WyKxxKFF/deployment.json` and `/tmp/arcus-release-v1.5.0.WyKxxKFF/observation.ZLv6POMT/observation.json`. These records were not attached or retrieved here; preserve sanitized evidence durably for later inspection.

## Validation and remaining evidence

The source audit found no additional authentication/consent, NWS recovery or delivery-claim defect requiring a separate story. Audit execution included eight standalone collection-decoding cases and two release-observer freshness tests. It did not rerun the full database suite, inspect production ingress/services, manipulate queues, read device secrets or send APNs. PR CI evidence is historical and must be identified as such.

Baseline shared contract: ArcusCore 0.7.0 / `4b8cd2db056cbda14303d6165bf9b73bea4d48c6`. Client #798 / PR justinrooks/project-arcus#800 supplies the authenticated v3 path. These source identities are not claims about a deployed server or distributed client build.

The current-source compatibility check passed **83 tests across 10 suites** through `tools/test_lane.sh --no-parallel` at `c4f5ee20d456d4dd7c3152229003b13b1d046df2`, completed 2026-10-29T18:42:46Z. Coverage included legacy device writes, enrollment/authority and migrations, v3 consent, foreground activity, alert/meso reads, meso eligibility and invalid NWS collections. Both database selectors targeted one disposable issue-scoped database. The initial run failed because alert tests preceded schema migration; that run was retained, schema preparation was confirmed, and the identical selection passed. Native evidence is `/private/tmp/arcus-compatibility-20261029/result.json` and `lane-0.stdout.log`. The deployed release differs only in release notes, so the application/test source matches; this local evidence is not a deployed-image test.

- **#378:** [Operational-access disposition remains unknown](https://github.com/justinrooks/arcus-signal/issues/378#issuecomment-6506799497). Verify trusted effective ingress/operator policy, protected-route coverage and origin/worker isolation; claim neither protection nor public exposure without evidence.
- **#400:** Obtain explicit live-processing, expired-lease and failed/terminal handoff classifications. Aggregate pending/stuck zeroes do not establish those separate counts. Record exact controlled TestFlight build/environment, capability/opt-in, current consent/usable presence and targeted meso reads; retain Justin's existing device-testing attestation.
- **#400:** Existing tests cover recovery, post-claim consent and worker-time presence separately. The unexecuted bounded follow-up is recovery of an expired NWS H3 handoff, authenticated higher-revision sharing opt-out with retained presence, then duplicate dequeue with zero opted-out sends and one opted-in control delivery. Verification-only #400 requires identifying this gap; it does not authorize a broad test campaign or claim that the composition passed.
- **#289:** Record correlated production receipt/open, absence of local/remote duplication, dashboard acceptance evidence and gate-off ownership refresh with intended local client behavior. Enabled server configuration alone does not close this rollout issue.

## Closure evidence to record

Record each correction's PR/merge SHA and focused test artifact on its issue. On #400 record the actual Signal release/images, ArcusCore pin, client build, operational access disposition, canonical freshness, recovery/backlog state and a bounded readiness verdict. On #289 record the actual gate transition, provider and device evidence separately, duplicate-prevention result and concrete rollback/ownership-refresh procedure. Never include credentials, device tokens, raw locations or private notification payloads.

This documentation records completed work and unresolved acceptance without closing #400, #289 or #397. Runtime behavior, production configuration and notification delivery are unchanged by publishing it.
