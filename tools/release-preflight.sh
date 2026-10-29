#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/release-common.sh"
if [[ $# == 1 && "$1" == --help ]]; then
  cat <<'EOF'
Usage: tools/release-preflight.sh vMAJOR.MINOR.PATCH [--baseline-meso-gate false|true] [--expected-meso-gate false|true]
Read-only readiness check; never pulls images or starts containers.
Uses the newest readable *.dump in ~/backups/arcus-signal. Override with
ARCUS_RELEASE_BACKUP_FILE or ARCUS_RELEASE_BACKUP_DIR (custom/tar archives).
ARCUS_RELEASE_BACKUP_MAX_AGE_HOURS defaults to 24. Archive readability does
not prove a tested restore. Exit: 0 ready, 2 invocation, 3 unavailable, 4 unsafe.
EOF
  exit 0
fi
[[ $# -ge 1 ]] && release_tag_valid "$1" || release_die 2 'Supply a vMAJOR.MINOR.PATCH tag followed by optional meso expectations.'
tag="$1"
shift
baseline_gate=false expected_gate=false
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 && ( "$2" == false || "$2" == true ) ]] || release_die 2 'Meso expectations require literal false or true.'
  case "$1" in
    --baseline-meso-gate) baseline_gate="$2";;
    --expected-meso-gate) expected_gate="$2";;
    *) release_die 2 'Unknown release option.';;
  esac
  shift 2
done
# Gate configuration must survive a fresh Compose process.
unset MESO_NOTIFICATIONS_ENABLED
export ARCUS_SIGNAL_IMAGE_TAG="$tag"
release_require git stat sort python3
release_docker_check
python3 "$RELEASE_ROOT/tools/lib/release-pin.py" --check "$RELEASE_ROOT/.env" "$tag"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || release_die 4 'Tracked files are modified; review and commit the release tooling before deploying.'
config="$(release_compose config --format json 2>/dev/null)" || release_die 3 'Compose configuration resolution failed.'
# Match the database used by read-only verification to the API/worker database.
# External databases require a separately reviewed verification connection.
printf '%s' "$config" | jq -e --arg image "$RELEASE_IMAGE:$tag" --arg gate "$expected_gate" '
  .services as $s |
  ($s.api.image == $image and $s.worker.image == $image) and
  ($s.api.environment.MESO_NOTIFICATIONS_ENABLED == $gate and $s.worker.environment.MESO_NOTIFICATIONS_ENABLED == $gate) and
  ($s.api.environment.VAPOR_ENV == "production" and $s.worker.environment.VAPOR_ENV == "production") and
  ($s.api.environment.DATABASE_URL == $s.worker.environment.DATABASE_URL) and
  ($s.api.environment.REDIS_URL | type == "string" and length > 0) and
  ($s.api.environment.REDIS_URL == $s.worker.environment.REDIS_URL) and
  ($s.api.environment.DATABASE_URL | capture("^postgres(?:ql)?://(?<authority>[^/]+)/(?<database>[^?]+)(?:[?].*)?$") |
    (.authority | endswith("@postgres:5432")) and .database == $s.postgres.environment.POSTGRES_DB)
' >/dev/null 2>&1 || release_die 4 'Compose must resolve the requested images, production environment, matching explicit database/Redis URLs, local Compose PostgreSQL, and API/worker meso gates matching --expected-meso-gate.'
unset config
api="$(release_service api)" || release_die 3 'API inspection failed.'
worker="$(release_service worker)" || release_die 3 'Worker inspection failed.'
jq -ne --argjson api "$api" --argjson worker "$worker" --arg gate "$baseline_gate" '
  $api.running and $worker.running and $api.image == $worker.image and
  $api.imageID == $worker.imageID and $api.mesoGate == $gate and $worker.mesoGate == $gate
' >/dev/null || release_die 4 'Current API/worker must be running matching images with explicit meso gates matching --baseline-meso-gate.'
current="$(jq -r '.image | split(":") | last' <<< "$api")"
release_tag_valid "$current" || release_die 4 'Current application image is not a stable versioned release.'
[[ "$(printf '%s\n' "$current" "$tag" | sort -V | tail -n 1)" == "$tag" ]] || release_die 4 'Downgrade requires a separately approved database-compatible rollback.'
release_json="$(curl -fsS --connect-timeout 5 --max-time 20 "https://api.github.com/repos/justinrooks/arcus-signal/releases/tags/$tag" 2>/dev/null)" || release_die 3 'Requested GitHub release is unavailable.'
jq -e --arg tag "$tag" '.tag_name == $tag and .draft == false and .prerelease == false and .published_at != null' <<< "$release_json" >/dev/null || release_die 4 'Requested tag is not a published stable GitHub release.'
timeout 30 docker manifest inspect "$RELEASE_IMAGE:$tag" >/dev/null 2>&1 || release_die 3 'Requested GHCR image is unavailable to this Docker client.'
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
jq -nc --arg tag "$tag" --arg previousTag "$current" --arg checkedAt "$(release_now)" --argjson age "$backup_age" --arg baselineGate "$baseline_gate" --arg expectedGate "$expected_gate" \
  '{schemaVersion:1,status:"passed",targetTag:$tag,baselineMesoGate:$baselineGate,expectedMesoGate:$expectedGate,previousTag:$previousTag,checkedAt:$checkedAt,backup:{archiveReadable:true,ageSeconds:$age,restoreTested:false}}'
