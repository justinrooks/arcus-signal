# Arcus Signal Codex Skills and Script Infrastructure Punchlist

**Status:** Planned  
**Project:** Arcus Signal  
**Purpose:** Build a small, composable set of Arcus-specific Codex skills backed by deterministic repository scripts.  
**Working mode:** One reviewable slice at a time, with human review after each usable capability.

## Objective

Make the Arcus Signal issue-to-PR workflow more deterministic, more Arcus-aware, and less expensive in context and tokens.

The target workflow is:

```text
issue context
    -> repository preflight
    -> readiness and slice planning
    -> bounded implementation
    -> focused validation
    -> scoped review
    -> commit readiness
    -> PR publication
```

The design should preserve the existing human approval gates while reducing repeated repository discovery, repeated test attempts, duplicated review prompts, and unnecessary session handoffs. The issue-lifecycle-orchestrator skill contains this flow and works as intended.

## Design principles

- Build one vertical slice at a time: script contract, skill, realistic trial, adjustment.
- Skills decide what should happen; scripts produce reproducible facts.
- Keep scripts in this repository under `tools/`.
- Keep reusable Codex skills in the personal skill directory unless a later packaging decision moves them elsewhere.
- Pass artifact paths between skills instead of copying logs and summaries into prompts.
- Prefer JSON output for machine consumption and a terse human summary for interactive use.
- Keep automatic skill discovery enabled for narrow domain skills.
- Require explicit invocation or explicit authorization for lifecycle, commit, push, and PR publication actions.
- Do not create a second large orchestration framework before the smaller capabilities have been proven.
- Keep each implementation slice within the repository’s normal review budget.
- Use current production code, tests, `AGENTS.md`, and `docs/architecture.md` as authority.

## Observed baseline

The August 13 Arcus Signal batch covered issues #208–#214. The archived traces showed:

- 7 issue sessions
- approximately 400 shell/tool executions
- 118 agent and control calls
- 23 agent spawns
- 54 `wait_agent` calls
- approximately 64.7 million session-reported cumulative tokens

The totals include system context and continuation behavior and should be treated as directional rather than an exact billing report.

Repeated patterns included:

- rereading the lifecycle skill, GitHub skill, `AGENTS.md`, architecture docs, and epic docs in every fresh session
- repeated issue and branch discovery
- repeated focused test commands after cache or dependency failures
- repeated full-suite attempts when the underlying issue was environmental
- repeated agent polling and follow-up turns
- PR publication being blocked by unrelated dirty files such as `docs/Sql/Device.sql`
- manual reconstruction of validation evidence and changed-file scope

## Proposed repository layout

```text
tools/
├── capabilities.json
├── repo_preflight.sh
├── issue_context.sh
├── test_lane.sh
├── integration_preflight.sh
├── integration_test.sh
├── diff_scope.sh
├── commit_readiness.sh
├── publish_readiness.sh
├── queue_contract_check.sh
├── db_check.sh
├── db_schema.sh
├── replay_ingest.sh
└── health_check.sh
```

Scripts should initially be independent. Add a shared shell library only after at least two scripts demonstrate a stable common need.

## Standard script contract

Every script should support:

```text
--json       emit machine-readable output
--quiet      suppress non-error progress output
--output DIR write artifacts to an explicit directory
--help       describe inputs, side effects, and exit codes
```

Recommended exit codes:

```text
0  success or verified positive result
1  expected check failure or negative result
2  invalid invocation
3  unavailable prerequisite or environment
4  ambiguous or unsafe state requiring human direction
```

The JSON envelope should be stable across scripts:

```json
{
  "schema_version": 1,
  "status": "passed",
  "repository": "justinrooks/arcus-signal",
  "branch": "...",
  "revision": "abc123",
  "command": "...",
  "started_at": "2026-09-17T00:00:00Z",
  "finished_at": "2026-09-17T00:00:05Z",
  "artifact": "/private/tmp/arcus-validation/example/result.json",
  "errors": []
}
```

Scripts should never place secrets, APNs tokens, raw coordinates, or database credentials in output artifacts.

## Foundation skills and scripts

### `arcus-repo-preflight`

**Purpose:** Establish trustworthy repository state before implementation, review, commit, or publication.

**Script:** `tools/repo_preflight.sh`

**Inputs:** optional repository path, base branch, and output directory.

**Checks:**

