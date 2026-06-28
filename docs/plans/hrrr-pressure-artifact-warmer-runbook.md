# HRRR Pressure Artifact Warmer Issue Runbook

**Status:** Active  
**Applies To:** HRRR Pressure Artifact Warmer Planning and Sequential Implementation  
**Project:** Arcus Signal  
**Parent Epic:** https://github.com/justinrooks/arcus-signal/issues/113  
**Issue 01:** https://github.com/justinrooks/arcus-signal/issues/114  
**Next Issue:** https://github.com/justinrooks/arcus-signal/issues/115  
**Related Docs:**
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/plans/hrrr-pressure-profile-runbook.md`
- `docs/plans/hrrr-pressure-profile-progress.md`
- `docs/plans/storm-setup-issue-runbook.md`
- `docs/plans/storm-setup-progress.md`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`

This document defines how to execute one HRRR pressure artifact warmer sub-issue at a time.

Every implementation prompt for this work should reference this runbook and `docs/plans/hrrr-pressure-artifact-warmer-progress.md`.

---

## Purpose

Build a narrow, sequential planning and implementation path for HRRR pressure artifact warming.

The warmer exists to ensure pressure artifacts are available before they are needed, without changing the live Storm Setup request path into a cold-acquisition path. The current storm-setup/current behavior must stay fast and predictable. If a pressure artifact is missing, the request path must not start fetching it on demand.

This work is intentionally conservative:
- keep the existing working surface GRIB path intact
- do not add cold pressure acquisition to the normal request loop
- do not move HRRR acquisition into Arcus-Anvil
- do not introduce Zarr, BUFKIT, native HRRR levels, or a new data platform
- do not broaden the work into a general NOAA framework

The warmer should be treated as a separate planning and scheduling concern layered around the existing pressure-profile work, not a rewrite of it.

> Do not treat any single sub-issue as permission to re-architect Storm Setup.
> Implement the current slice, verify it, update the progress log, and stop cleanly.

---

## Source of Truth

Treat these inputs with the following authority:

1. The repo `AGENTS.md`
   Repo-wide and server standing rules.

2. `docs/architecture.md` and `docs/epics-stories.md`
   Arcus Signal pipeline, idempotency, queue, and delivery invariants.

3. `docs/plans/hrrr-pressure-profile-runbook.md` and `docs/plans/hrrr-pressure-profile-progress.md`
   Historical pressure-profile boundaries, cache identity choices, and sequencing patterns.

4. `docs/plans/storm-setup-issue-runbook.md` and `docs/plans/storm-setup-progress.md`
   Existing HRRR GRIB boundaries and the working surface-path constraints to preserve.

5. `docs/plans/hrrr-pressure-artifact-warmer-runbook.md`
   The execution contract for HRRR pressure artifact warmer sub-issues.

6. `docs/plans/hrrr-pressure-artifact-warmer-progress.md`
   Durable implementation ledger and issue-to-issue handoff record.

7. The current GitHub sub-issue
   The implementation boundary for the current run.

8. Current source and tests touched by that issue.

---

## Required Read Order

Read in this order before implementation:

1. `AGENTS.md`
2. `docs/architecture.md`
3. `docs/epics-stories.md`
4. `docs/plans/hrrr-pressure-profile-runbook.md`
5. `docs/plans/hrrr-pressure-profile-progress.md`
6. `docs/plans/storm-setup-issue-runbook.md`
7. `docs/plans/storm-setup-progress.md`
8. `docs/plans/hrrr-pressure-artifact-warmer-runbook.md`
9. `docs/plans/hrrr-pressure-artifact-warmer-progress.md`
10. The current GitHub issue
11. Relevant source and tests for the current issue

Do not broaden the work into runtime changes outside the current issue boundary.

---

## Minimal Prompt Contract

A future implementation prompt can be as small as:

```text
Implement GitHub issue #NN for arcus-signal.

Before coding, read:
- docs/plans/hrrr-pressure-artifact-warmer-runbook.md
- docs/plans/hrrr-pressure-artifact-warmer-progress.md
- the GitHub issue body

Work only that issue. Do not touch the existing surface GRIB path unless the issue explicitly allows it.
Do not add cold pressure acquisition to the normal storm-setup/current request path.
After verification, update docs/plans/hrrr-pressure-artifact-warmer-progress.md.
```

