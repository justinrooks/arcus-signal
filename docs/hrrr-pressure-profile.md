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
- Whole-file pressure GRIB download is not the primary path.
- Surface HRRR flow remains unchanged.
- The server does not store raw user lat/lon for this path.
- The Anvil result is used as supporting evidence inside Storm Setup, not as a separate prediction product.

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
- `STORM_SETUP_PRESSURE_GRIB_MAX_BYTES`
  - Maximum size for the pressure raw cache.

### Anvil Profile Analysis

- `ANVIL_PROFILE_ANALYSIS_BASE_URL`
  - Base URL for Arcus-Anvil profile analysis.
- `ANVIL_PROFILE_ANALYSIS_TIMEOUT_SECONDS`
  - Timeout for the Anvil profile-analysis request.

## Cache Layout

Under the configured Storm Setup cache root:

- `grib-subsets/`
  - Existing surface GRIB subset cache.
- `pressure-grib-subsets/`
  - Byte-range pressure subset cache.
- `pressure-grib-raw/`
  - Raw pressure GRIB cache used by the completed pressure-profile path.
- `sampled-snapshots/`
  - Cached sampled snapshot output.

The pressure caches are intentionally separate from the surface caches so the two flows do not collide.

## Operational Diagnostics

When the path fails, the useful signals are:

- Missing `.idx` inventory or unavailable source
  - Reported as upstream unavailability.
- Missing required pressure levels
  - Reported as an unusable profile, not a fabricated profile.
- Partial-content download problems
  - The byte-range downloader expects valid partial-content responses and rejects ignored-range behavior.
- `wgrib2` execution failure
  - Treated as internal execution failure.
- Missing or degraded Anvil response fields
  - Surface as absent evidence or degraded confidence, not zeroes.

The preview and analysis debug payloads should be used to inspect selected message counts, ranges, cache state, and missing levels.

## Degraded and Deferred Modes

- No live HRRR, NOMADS, or Anvil calls should be used in unit tests.
- There is no fallback from byte-range downloads to whole-file pressure downloads unless a future issue explicitly reopens that scope.
- Pressure-level tuning remains a product decision, not a transport contract.
- Anvil severe-weather values are internal ingredient evidence, not user-facing tornado prediction language.

## Verification Record

The completed implementation trail and final verification commands are recorded in `docs/plans/hrrr-pressure-profile-progress.md`.