- repository identity and remote
- current branch
- current HEAD and merge-base with base
- upstream branch
- staged, unstaged, and untracked files
- committed changes versus unrelated dirty files
- applicable `AGENTS.md` files
- presence of expected Arcus files

**Output shape:**

```json
{
  "status": "attention",
  "repository": "justinrooks/arcus-signal",
  "branch": "213-06-dispatch-reconciliation-work",
  "base": "main",
  "head": "abc123",
  "merge_base": "def456",
  "worktree": {
    "clean": false,
    "staged_files": [],
    "unstaged_files": ["docs/Sql/Device.sql"],
    "untracked_files": [],
    "unrelated_dirty_files": ["docs/Sql/Device.sql"]
  },
  "errors": []
}
```

**Acceptance criteria:**

- works in clean and dirty worktrees
- separates committed branch scope from unrelated worktree dirt
- produces stable JSON
- does not mutate the repository
- clearly reports ambiguous staged changes

### `arcus-issue-context`

**Purpose:** Create a compact durable packet for a single issue so a fresh session does not rediscover the same context.

**Script:** `tools/issue_context.sh <issue-number>`

**Inputs:** issue number, optional repository, optional progress/runbook path.

**Collects:**

- issue title, body, labels, state, URL, and comments relevant to implementation
- parent epic and dependencies
- current branch and worktree packet
- relevant section from the Arcus progress/runbook document
- likely production and test files
- explicit stop condition
- focused validation commands

**Output shape:**

```json
{
  "issue": {
    "number": 213,
    "title": "Dispatch and process installation reconciliation work",
    "url": "https://github.com/justinrooks/arcus-signal/issues/213"
  },
  "scope": {
    "production_files": [],
    "test_files": [],
    "documentation_files": [],
    "excluded_areas": []
  },
  "validation": [
    "swift test --filter InstallationAlertReconciliationJobTests"
  ],
  "stop_condition": "...",
  "repository_packet": "/private/tmp/arcus-issue/213/repo.json"
}
```

**Acceptance criteria:**

- reads only the issue and directly relevant durable artifacts
- emits paths and commands instead of copying large source excerpts
- records missing or ambiguous information explicitly
- does not claim that inferred files or tests are authoritative

### `arcus-issue-readiness`

**Purpose:** Decide whether an issue is ready for bounded implementation.

**Skill only initially;** it consumes the issue and repository packets.

**Checks:**

- acceptance criteria are actionable
- dependencies are complete or explicitly waived
- scope fits one review unit
- production and test paths are identifiable
- validation is defined
- no branch or worktree ambiguity blocks safe work

**Output:** `READY`, `BLOCKED`, or `REQUIRES HUMAN DECISION`, with evidence paths and one concise reason.

## Validation skills and scripts

### `arcus-focused-validation`

**Purpose:** Run the smallest meaningful validation lane and preserve exact evidence.

**Script:** `tools/test_lane.sh`

**Inputs:** one or more explicit SwiftPM filters, optional `--full`, optional `--no-parallel`, output directory.

**Responsibilities:**

- configure task-specific SwiftPM and Clang cache paths
- run the requested command once
- capture stdout, stderr, exit status, revision, and environment summary
- report test counts when available
- return a compact result path
- avoid automatic retries unless explicitly requested

**Output shape:**

```json
{
  "status": "passed",
  "revision": "abc123",
  "commands": [
    "swift test --filter PresenceReconciliationOutboxTests",
    "swift test --filter DevicePresenceMigrationTests"
  ],
  "tests": {
    "executed": 18,
    "passed": 18,
    "failed": 0
  },
  "log": "/private/tmp/arcus-validation/209/test.log",
  "result": "/private/tmp/arcus-validation/209/result.json"
}
```

**Acceptance criteria:**

- does not silently rerun failed commands
- distinguishes compilation failure, test failure, and unavailable prerequisite
- records the exact tested revision
- supports focused tests before broad tests
- produces evidence another agent can inspect without rerunning the suite

### `arcus-integration-preflight`

**Purpose:** Detect unavailable local infrastructure before integration tests begin.

**Script:** `tools/integration_preflight.sh`

**Checks:**

- Docker availability
- Postgres readiness and expected database
- Redis readiness
- configured ports
- required environment variables without printing secrets
- migration/schema prerequisites

**Output:** service-by-service status with remediation guidance and exit code `3` for unavailable prerequisites.