If a prompt omits those docs, the implementing agent should still read them before coding.

---

## Scope Rules

Implement only the current issue's scope.

### Required

- Keep implementation narrow and sequential, one GitHub issue at a time.
- Preserve the working surface GRIB path exactly as-is unless the current issue explicitly says otherwise.
- Keep pressure artifact warming separate from the existing NWS alert polling loop.
- Keep normal storm-setup/current requests free of cold pressure artifact acquisition.
- Preserve deterministic source identity, including run time, forecast hour, valid time, field-set version, selected message identity, and source URL.
- Use cache keys that are inspectable and stable.
- Keep field-set versioning explicit so future warmer iterations can invalidate safely without guesswork.
- Keep warmer scheduling explicit and bounded.
- Prefer offline tests and deterministic fixtures for any implementation work.
- Update `docs/plans/hrrr-pressure-artifact-warmer-progress.md` before finishing.

### Forbidden

- Do not refactor the working surface GRIB path.
- Do not add pressure acquisition to the existing NWS alert polling loop.
- Do not move GRIB acquisition into Arcus-Anvil.
- Do not introduce Zarr, BUFKIT, native HRRR levels, or a new data platform.
- Do not add broad NOAA provider abstractions.
- Do not create a hidden on-demand fetch path from the request handler.
- Do not broaden the scope to general cold-start optimization for unrelated features.
- Do not change notification/APNs behavior as part of this work.

If a future-facing seam is required, keep it:
- narrow
- replaceable
- documented in the progress log

---

## Target Architecture

The warmer is a separate planning and scheduling layer around existing pressure-artifact work.

### Core shape

- The existing request path remains read-only with respect to pressure artifact acquisition.
- A dedicated warmer path prepares pressure artifacts ahead of demand.
- The warmer writes artifacts to cache or durable local storage using deterministic keys.
- Request handlers consume warmed artifacts if present.
- If the artifact is absent or stale, the request path degrades gracefully instead of fetching cold data.

### Boundary rules

- The surface GRIB path stays unchanged.
- Pressure warming does not become a new data platform.
- The warmer does not own storm-science interpretation.
- The warmer does not send notifications or manipulate APNs state.
- The warmer does not belong inside Arcus-Anvil.

### Operational intent

- Keep warming behavior predictable and easy to reason about.
- Keep the cache identity explicit enough to diagnose stale or mismatched artifacts.
- Keep request-path work bounded to read, validate, and degrade.

### Verified guardrails

- Worker and API must point at the artifact cache using the same absolute path.
- The expanded 185-message pressure artifact was approximately 121 MiB during local testing.
- `STORM_SETUP_GRIB_MAX_BYTES` must be high enough for the expanded artifact; `209715200` bytes was the tested value.
- Warm diagnostics must show a `wrfprsf` source URL, not a `wrfsfcf` source URL.

---

## Issue Sequence

Work these issues sequentially:

1. `#114` - 01: Create HRRR pressure artifact warmer planning docs
2. `#115` - 02: First runtime warmer slice

Do not execute later issues before earlier ones complete.

Do not parallelize pressure-artifact warmer issues under a parent coordinator.

---

## Artifact Lifecycle

Treat pressure artifacts as versioned, replaceable cached outputs.

### Lifecycle stages

- `missing`
  - No warmed artifact exists for the requested key.
  - The request path must not start a cold fetch.

- `warming`
  - A dedicated warmer job is preparing the artifact.
  - Duplicate warming attempts should collapse under deterministic identity or DB/queue uniqueness.

- `ready`
  - The artifact is available for request-path consumption.
  - Consumers should prefer the latest valid artifact for the matching key and field-set version.

- `stale`
  - The artifact exists but no longer matches the current key, field-set version, or freshness policy.
  - Request handling should degrade rather than trigger acquisition.

- `failed`
  - The warmer could not produce the artifact.
  - Follow the rollback/degradation behavior below.

### Lifecycle rules

