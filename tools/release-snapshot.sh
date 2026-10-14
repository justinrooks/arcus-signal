#!/usr/bin/env bash
set -euo pipefail

# Read-only: emit only coarse operational fields, never secrets or raw metrics.
usage() { echo "Usage: $0 [--expected-tag vMAJOR.MINOR.PATCH] [--json] [--output PATH]" >&2; }
tag=""
json=0
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-tag) [[ $# -ge 2 ]] || { usage; exit 2; }; tag="$2"; shift 2 ;;
    --json) json=1; shift ;;
    --output) [[ $# -ge 2 ]] || { usage; exit 2; }; output="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
if [[ -n "$tag" && ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  usage; exit 2
fi
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Missing .env" >&2; exit 3; }
for tool in docker sudo curl jq date; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing prerequisite: $tool" >&2; exit 3; }
done

service_info() {
  local service="$1" id details running image health gate
  id="$(sudo docker compose --env-file .env ps -q "$service" 2>/dev/null || true)"
  if [[ -z "$id" ]]; then
    jq -nc '{running:false,image:null,health:"missing",mesoGate:null}'
    return
  fi
  details="$(sudo docker inspect --format '{{.State.Running}}|{{.Config.Image}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || true)"
  if [[ -z "$details" ]]; then
    jq -nc '{running:false,image:null,health:"inspect_failed",mesoGate:null}'
    return
  fi
  IFS='|' read -r running image health <<< "$details"
  gate="$(sudo docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null | sed -n 's/^MESO_NOTIFICATIONS_ENABLED=//p' | head -n 1 || true)"
  jq -nc --arg running "$running" --arg image "$image" --arg health "$health" --arg gate "$gate" \
    '{running:($running=="true"),image:$image,health:$health,mesoGate:$gate}'
}
api="$(service_info api)"
worker="$(service_info worker)"
postgres="$(service_info postgres)"
redis="$(service_info redis)"
api_http=false
worker_http=false
if curl -fsS --max-time 5 http://127.0.0.1:8080/health >/dev/null 2>&1; then api_http=true; fi
if curl -fsS --max-time 5 http://127.0.0.1:8081/health >/dev/null 2>&1; then worker_http=true; fi

# Read /v1/metrics into memory and discard the raw response immediately.
metrics="null"
raw="$(curl -fsS --max-time 8 http://127.0.0.1:8080/v1/metrics 2>/dev/null || true)"
if [[ -n "$raw" ]]; then
  selected="$(printf '%s' "$raw" | jq -ec '
    select(.redLights.ingestFreshness.status != null) |
    {generatedAt,
     nwsIngest:(.redLights.ingestFreshness | {status,refreshedAt,timeSinceLastSuccessfulSweepSeconds,recentSuccessCount,recentFailureCount}),
     mesoIngest:(.redLights.spcMesoIngest | {status,lastAttemptAgeSeconds,lastAttemptStatus,recentFailureCount}),
     backlog:(.redLights.pipelineBacklogAge | {status,pendingTargetDispatchCount,oldestPendingTargetDispatchAgeSeconds,pendingNotificationDispatchCount,oldestPendingNotificationDispatchAgeSeconds}),
     stuckClaims:(.redLights.stuckClaimedRows | {status,count,oldestClaimedAgeSeconds}),
     delivery:(.deliveryKPIs.apnsDeliverySuccessRate | {refreshedAt,windowHours,sentCount,failedCount,successRate,topFailureReasons}),
     noOps:(.deliveryKPIs.sendNoOpRateByReason | {totalAttemptCount,noOpAttemptCount,noOpRate})}
  ' 2>/dev/null || true)"
  if [[ -n "$selected" ]]; then metrics="$selected"; fi
fi
unset raw

result="$(jq -nc --arg capturedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg tag "$tag" \
  --argjson api "$api" --argjson worker "$worker" --argjson postgres "$postgres" --argjson redis "$redis" \
  --argjson apiHttp "$api_http" --argjson workerHttp "$worker_http" --argjson metrics "$metrics" '
  {schemaVersion:1,capturedAt:$capturedAt,expectedTag:(if $tag=="" then null else $tag end),
   services:{api:$api,worker:$worker,postgres:$postgres,redis:$redis},
   httpHealth:{api:$apiHttp,worker:$workerHttp},metrics:$metrics}
  | . + {status: (
    if ([$api,$worker,$postgres,$redis] | any(.running != true))
       or $postgres.health != "healthy" or $redis.health != "healthy"
       or $apiHttp != true or $workerHttp != true or $api.mesoGate != $worker.mesoGate
       or ($tag != "" and ($api.image != ("ghcr.io/justinrooks/arcus-signal:" + $tag)
            or $worker.image != ("ghcr.io/justinrooks/arcus-signal:" + $tag)))
    then "failed"
    elif $metrics == null then "attention"
    else "passed" end
  )}' )"
if [[ -n "$output" ]]; then
  umask 077
  mkdir -p "$(dirname "$output")"
  printf '%s\n' "$result" > "$output"
fi
if [[ "$json" -eq 1 ]]; then
  printf '%s\n' "$result" | jq .
else
  printf '%s\n' "$result" | jq -r '"Release snapshot: \(.status) | API \(.services.api.image // "missing") | Worker \(.services.worker.image // "missing") | NWS ingest \(.metrics.nwsIngest.status // "unavailable") | APNs sent/failed \(.metrics.delivery.sentCount // "n/a")/\(.metrics.delivery.failedCount // "n/a")"'
fi
case "$(printf '%s' "$result" | jq -r '.status')" in
  passed) exit 0 ;;
  attention) exit 1 ;;
  *) exit 4 ;;
esac