### `arcus-integration-validation`

**Purpose:** Run explicitly requested Postgres/Redis-backed tests with reproducible setup and evidence.

**Script:** `tools/integration_test.sh <suite>`

**Responsibilities:**

- call integration preflight
- use the repository’s existing Docker and database conventions
- run migrations or test setup as required
- capture logs and result metadata
- avoid destructive cleanup unless explicitly requested

## Domain skills and scripts

### `arcus-persistence-change`

**Trigger:** Fluent models, migrations, PostgreSQL queries, transaction boundaries, persistence stores, or schema changes.

**Guidance:**

- verify migration registration
- verify uniqueness and idempotency constraints
- identify transaction owner
- distinguish mock-only tests from disk-backed persistence tests
- preserve rollback and deployment expectations
- use `arcus-focused-validation` and `arcus-integration-validation` only when required

**Optional script:** `tools/db_schema.sh`

### `arcus-queue-change`

**Trigger:** Vapor Queues, Redis, worker startup, queue lanes, outbox handoff, retries, or scheduled jobs.

**Guidance:**

- API remains enqueue-only
- worker owns consumers and APNs delivery
- durable intent precedes best-effort queue handoff
- duplicate dispatch is safe through DB idempotency
- retry behavior is bounded and explicit
- queue lane and concurrency settings remain intentional

**Script:** `tools/queue_contract_check.sh`

**Potential checks:** queue registration, worker-only startup, lane names, retry settings, and outbox state transitions.

### `arcus-notification-boundary`

**Trigger:** targeting, notification outbox, candidate queries, ledger claims, send jobs, notification composition, or APNs delivery.

**Guidance:**

- targeting never sends APNs directly
- the ledger claim remains the at-most-one delivery claim boundary
- candidate-specific copy is composed after a successful claim
- stale, ended, expired, and cancelled alerts are handled deliberately
- constrained and unconstrained delivery paths remain compatible

### `arcus-contract-review`

**Trigger:** DTOs, Codable payloads, API routes, queue payloads, persisted payloads, schemas, or client/server contracts.

**Guidance:**

- inspect backward decoding
- compare route aliases and handler behavior
- compare code, migrations, and persisted identity fields
- identify cross-repository impact
- preserve compatibility unless the issue explicitly changes the contract

### `arcus-concurrency-review`

**Trigger:** actors, async jobs, cancellation, shared mutable state, concurrent queue work, or retry races.

**Guidance:**

- use only when the diff materially touches concurrency
- inspect cancellation and lifecycle boundaries
- identify duplicate execution behavior
- require deterministic race characterization where practical

## Review and scope skills

### `arcus-diff-scope`

**Purpose:** Produce a mechanical changed-file and risk-boundary report.

**Script:** `tools/diff_scope.sh <base> <head>`

**Output shape:**

```json
{
  "base": "main",
  "head": "abc123",
  "changed_files": [],
  "counts": {
    "production": 3,
    "tests": 2,
    "migrations": 1,
    "documentation": 1
  },
  "boundaries": ["persistence", "queue"],
  "diff_lines": {
    "added": 120,
    "deleted": 18
  },
  "out_of_scope_candidates": []
}
```

### `arcus-regression-review`

**Purpose:** Read-only defect review for Arcus-specific correctness risks.

**Consumes:** issue packet, diff scope report, and validation artifact paths.

**Prioritizes:**

- route/worker ownership violations
- transaction and persistence defects
- lost durable intents
- duplicate or unsafe delivery behavior
- stale alert or presence behavior
- retry/cancellation defects
- contract incompatibility
- meaningful missing regression coverage

It should return only actionable findings with severity, evidence, failure mode, smallest correction, and required validation.

### `arcus-validation-auditor`

**Purpose:** Determine whether validation evidence supports the issue’s acceptance criteria.

**Consumes:** native test artifacts rather than copied logs.

**Returns:** `sufficient`, `sufficient with limitations`, or `insufficient`, with only meaningful gaps.

## Publication skills and scripts

### `arcus-commit-readiness`

**Script:** `tools/commit_readiness.sh`

Checks:

- focused validation evidence exists and matches the intended revision
- diff scope is within the issue boundary
- accidental staged files are absent
- commit message can reference the issue
- unresolved findings are either fixed or explicitly accepted

### `arcus-publish-readiness`