- Artifact identity must include the source metadata required to prevent collisions.
- Field-set version changes must invalidate prior artifacts explicitly.
- A warmed artifact may be superseded, but the old artifact must remain diagnosable until retention cleanup.
- Request-path reads must not mutate lifecycle state except for safe bookkeeping such as last-seen timestamps if those are already part of the design.

---

## Queue and Scheduling Behavior

The warmer must be driven by explicit scheduling, not by the live request path.

### Requirements

- Use a dedicated warmer job or queue lane when runtime work begins.
- Keep scheduling separate from the existing NWS alert polling loop.
- Preserve sequential issue implementation so the first runtime slice can be validated in isolation.
- Ensure warmer work is idempotent and safe to retry.
- Prefer bounded concurrency and explicit backpressure over hidden fan-out.

### Scheduling constraints

- The warmer should not fire on every request.
- The warmer should not be coupled to the normal alert polling cadence.
- If a scheduler exists, it should enqueue warming work only for missing or stale artifacts that are within the current operational policy.
- If a queue is unavailable or degraded, the request path still must not acquire cold artifacts.

---

## Request-Path Behavior

The request path must remain conservative.

### Required behavior

- Read warmed pressure artifacts when present and valid.
- Do not start pressure artifact acquisition from the normal storm-setup/current request path.
- Do not block the request path on a cold artifact fetch.
- If the artifact is missing, stale, or failed, return the best available degraded response rather than expanding the path.
- Preserve the existing surface GRIB path and its behavior.

### Degradation rules

- Missing warmed artifact does not equal request failure by default.
- Missing warmed artifact should surface as degraded or incomplete pressure data, not as a silent cold fetch.
- If a later issue adds stronger failure semantics, those semantics must be documented before implementation.

---

## Cache Keys and Field-Set Versioning

Cache identity must be explicit and boring.

### Cache key requirements

- Include HRRR source identity.
- Include run time.
- Include forecast hour.
- Include valid time when relevant to identity.
- Include the selected pressure field set.
- Include a field-set version.
- Include any message-selection identity required to prevent accidental reuse.

### Field-set versioning

- Treat the pressure field set as versioned API, not an implementation detail.
- Increment the field-set version when the warmer changes the selected pressure variables, levels, or message group in a way that would affect the resulting artifact.
- Do not reuse incompatible artifacts across field-set versions.
- Make the version visible in progress logs and debugging output.

### Retention implications

- Old cache entries may remain on disk until cleanup, but they must not be treated as current when the version changes.
- A version bump should be enough to force consumers onto the new artifact shape without manual cache surgery.

---

## Operational Guardrails

- Keep the normal storm-setup/current request path free of cold acquisition.
- Keep the existing surface GRIB path unchanged.
- Keep all acquisition concerns out of Arcus-Anvil.
- Keep implementation sequential and issue-scoped.
- Prefer explicit keys and small helper types over hidden convention.
- Prefer deterministic fixtures and offline verification.
- Preserve idempotency for any job or queue work.
- Do not add broad abstractions to cover future data sources that do not yet exist.
- Make degradation obvious in progress notes and request-path behavior.

---

## Known Risks

- A warmer can accidentally become a second request-time fetch path if boundaries are not enforced.
- Cache identity drift can cause stale artifacts to be reused across field-set changes.
- Coupling to the existing alert loop would create timing pressure and hidden failure modes.
- If the surface GRIB path is touched, regressions could spread into currently working behavior.
- Overfitting the first warmer slice to future needs could produce avoidable complexity.

---

## Rollback and Degradation Behavior

If the warmer is partially implemented or fails operationally:

- Leave the existing request path intact.
- Disable or stop the warmer scheduling path.
- Keep cached artifacts readable if they are still valid, but do not treat them as required for correctness.
- Fall back to degraded pressure output rather than cold acquisition on request.
- Document the failure and any manual cleanup required in the progress log.

Rollback should prefer turning off warming over broad code rollback when the request path remains healthy.

---

## Completion Checklist

Before finishing any sub-issue:

- Current issue acceptance criteria are satisfied or a blocker is documented.
- The surface GRIB path still behaves as expected if the issue touches shared Storm Setup code.
- No cold pressure artifact acquisition was added to the live request path.
- No warming logic was added to the NWS alert polling loop.
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md` is updated.
- The final response names verification that actually ran.
