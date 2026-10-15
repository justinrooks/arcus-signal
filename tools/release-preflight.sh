#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/release-common.sh"
if [[ $# == 1 && "$1" == --help ]]; then
  cat <<'EOF'
Usage: tools/release-preflight.sh vMAJOR.MINOR.PATCH
Read-only readiness check; never pulls images or starts containers.
Uses the newest readable *.dump in ~/backups/arcus-signal. Override with
ARCUS_RELEASE_BACKUP_FILE or ARCUS_RELEASE_BACKUP_DIR (custom/tar archives).
ARCUS_RELEASE_BACKUP_MAX_AGE_HOURS defaults to 24. Archive readability does
not prove a tested restore. Exit: 0 ready, 2 invocation, 3 unavailable, 4 unsafe.
EOF
  exit 0
fi
[[ $# == 1 ]] && release_tag_valid "$1" || release_die 2 'Supply exactly one vMAJOR.MINOR.PATCH tag.'
export ARCUS_SIGNAL_IMAGE_TAG="$1"
release_require git stat sort
release_docker_check
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || release_die 4 'Tracked files are modified; review and commit the release tooling before deploying.'
config="$(release_compose config --format json 2>/dev/null)" || release_die 3 'Compose configuration resolution failed.'
# Match the database used by read-only verification to the API/worker database.
# External databases require a separately reviewed verification connection.
printf '%s' "$config" | jq -e --arg image "$RELEASE_IMAGE:$1" '
  .services as $s |
  ($s.api.image == $image and $s.worker.image == $image) and
  ($s.api.environment.MESO_NOTIFICATIONS_ENABLED == "false" and $s.worker.environment.MESO_NOTIFICATIONS_ENABLED == "false") and
  ($s.api.environment.VAPOR_ENV == "production" and $s.worker.environment.VAPOR_ENV == "production") and
  ($s.api.environment.DATABASE_URL == $s.worker.environment.DATABASE_URL) and
  ($s.api.environment.REDIS_URL | type == "string" and length > 0) and
  ($s.api.environment.REDIS_URL == $s.worker.environment.REDIS_URL) and
  ($s.api.environment.DATABASE_URL | capture("^postgres(?:ql)?://(?<authority>[^/]+)/(?<database>[^?]+)(?:[?].*)?$") |
    (.authority | endswith("@postgres:5432")) and .database == $s.postgres.environment.POSTGRES_DB)
' >/dev/null 2>&1 || release_die 4 'Compose must resolve the requested images, production environment, matching explicit database/Redis URLs, local Compose PostgreSQL, and false meso gates.'
unset config
api="$(release_service api)" || release_die 3 'API inspection failed.'
worker="$(release_service worker)" || release_die 3 'Worker inspection failed.'
jq -ne --argjson api "$api" --argjson worker "$worker" '
  $api.running and $worker.running and $api.image == $worker.image and
  $api.imageID == $worker.imageID and $api.mesoGate == "false" and $worker.mesoGate == "false"
' >/dev/null || release_die 4 'Current API/worker must be running matching images with meso disabled.'
current="$(jq -r '.image | split(":") | last' <<< "$api")"
release_tag_valid "$current" || release_die 4 'Current application image is not a stable versioned release.'
[[ "$(printf '%s\n' "$current" "$1" | sort -V | tail -n 1)" == "$1" ]] || release_die 4 'Downgrade requires a separately approved database-compatible rollback.'
release_json="$(curl -fsS --connect-timeout 5 --max-time 20 "https://api.github.com/repos/justinrooks/arcus-signal/releases/tags/$1" 2>/dev/null)" || release_die 3 'Requested GitHub release is unavailable.'
jq -e --arg tag "$1" '.tag_name == $tag and .draft == false and .prerelease == false and .published_at != null' <<< "$release_json" >/dev/null || release_die 4 'Requested tag is not a published stable GitHub release.'
timeout 30 docker manifest inspect "$RELEASE_IMAGE:$1" >/dev/null 2>&1 || release_die 3 'Requested GHCR image is unavailable to this Docker client.'
backup="${ARCUS_RELEASE_BACKUP_FILE:-}"
if [[ -z "$backup" ]]; then
  backup_dir="${ARCUS_RELEASE_BACKUP_DIR:-$HOME/backups/arcus-signal}"
  for candidate in "$backup_dir"/*.dump; do
    [[ -f "$candidate" && -r "$candidate" ]] || continue
    if [[ -z "$backup" || "$candidate" -nt "$backup" ]]; then backup="$candidate"; fi
  done
fi
max_age="${ARCUS_RELEASE_BACKUP_MAX_AGE_HOURS:-24}"
[[ "$max_age" =~ ^[1-9][0-9]{0,3}$ ]] || release_die 2 'Backup maximum age must be a positive number of hours (at most four digits).'
[[ -n "$backup" && -f "$backup" && -r "$backup" && -s "$backup" ]] || release_die 4 'Set ARCUS_RELEASE_BACKUP_FILE to an existing readable PostgreSQL custom/tar backup.'
backup_age=$(( $(date +%s) - $(stat -c %Y "$backup") ))
(( backup_age >= 0 && backup_age <= max_age * 3600 )) || release_die 4 'PostgreSQL backup timestamp is outside the allowed age.'
release_compose exec -T postgres pg_restore --list < "$backup" >/dev/null 2>&1 || release_die 4 'PostgreSQL backup archive cannot be read by pg_restore.'
jq -nc --arg tag "$1" --arg previousTag "$current" --arg checkedAt "$(release_now)" --argjson age "$backup_age" \
  '{schemaVersion:1,status:"passed",targetTag:$tag,previousTag:$previousTag,checkedAt:$checkedAt,backup:{archiveReadable:true,ageSeconds:$age,restoreTested:false}}'