**Script:** `tools/publish_readiness.sh <base> <head>`

Uses the committed range `base...head` as publication scope.

It should distinguish:

- committed branch changes
- staged but uncommitted changes
- unrelated unstaged files
- missing upstream branch
- branch divergence
- changed files overlapping the intended issue

An unrelated unstaged file should produce attention, not automatically block PR creation.

### `arcus-pr-publisher`

Thin Arcus-specific wrapper around the existing PR publication skill.

It should receive:

- issue packet
- repository preflight result
- diff scope result
- validation artifact paths
- explicit publication authorization

It should reconstruct the PR from Git and GitHub evidence, avoid rerunning tests, and publish only committed and pushed work.

## Operational skills

### `arcus-db-diagnostics`

**Scripts:**

- `tools/db_check.sh`
- `tools/db_schema.sh`

Read-only checks for:

- migration state
- required tables and indexes
- outbox rows and state transitions
- queue recovery state
- stale leases
- notification ledger claims

Mutating repair commands should be separate, explicitly named, and require direct authorization.

### `arcus-replay-validation`

**Script:** `tools/replay_ingest.sh <fixture>`

Standardizes deterministic NWS replay validation, expected series/revision assertions, outbox inspection, and result capture.

### `arcus-health-check`

**Script:** `tools/health_check.sh`

Checks API and worker health endpoints plus Redis/Postgres reachability after startup, queue, or deployment-related changes.

## Larger skills to update

### Existing issue lifecycle orchestrator

Update after the foundation has been proven. The Arcus-specific version should:

1. call repository preflight once
2. create or consume the issue packet once
3. read only the relevant progress/runbook section
4. classify the issue using the Arcus risk rubric
5. select domain skills based on issue scope and changed files
6. run focused validation before any broad validation
7. pass artifact paths to reviewers and publisher
8. avoid re-running tests after unchanged evidence
9. treat unrelated unstaged files correctly during publication
10. preserve explicit approval gates for commit, push, PR, and merge

### Existing implementation skills

Update implementation-oriented skills only after their supporting scripts and domain contracts are working.

Changes should be narrow:

- replace repeated discovery with issue and repository packets
- reference Arcus scripts instead of retyping shell procedures
- route persistence, queue, notification, contract, and concurrency concerns to the appropriate small skill
- preserve the existing implementation skill’s original purpose
- remove duplicated generic guidance that is already enforced by `AGENTS.md`

### Existing reviewer and publisher agents

Create Arcus-specific agents or update the existing ecosystem agents only after the skill boundaries are proven. Their prompts should accept artifact paths and avoid copying full diffs, logs, or planning documents.

## Model routing

Use the smallest model that can perform the current decision reliably. The purpose of moving to a larger model is to reduce architectural rework and tool mistakes, not to compensate for missing scripts or noisy context.

Recommended default routing:

| Capability | Recommended model | Reasoning guidance |
|---|---|---|
| `arcus-repo-preflight` implementation | Luna | Mechanical shell work with a narrow contract |
| `arcus-issue-context` implementation | Luna | Deterministic GitHub and repository extraction |
| `arcus-focused-validation` implementation | Luna | Scripted command execution and artifact capture |
| `arcus-integration-preflight` implementation | Luna | Explicit service checks and exit-code handling |
| `arcus-integration-validation` implementation | Terra | Environment, cleanup, and evidence boundaries need more judgment |
| `arcus-issue-readiness` | Terra | Scope, dependency, and acceptance-criteria interpretation |
| `arcus-slice-planner` | Terra | Converts issue evidence into a bounded implementation unit |
| `arcus-persistence-change` | Terra | Transaction, migration, uniqueness, and deployment implications |
| `arcus-queue-change` | Terra | Queue durability, retries, worker ownership, and idempotency |
| `arcus-notification-boundary` | Terra | Cross-job delivery and ledger invariants |
| `arcus-contract-review` | Terra | Compatibility across API, Codable, queue, and persistence boundaries |
| `arcus-concurrency-review` | Terra | Cancellation and race reasoning when the diff materially touches concurrency |
| `arcus-diff-scope` implementation | Luna | Mechanical changed-file and line-count reporting |
| `arcus-regression-review` | Terra | Independent defect analysis over supplied evidence |
| `arcus-validation-auditor` | Terra | Acceptance-criteria coverage and evidence matching |
| `arcus-db-diagnostics` implementation | Luna | Read-only query packaging with explicit safety limits |
| `arcus-replay-validation` implementation | Terra | Fixture selection and expected persistence/outbox assertions |
| `arcus-health-check` implementation | Luna | Bounded endpoint and service checks |
| `arcus-commit-readiness` | Luna | Mechanical staged-file and evidence checks |
| `arcus-publish-readiness` | Luna | Mechanical committed-range and branch checks |
| `arcus-pr-publisher` | Luna | Evidence-based packaging after all decisions are complete |
| Arcus lifecycle integration | Terra | Coordinates multiple skills, artifacts, gates, and fallback paths |
| Overall skill architecture or conflicting boundaries | Sol | Reserve for cross-skill design decisions that Terra cannot resolve cleanly |

