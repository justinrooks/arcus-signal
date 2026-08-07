# HRRR Pressure Profile

This document is the short operational reference for the completed HRRR pressure-profile path in Arcus Signal.

It is not a new design proposal. It records the finished byte-range implementation so the next maintainer does not have to reconstruct the contract from issue history.

## What It Does

- Resolves an H3 cell to a centroid internally.
- Builds the HRRR `wrfprsf` source metadata for the requested run and forecast hour.
- Reads the upstream `.idx` inventory.
- Selects only the pressure-profile GRIB messages required for Anvil.
- Downloads those messages with HTTP byte ranges.
- Caches the resulting pressure subset separately from the existing surface GRIB flow.
- Samples the subset with the existing `wgrib2` plumbing.
- Builds the frozen Anvil profile request.
- Sends that profile to Arcus-Anvil.
- Treats Anvil output as ingredient evidence, not tornado or hail prediction.

## Current Boundary

- Byte-range `.idx` selection is the current pressure-profile behavior.
- The whole-file pressure GRIB cache path was retired and is not part of the supported flow.
- Surface HRRR flow remains unchanged.
- The server does not store raw user lat/lon for this path.
- The Anvil result is used as supporting evidence inside Storm Setup, not as a separate prediction product.

## Exact-Cycle Surface Row

Every Anvil profile begins with one surface row sampled from the HRRR `wrfsfc` product. The surface source must match the selected pressure artifact's model, domain, run time, forecast hour, and valid time. Arcus Signal does not substitute another cycle.

The dedicated `anvil-surface-v1` field set selects:

- `PRES` and `HGT` at `surface`
- `TMP` and `DPT` at `2 m above ground`
- `UGRD` and `VGRD` at `10 m above ground`

The loader deterministically selects the first matching value for each field, converts pressure from Pa to mb and temperature/dewpoint from K to Celsius, and requires all six values to be finite. Invalid pressure sentinel values are rejected. The normalized surface pressure remains a `Double`; it is not rounded to a standard pressure level.

The request builder requires this complete surface row in addition to at least five retained pressure levels. Surface pressure must be greater than the first pressure-level pressure, and surface height must be lower than the first pressure-level height.

## Runtime Configuration

### Shared Storm Setup

- `STORM_SETUP_CACHE_ROOT`
  - Base cache root for Storm Setup caches.
  - Pressure subset, pressure raw, and sampled snapshot caches are derived from this root.
- `STORM_SETUP_WGRIB2_PATH`
  - Path to the `wgrib2` executable.
- `STORM_SETUP_WGRIB2_TIMEOUT_SECONDS`
  - Timeout for `wgrib2` execution.
- `STORM_SETUP_GRIB_MAX_BYTES`
  - Maximum size for the existing surface GRIB subset cache.
- `STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS`
  - Per-request IDX and GRIB byte-range deadline for pressure-artifact warming. Defaults to `30`; missing, blank, malformed, non-finite, zero, and negative values use the default.
- `STORM_SETUP_PRESSURE_ARTIFACT_WARM_TIMEOUT_SECONDS`
  - Whole-attempt deadline after a pressure artifact is claimed. Defaults to `900` seconds and must remain positive, representable, and shorter than `STORM_SETUP_PRESSURE_ARTIFACT_RECOVERY_TIMEOUT_SECONDS`.
  - Recovery leases shorter than one second normalize to one second. Missing, malformed, non-finite, non-positive, unrepresentable, or lease-incompatible warm values use the smaller of `900` seconds and half the normalized recovery lease.

### Anvil Profile Analysis

- `ANVIL_PROFILE_ANALYSIS_BASE_URL`
  - Base URL for Arcus-Anvil profile analysis.
- `ANVIL_PROFILE_ANALYSIS_TIMEOUT_SECONDS`
  - Timeout for the Anvil profile-analysis request.
- Anvil profile-analysis POSTs use a single attempt in Arcus Signal.
  - The shared HTTP client still retries for other callers.
  - A transient transport failure is surfaced to the caller instead of replaying the analysis request.
  - This keeps duplicate upstream compute out of the Storm Setup path.

## Cache Layout

Under the configured Storm Setup cache root:

- `grib-subsets/`
  - Existing surface GRIB subset cache.
- `pressure-grib-subsets/`
  - Byte-range pressure subset cache.
- `sampled-snapshots/`
  - Cached sampled snapshot output.

The pressure caches are intentionally separate from the surface caches so the two flows do not collide.

## Operational Diagnostics

When the path fails, the useful signals are:

- Missing `.idx` inventory or unavailable source
  - Reported as upstream unavailability.
- Missing required pressure levels
  - Reported as an unusable profile, not a fabricated profile.
- Missing or invalid exact-cycle surface fields
  - Reported as an unusable profile with the affected `PRES`, `HGT`, `TMP`, `DPT`, `UGRD`, or `VGRD` field names.
- Partial-content download problems
  - The byte-range downloader expects valid partial-content responses and rejects ignored-range behavior.
- `wgrib2` execution failure
  - Treated as internal execution failure.
- Missing or degraded Anvil response fields
  - Surface as absent evidence or degraded confidence, not zeroes.
- Transient Anvil POST transport failure
  - Surface the failure directly; Arcus Signal does not retry the request inside Storm Setup.
- Development-only preview diagnostics
  - Report `surfacePressureMb` and `surfaceSubsetCacheHit` for exact-cycle surface inspection.
  - Keep those diagnostics out of `storm-setup/current`; the synthesized surface row stays internal to preview assembly and Anvil request construction.

The preview and analysis debug payloads should be used to inspect selected message counts, ranges, cache state, surface pressure/cache state, and missing levels.

## Degraded and Deferred Modes

- No live HRRR, NOMADS, or Anvil calls should be used in unit tests.
- There is no fallback from byte-range downloads to whole-file pressure downloads.
- There is no cross-cycle or fabricated fallback for a missing exact-cycle surface row.
- Surface-row failure stops profile assembly before Anvil dispatch.
- Pressure-level tuning remains a product decision, not a transport contract.
- Anvil severe-weather values are internal ingredient evidence, not user-facing tornado prediction language.
- Anvil profile-analysis POSTs are intentionally non-retrying to avoid duplicate upstream compute.

## Verification Record

The completed implementation trail and final verification commands are recorded in `docs/plans/hrrr-pressure-profile-progress.md`.
