# Storm Setup Issue Runbook

**Status:** Active  
**Applies To:** Storm Setup / Tornado Ingredient Snapshot  
**Project:** Arcus Signal  
**Parent Issue:** https://github.com/justinrooks/arcus-signal/issues/68  
**Related Docs:**
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/plans/storm-setup-progress.md`
- `/Users/justin/Code/Skills/swift-concurrency-expert/SKILL.md`
- `/Users/justin/Code/SwiftUI-Agent-Skill/swiftui-expert-skill/SKILL.md`
- `/Users/justin/Library/Mobile Documents/iCloud~md~obsidian/Documents/Second Brain/+/Tornado Ingredient Snapshot.md`

This document defines how to execute one Storm Setup sub-issue at a time.

Every implementation prompt for a Storm Setup sub-issue must reference this runbook and `docs/plans/storm-setup-progress.md`.

---

## Purpose

Build the first local Storm Setup backend slice for Tornado Ingredient Snapshots.

The endpoint should accept an H3 cell, sample official HRRR 2D GRIB data server-side through `wgrib2`, normalize selected tornado-relevant ingredients, interpret them into calm environmental-favorability language, and return compact JSON to SkyAware.

This runbook exists to keep implementation:
- issue-scoped
- sequential
- local-first
- testable
- verifiable
- aligned with product truthfulness
- easy for the next agent to resume

> Do not treat any single sub-issue as permission to build the whole Storm Setup system.  
> Implement the current slice, verify it, update the progress log, and stop cleanly.

---

## Source of Truth

Treat these inputs with the following authority:

1. The relevant repo `AGENTS.md`  
   Repo-wide and server standing rules.

2. `docs/architecture.md` and `docs/epics-stories.md`  
   Arcus Signal pipeline, persistence, idempotency, and delivery invariants.

3. `docs/plans/storm-setup-issue-runbook.md`  
   The execution contract for Storm Setup sub-issues.

4. `Tornado Ingredient Snapshot.md`  
   Product intent, data-source guidance, response shape, field set, cache model, and language boundaries.

5. `docs/plans/storm-setup-progress.md`  
   Durable implementation ledger and issue-to-issue handoff record.

6. The current GitHub sub-issue  
   The implementation boundary for the current run.

7. Current source, tests, route registration, and local verification output touched by that issue.

---

## Required Read Order

Read in this order before doing implementation work:

1. `AGENTS.md`
2. `docs/architecture.md`
3. `docs/epics-stories.md`
4. `docs/plans/storm-setup-issue-runbook.md`
5. `/Users/justin/Code/Skills/swift-concurrency-expert/SKILL.md`
6. `/Users/justin/Code/SwiftUI-Agent-Skill/swiftui-expert-skill/SKILL.md`
7. `/Users/justin/Library/Mobile Documents/iCloud~md~obsidian/Documents/Second Brain/+/Tornado Ingredient Snapshot.md`
8. `docs/plans/storm-setup-progress.md`
9. The current GitHub sub-issue
10. Relevant source and tests touched by that sub-issue

Storm Setup is server-side for this local-first slice. Do not inspect or modify app repositories unless a future issue explicitly says otherwise.

---

## Prompt Contract

Every implementation prompt for a Storm Setup sub-issue should include:

```text
Before implementing, read:
- docs/plans/storm-setup-issue-runbook.md
- docs/plans/storm-setup-progress.md
- /Users/justin/Code/Skills/swift-concurrency-expert/SKILL.md
- /Users/justin/Code/SwiftUI-Agent-Skill/swiftui-expert-skill/SKILL.md