Preferred pattern:

```text
Terra: establish the script or artifact contract
Luna: implement the narrow script or skill
Terra: review the result and boundary behavior
Sol: resolve only material architectural disagreement
```

Do not move every task to a larger model. A larger model does not eliminate repeated context reads, redundant test runs, or weak artifact contracts. Those are addressed by the script and skill design itself.

Model-routing acceptance criteria:

- each skill has a default model recommendation
- larger-model escalation has a concrete reason
- routine script work remains cost-sensitive
- model changes are not used as a substitute for missing validation
- one representative Terra/Luna comparison is recorded before changing defaults broadly

## Risk rubric

| Change type | Default treatment | Default validation |
|---|---|---|
| Pure policy or DTO | ordinary implementation | focused unit tests |
| Fluent model or migration | persistence skill, higher scrutiny | focused persistence and migration tests |
| Route transaction | persistence and contract review | controller plus persistence tests |
| Queue or outbox | queue skill, higher scrutiny | focused queue/persistence tests |
| Worker scheduling | queue skill | worker bootstrap and schedule tests |
| Notification targeting or delivery | notification boundary review | candidate, freshness, ledger, and delivery tests |
| Cross-pipeline behavior | regression review and validation audit | focused suites, build, then non-parallel full suite when justified |

## Implementation sequence

### Phase 0 — Tracking and contracts

- [ ] Decide whether this punchlist is tracked only in-repository or also through a GitHub epic.
- [ ] Define the standard JSON result envelope.
- [ ] Define artifact storage location and retention expectations.
- [ ] Decide whether scripts should require Bash 4+ features or remain macOS default-shell compatible.
- [ ] Decide how issue-specific validation commands are discovered from progress/runbook documents.
- [ ] Record the default model routing and escalation rule for each skill family.

**Review gate:** approve the contracts and storage conventions before implementing multiple scripts.

### Phase 1 — Foundation vertical slice

- [x] Implement `tools/repo_preflight.sh`.
- [x] Create the `arcus-repo-preflight` skill.
- [x] Validate clean, unrelated-dirty, staged, and ambiguous worktrees.
- [x] Trial it against one real Arcus branch.
- [x] Implement and review the first slice with Luna after the contract is approved by Terra.

**Completed evidence:**

- `tools/capabilities.json` declares the `repository-preflight` capability and maps it to `arcus-repo-preflight`.
- `tools/repo_preflight.sh` emits human-readable and JSON results, expands untracked directories, and classifies unrelated files only when an explicit scope file is supplied.
- The centralized skill is registered in `Prompt_Fu/manifest.yaml` and installed into both Codex and Xcode target directories from the same Prompt_Fu source.
- A fresh Codex session invoked the skill successfully against `justinrooks/arcus-signal` and reported the expected `attention` state for the dirty worktree.
- Direct validation covered Bash syntax, manifest mapping, JSON output, output artifacts, and explicit scope classification.
- `tools/test_lane.sh` runs explicit SwiftPM filters once, uses task-local caches, captures separate stdout/stderr, and emits lane plus actual test counts.
- The centralized `arcus-focused-validation` skill is registered in `Prompt_Fu/manifest.yaml` and installed into both Codex and Xcode target directories from the same Prompt_Fu source.
- A fresh session invoked `tools/test_lane.sh --filter PresenceReconciliationOutboxTests --no-parallel` at revision `8e351225f9b9f578b761ac266321290d01962029`; the result was 6/6 passed with evidence at `/private/tmp/arcus-validation/20260917-presence-reconciliation-escalated/result.json`.
- Validation also demonstrated that nested-sandbox SwiftPM setup failures are reported as `unavailable`, rather than being misreported as test failures.

