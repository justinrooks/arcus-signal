---
name: arcus-signal-release
description: Deploy an explicitly requested Arcus Signal version on its server, then observe ingestion, queues, and delivery for 12 minutes. Use for requests such as "release v1.4.2"; require an explicit version.
---

# Arcus Signal release

Operate from this checkout on the deployment host. `install` owns deployment;
`tools/release-observe.sh` owns timed observation. Read `AGENTS.md`, the requested
version's release notes, and relevant delivery invariants in `docs/architecture.md`.
Do not publish a GitHub release or substitute a different version.

## Version and authorization

Accept one complete stable version, `vMAJOR.MINOR.PATCH`; a bare version may be
normalized by adding `v`. Reject leading zeroes, prerelease/build suffixes, and
`latest`. Retain that exact normalized tag across follow-ups. If none was supplied,
ask for it before starting. Never infer a tag from the checkout or release list.

An explicit instruction such as **"release v1.4.2" authorizes preflight, one install,
and bounded observation**. Announce the target and proceed without a second
conversational approval. Runtime execution approvals remain enforced; request the
specific command through that boundary when needed, explaining its source.
Investigation and editing this skill do not authorize deployment.

## Execute

1. Run `./install <tag>` **once**. It locks the checkout, checks the published stable
   release and GHCR image, verifies configuration and a backup, saves a baseline,
   pulls the image, checks packaged binaries, migrates using production configuration,
   verifies the schema, starts API/worker, checks image identities and HTTP health,
   and atomically saves the successful image tag in `.env`. Preflight requires
   Python 3 and a writable regular `.env` file and directory.
   `./tools/release-preflight.sh <tag>` is available for a standalone readiness check.
2. Use the printed `deployment.json` path. If installation failed, inspect its
   `failedPhase`, `completedPhases`, and `migrationState`; stop deployment actions.
   `uncertain` or `completed` migrations may have committed changes. Inspect ledger
   **and schema** before proposing an explicitly approved retry or rollback.
3. On success, confirm `persistedTag` equals the requested tag and
   `saved_configuration_verification` is in `completedPhases`. Independently check
   `env -u ARCUS_SIGNAL_IMAGE_TAG docker compose --env-file .env config --images`
   after the installer exits; both application images must select the requested
   release. This prints image references only. Missing or mismatched saved selection
   is a failed deployment check; do not recreate services or silently repair it.
   Then immediately run
   `./tools/release-observe.sh --deployment <absolute-path-to-deployment.json>`.
   It samples immediately and at **2, 7, and 12 minutes** from observation start.
   When the tool yields, poll its running session and provide progress updates.
   Never claim observations that have not actually completed.
4. Read the resulting `observation.json`. Report target/revision/digest, saved image tag, previous
   images, migration/schema result, rollout gates, observation times, NWS/SPC status,
   backlog/claim changes, and delivery confidence. Include `findings` from the whole
   window, with recovered/unresolved states and baseline context; recovered warnings
   remain visible even when the final status passes.

## Operating rules

- Use direct Docker access. Access/inspection errors are collection failures,
  not missing services. Do not add `sudo` or change host permissions to bypass an error.
- Meso delivery stays **explicitly false on API and worker through v1.4.1 and later
  versions until the separately approved app cutover**. An enabled gate blocks release;
  this workflow does not change it.
- Backups default to the newest readable `*.dump` in `~/backups/arcus-signal`.
  `ARCUS_RELEASE_BACKUP_FILE` or `ARCUS_RELEASE_BACKUP_DIR` overrides discovery;
  `ARCUS_RELEASE_BACKUP_MAX_AGE_HOURS` defaults to 24. Archive readability and age
  do not prove a tested restore. Missing/stale/invalid evidence blocks deployment;
  do not create or restore backups implicitly.
- A recent successful SPC attempt can warn after ten minutes because the schedule
  also runs every ten minutes. One age-only warning calls for a recheck. Continued
  staleness or failed attempts require investigation; report an unresolved warning
  at the end of the observation window.
- Rolling 24-hour APNs counts are historical activity. `observed` requires a successful
  ledger completion after the new worker image is verified. Count evidence from
  rollout start: earlier overlapping completions remain ambiguously attributed,
  including those before installer checks finish. Overlap-only traffic is `ambiguous`;
  no traffic is `unobserved`, not failed delivery.
  HTTP `/health` proves response availability only.
- Evidence contains coarse operational fields only and lives in private temporary
  run directories outside the repo. Never print `.env`, credentials, APNs material,
  installation identities, precise locations, raw dashboard responses, or raw logs.
- No automatic retry, rollback, schema repair, queue cleanup, synthetic alerts, or
  test pushes. A rollback needs separate approval and compatibility with the already
  migrated database; selecting an older image does not revert schema or data.
- Monitoring ends with this bounded session. For a concern, inspect bounded,
  sanitized logs or narrow read-only queries and recommend the next action.