Work only the current GitHub issue.
After implementation and verification, update docs/plans/storm-setup-progress.md with:
- status
- files changed
- tests/commands run
- local verification notes
- deferred scope
- handoff notes for the next issue
```

If a prompt does not reference these docs, the implementing agent should still read them before coding.

---

## Swift Best-Practice Skill Guidance

Every Storm Setup implementation agent must use these skills as Swift best-practice guidelines:

- `swift-concurrency-expert` at `/Users/justin/Code/Skills/swift-concurrency-expert/SKILL.md`
- `swiftui-expert:swiftui-expert-skill` at `/Users/justin/Code/SwiftUI-Agent-Skill/swiftui-expert-skill/SKILL.md`

Use `swift-concurrency-expert` directly for server implementation decisions involving:
- async/await flows
- `Sendable` and `Codable` models crossing concurrency boundaries
- `Foundation.Process`
- filesystem or network work from async code
- Vapor request handlers and provider protocols
- mutable shared state, caches, clocks, and injected clients

Use `swiftui-expert` as a design-quality guideline for any app-facing contract or later SkyAware handoff:
- prefer stable, native Swift-friendly Codable shapes
- keep data flow clear and separable from presentation
- avoid response contracts that force awkward SwiftUI state or identity handling
- keep user-facing language accessible, restrained, and easy to render
- do not introduce UIKit/AppKit assumptions into server contracts

Storm Setup currently lives in the server repo. The SwiftUI skill does not authorize editing the SkyAware app or adding UI work unless a future issue explicitly scopes that work.

---

## Product Language Boundaries

Storm Setup explains environmental favorability. It does not predict tornadoes.

Use language like:
- `Storm Setup`
- `Tornado Ingredients`
- `Environment is conditionally supportive`
- `Ingredients are becoming more supportive`
- `Low-level rotation is modest`
- `Storm development remains conditional`
- `near your area`
- `around your location`
- `for your local area`

Avoid language like:
- `Tornado predictor`
- `Tornado probability`
- `Tornado hunting`
- `Tornado risk score`
- `Tornado likely here`
- `at your exact location`

The API may expose raw values, but the assessment summary must remain calm, defensible, and explicitly about ingredients.

---

## Scope Rules

Implement only the current issue's scope.

### Required

- Keep implementation files under `Sources/App/StormSetup`.
- Keep only the controller entrypoint under `Sources/App/Controllers/StormSetupController.swift`.
- Use the local `wgrib2` executable path for this first pass:
  - `/Users/justin/Downloads/wgrib2-3.8.0/build/install/bin/wgrib2`
- Keep the executable path centralized so it can be replaced later.
- Keep the controller thin.
- Do not run `Process` directly in routes.
- Use H3 for model sampling input.
- Represent H3 cells as `Int64` in server-side Storm Setup models, providers, cache keys, and tests.
- Accept query input as text only at the HTTP boundary, then validate and convert it to `Int64` before passing it deeper into the StormSetup module.
- Resolve H3 to centroid latitude/longitude before sampling.
- Sample HRRR with `wgrib2 -lon` at or near the H3 centroid.
- Cache source GRIB subsets by source metadata, bbox, and field set.
- Cache sampled snapshots by H3 cell, HRRR source metadata, and rules version.
- Use deterministic source keys that include run time and forecast hour.
- Preserve source metadata in the response.
- Return missing data as `nil`, not fake zeroes.
- Keep interpretation deterministic and testable.
- Mark stale/missing/degraded source situations explicitly.
- Add focused tests for the current slice when practical.
- Run the narrowest meaningful verification before finishing.
- Update `docs/plans/storm-setup-progress.md` before finishing.

### Forbidden

- Do not introduce a separate deployed service.
- Do not add production DB schema for this local-first slice unless a future issue explicitly scopes it.
- Do not wire APNs/content-available pushes in this first local endpoint sequence.
- Do not use SPC point-values as the main implementation path.
- Do not use Pivotal Weather as a production data endpoint.
- Do not add UH tracks, full Skew-T reconstruction, model consensus, radar morphology, or pressure-level sounding reconstruction.
- Do not store server-side raw lat/lon for users.
- Do not create a parallel app refresh architecture.
- Do not broaden the current sub-issue to "finish Storm Setup."
- Do not hide source selection behind a vague `latest` key.

If a future-facing seam is required, keep it:
- minimal
- local
- replaceable
- documented in the progress log

---

## Working Style

Prefer:
- small value types
- pure parsing and interpretation functions
- explicit source metadata
- narrow filesystem cache abstractions
- injected clocks for time-sensitive tests
- injected process/HTTP clients for testability
- deterministic cache keys
- straightforward Vapor controller patterns
- clear errors over silent fallback

Avoid:
- speculative service boundaries
- broad migrations
- hidden live-network dependencies in unit tests
- shell command strings
- raw model-data assumptions without tests or notes
- route-level orchestration
- "latest" cache keys
- user-facing prediction language

The right shape is a bounded StormSetup module inside Arcus Signal, not a meteorology platform trying to happen all at once.

---

## Sequential Execution Model

Work one GitHub sub-issue at a time, sequentially.

Do not execute multiple Storm Setup sub-issues in parallel under a parent coordinator.

Parallelism is allowed only inside the current issue and only for narrow investigation or isolated subtasks that do not change the issue boundary.

---

## Delegated Agent Rules

If delegated agents or subtasks are available, use them only when they reduce context sprawl and improve quality for the current issue.

### Good delegated tasks

- checking current Vapor controller patterns
- inspecting SwiftyH3 usage and H3 cell conversion APIs
- mapping existing local filesystem/cache patterns
- reviewing `Process` / async concurrency safety
- checking representative `wgrib2 -lon` output parsing behavior
- validating a proposed HRRR source-selection rule against the brief

### Do not delegate

- final issue scope
- final product language
- final source-selection policy
- cross-issue sequencing
- final integration decisions
- final progress-log handoff

Delegated work should stay scoped and concise.

The primary executor remains responsible for:
- reconciling findings
- resolving conflicts
- producing one coherent implementation for the current issue
- updating the progress log

---

## Execution Sequence

Before making code changes for the current issue:

### 1. Inspect inputs

Inspect the relevant sections of:
- `Tornado Ingredient Snapshot.md`
- `docs/plans/storm-setup-progress.md`
- the current GitHub issue
- existing StormSetup source files and nearby controller/route patterns
- tests relevant to the issue

### 2. Identify what matters now

Identify:
- which parts of the brief are relevant to the current issue
- which parts are already partially implemented
- what existing seams, models, tests, and route patterns are most relevant
- what must change now
- what should remain deferred

### 3. Produce a pre-implementation plan

Before coding, produce:
- a concise findings summary
- an issue-scoped implementation plan
- a short ambiguity/risk list
- any assumptions to be made
- a verification plan tied to the issue acceptance notes

### 4. Evaluate the plan before coding

Evaluate the plan and:
- remove anything that reaches beyond the current issue
- remove speculative abstractions
- check for conflicts with the brief, progress log, or existing code conventions
- verify that it leaves a clean handoff for the next issue
- simplify the design if it starts growing tentacles

### 4.5 Skill guidance gate

Before coding, apply `swift-concurrency-expert` and `swiftui-expert:swiftui-expert-skill` as required guidelines.

Use `swift-concurrency-expert` especially when the issue touches:
- async/await flows
- `Sendable` or `Codable` models crossing concurrency boundaries
- `Foundation.Process`
- Vapor request handlers
- shared service/provider types used from async contexts
- filesystem or network work executed from async code

Use `swiftui-expert:swiftui-expert-skill` to sanity-check Swift-facing API design, response shape, naming, user-facing wording, and future app ergonomics.

For both skills:
- read the skill before implementation
- apply only guidance relevant to the current issue
- record important skill-driven decisions in `docs/plans/storm-setup-progress.md`

Do not use either skill as permission to broaden scope.

### 5. Implement

Implement in small, reviewable steps.

Prefer extending existing patterns over inventing new ones.

### 6. Ask questions only when necessary

Stop to ask questions only if a missing decision would materially affect:
- the current issue's scope
- the public API response contract
- the cache identity model
- the source-selection policy
- user-facing assessment language
- whether to introduce persistence or broader architecture

### 7. Verify

Run the smallest meaningful verification for the issue:
- focused unit tests for pure logic
- parser tests for `wgrib2` inventory/value output
- cache-key and cache hit/miss tests
- deterministic source-selection tests with injected clocks
- route tests for request validation
- local `wgrib2` / NOMADS verification only when the issue reaches live integration
- `swift test` or narrower SwiftPM test filters when the issue touches shared behavior

Do not claim tests passed unless they were actually run.

### 8. Update progress

Before finishing the issue, update `docs/plans/storm-setup-progress.md` with:
- issue status
- files changed
- tests/commands run
- local verification notes
- deferred scope
- risks/open questions
- handoff notes for the next issue

---

## Suggested Implementation Sequence

Work these slices in order unless the owner explicitly changes the order:

1. `#69` - Contracts, route boundary, and H3 centroid resolution
2. `#70` - Safe local `wgrib2` execution and point-sample parsing
3. `#71` - HRRR run/forecast selection and NOMADS subset URL construction
4. `#72` - NOMADS GRIB subset download and local filesystem cache
5. `#73` - HRRR field sampling and raw-parameter normalization
6. `#74` - Tornado ingredient assessment and freshness/degraded semantics
7. `#76` - Local sampled snapshot cache keyed by H3/source/rules version
8. `#75` - Provider/controller orchestration for local end-to-end snapshots

---

## Expected End State

The local Storm Setup slice is done when:
- `GET /api/v1/storm-setup/current?h3=<valid-cell>` returns a populated Tornado Ingredient Snapshot locally when NOMADS and `wgrib2` are available.
- Invalid or missing H3 input returns a useful 400 response.
- H3 cells are represented as `Int64` after HTTP-boundary validation.
- H3 input resolves to a centroid and is described as local-area sampling, not exact-location truth.
- HRRR source metadata includes model, product, run time, forecast hour, valid time, field set, and freshness.
- GRIB subsets are cached by deterministic source/bbox/field-set keys.
- Sampled snapshots are cached by H3/source/rules-version keys.
- `wgrib2` execution is isolated behind a safe wrapper.
- Raw values are normalized into stable JSON with missing values represented as nil.
- Assessment output includes overall support, confidence, drivers, limiting factors, and summary.
- Assessment language never implies tornado prediction or probability.
- No production DB schema, APNs push wiring, app UI changes, or separate deployed service is introduced.
- `docs/plans/storm-setup-progress.md` contains a complete issue-by-issue handoff ledger.