**Stop condition:** repository state is represented accurately without mutation or manual interpretation.

- [x] Implement `tools/test_lane.sh`.
- [x] Create the `arcus-focused-validation` skill.
- [x] Validate focused pass and unavailable prerequisite behavior; retain focused-failure and compile-failure cases as future hardening coverage if a safe fixture is added.
- [x] Trial it against the Presence Reconciliation outbox tests relevant to issues #209/#213.
- [ ] Compare Luna and Terra only if the first implementation exposes contract or reliability ambiguity.

**Stop condition:** one validation command produces inspectable evidence and does not silently retry.

### Phase 2 — Context and scope

- [ ] Implement `tools/issue_context.sh`.
- [ ] Create the `arcus-issue-context` skill.
- [ ] Create `arcus-issue-readiness` as a small consumer of the packet.
- [ ] Implement `tools/diff_scope.sh`.
- [ ] Create `arcus-diff-scope`.

**Review gate:** compare the new packets against the manual context gathered for issues #208–#214.

### Phase 3 — Environment and publication reliability

- [ ] Implement `integration_preflight.sh`.
- [ ] Implement `integration_test.sh`.
- [ ] Implement `commit_readiness.sh`.
- [ ] Implement `publish_readiness.sh`.
- [ ] Trial publication with an unrelated dirty `docs/Sql/Device.sql` change present.

**Stop condition:** unrelated worktree dirt no longer causes repeated PR publication attempts.

### Phase 4 — Domain skills

- [ ] Create `arcus-persistence-change`.
- [ ] Create `arcus-queue-change` and `queue_contract_check.sh`.
- [ ] Create `arcus-notification-boundary`.
- [ ] Create `arcus-contract-review`.
- [ ] Create `arcus-concurrency-review`.
- [ ] Create `arcus-db-diagnostics` and read-only database scripts.

Each skill must be trialed against one real issue or representative change before the next domain skill is started.

### Phase 5 — Lifecycle integration

- [ ] Create the Arcus-specific lifecycle overlay.
- [ ] Update the existing implementation skills to consume the packets and scripts.
- [ ] Add Arcus-specific reviewer and validation-auditor agents.
- [ ] Update the PR publisher wrapper.
- [ ] Run a complete issue-to-PR rehearsal on a small, already-completed issue.

**Stop condition:** the lifecycle can complete a bounded Arcus issue while passing artifacts rather than repeating discovery and validation output.

### Phase 6 — Forward testing and pruning

- [ ] Test automatic activation with realistic Arcus requests.
- [ ] Test explicit activation for lifecycle and publication skills.
- [ ] Identify false-positive skill activation.
- [ ] Identify skills that overlap and tighten descriptions or exclusions.
- [ ] Remove instructions that duplicate `AGENTS.md` or repository scripts.
- [ ] Record observed token/tool savings where available.
- [ ] Record whether Terra reduced rework enough to justify its additional cost for design and integration work.

## Working agreement for each future slice

Before implementation, state:

- behavior or capability being added
- files expected to change
- approximate diff size
- explicit exclusions
- validation plan
- stop condition

After implementation, report:

- changed files
- behavior or workflow impact
- validation performed
- artifacts produced
- risks or follow-up

Do not begin the next punchlist item in the same review unit without agreement.

## Open decisions

- [ ] Should the skills live only in `~/.codex/skills`, or should a repository plugin package them for portability?
- [ ] Should the first milestone be a GitHub epic with child issues, or should this document remain the primary tracker?
- [ ] Should issue packets be temporary-only, or should selected packets be retained as repository evidence?
- [ ] Should validation scripts support only SwiftPM initially, or also Docker Compose and direct Postgres/Redis checks in the first milestone?
- [ ] Should automatic skill discovery remain enabled for every domain skill, with explicit-only policy reserved for mutation-capable skills?
- [ ] Which completed Arcus issue is the best first rehearsal after Phase 1: #209, #210, or #213?

## Initial recommendation

Start with the smallest foundation vertical slice:

```text
repo_preflight.sh
arcus-repo-preflight
```

The foundation validation slice is complete. The next slice is `issue_context.sh` and `arcus-issue-context`.

This sequence creates immediate value, tests the core script/skill boundary, and keeps the project reviewable throughout.
