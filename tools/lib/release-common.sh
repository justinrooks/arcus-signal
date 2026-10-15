#!/usr/bin/env bash
# Shared release mechanics. Callers enable set -Eeuo pipefail.
RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_IMAGE=ghcr.io/justinrooks/arcus-signal
cd "$RELEASE_ROOT"
umask 077

release_die() { printf '%s\n' "$2" >&2; exit "$1"; }
release_require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || release_die 3 "Missing prerequisite: $tool"
  done
}
release_tag_valid() { [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }
release_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
release_now_precise() { date -u '+%Y-%m-%dT%H:%M:%S.%NZ'; }
release_timestamp_valid() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?Z$ ]]; }
release_timestamp_key() {
  local value="${1%Z}" fraction=000000000
  if [[ "$value" == *.* ]]; then fraction="${value#*.}000000000"; value="${value%%.*}"; fi
  printf '%s.%.9s' "$value" "$fraction"
}
release_compose() { timeout --foreground 60 docker compose --project-directory "$RELEASE_ROOT" --env-file "$RELEASE_ROOT/.env" "$@"; }
release_docker_check() {
  release_require docker timeout jq curl date
  [[ -f .env ]] || release_die 3 'Missing deployment .env.'
  timeout 10 docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || release_die 3 'Docker access failed; no services have been classified as missing.'
  timeout 10 docker compose version >/dev/null 2>&1 || release_die 3 'Docker Compose is unavailable.'
}
release_write() {
  # Atomic artifacts; run directories are private and created with mktemp.
  local path="$1" value="$2"
  printf '%s\n' "$value" > "$path.tmp"
  mv "$path.tmp" "$path"
}
release_psql() {
  # Credentials stay inside the existing PostgreSQL container. Output is aggregates only.
  release_compose exec -T postgres sh -c '
    export PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=10000 -c lock_timeout=2000"
    export PGAPPNAME=arcus_release_verification
    exec psql -X -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"
  ' sh "$@"
}
release_service() {
  local service="$1" id details
  id="$(release_compose ps --all -q "$service" 2>/dev/null)" || return 3
  if [[ -z "$id" ]]; then
    jq -nc '{running:false,image:null,imageID:null,health:"missing",mesoGate:null}'
    return
  fi
  [[ "$id" != *$'\n'* ]] || return 3
  details="$(timeout 10 docker inspect --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null)" || return 3
  # Select only approved configuration fields inside the Docker template.
  local image image_id gate
  image="$(timeout 10 docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null)" || return 3
  image_id="$(timeout 10 docker inspect --format '{{.Image}}' "$id" 2>/dev/null)" || return 3
  gate="$(timeout 10 docker inspect --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "MESO_NOTIFICATIONS_ENABLED"}}{{index (split . "=") 1}}{{end}}{{end}}' "$id" 2>/dev/null)" || return 3
  local running health
  IFS='|' read -r running health <<< "$details"
  jq -nc --arg running "$running" --arg health "$health" --arg image "$image" --arg imageID "$image_id" --arg gate "$gate" \
    '{running:($running=="true"),image:$image,imageID:$imageID,health:$health,mesoGate:(if $gate=="" then null else $gate end)}'
}
