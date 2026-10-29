#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/release-common.sh"
usage() { echo 'Usage: tools/release-snapshot.sh [--expected-tag vMAJOR.MINOR.PATCH] [--expected-meso-gate false|true] [--since UTC_TIMESTAMP [--attributable-since UTC_TIMESTAMP]] [--json] [--output FILE]'; }
expected_gate=false
tag='' since='' attributable_since='' output='' json=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-meso-gate|--expected-tag|--since|--attributable-since|--output)
      [[ $# -ge 2 && -n "$2" ]] || release_die 2 'Missing option value.'
      case "$1" in --expected-meso-gate) expected_gate="$2";; --expected-tag) tag="$2";; --since) since="$2";; --attributable-since) attributable_since="$2";; --output) output="$2";; esac
      shift 2 ;;
    --json) json=1; shift;;
    --help|-h) usage; exit 0;;
    *) usage >&2; exit 2;;
  esac
done
[[ "$expected_gate" == false || "$expected_gate" == true ]] || release_die 2 'Expected meso gate must be literal false or true.'
[[ -z "$tag" ]] || release_tag_valid "$tag" || release_die 2 'Invalid expected tag.'
[[ -z "$since" ]] || release_timestamp_valid "$since" || release_die 2 'Use a UTC ISO timestamp, optionally with fractional seconds.'
if [[ -n "$attributable_since" ]]; then
  [[ -n "$since" ]] && release_timestamp_valid "$attributable_since" || release_die 2 '--attributable-since requires --since and a UTC ISO timestamp.'
  [[ "$(release_timestamp_key "$attributable_since")" < "$(release_timestamp_key "$since")" ]] && release_die 2 'Attribution boundary must not precede the evidence boundary.'
fi
attributable_since="${attributable_since:-$since}"
[[ -z "$tag" ]] || export ARCUS_SIGNAL_IMAGE_TAG="$tag"
release_require jq
emit() {
  if [[ -n "$output" ]]; then
    [[ -d "$(dirname "$output")" ]] || release_die 3 'Output directory must already exist.'
    release_write "$output" "$result"
  fi
  if [[ "$json" == 1 ]]; then printf '%s\n' "$result" | jq .
  else printf '%s' "$result" | jq -r '"Snapshot: \(.status) | collection \(.collectionStatus) | infrastructure \(.infrastructureStatus // "unknown") | expected meso \(.expectedMesoGate // "unknown") | operations \(.operationalStatus // "unknown")"'; fi
}
# Docker errors are collection failures, never apparently valid missing-service results.
if ! (release_docker_check) >/dev/null 2>&1; then
  result="$(jq -nc --arg at "$(release_now)" '{schemaVersion:2,capturedAt:$at,status:"failed",collectionStatus:"failed",error:"docker_access_or_configuration_failed"}')"
  emit; exit 3
fi
services='{}'
for service in api worker postgres redis; do
  if ! info="$(release_service "$service")"; then
    result="$(jq -nc --arg service "$service" --arg at "$(release_now)" '{schemaVersion:2,capturedAt:$at,status:"failed",collectionStatus:"failed",error:"docker_inspection_failed",service:$service}')"
    emit; exit 3
  fi
  services="$(jq -c --arg service "$service" --argjson info "$info" '. + {($service):$info}' <<< "$services")"
done
api_http=false worker_http=false
curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8080/health >/dev/null 2>&1 && api_http=true
curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8081/health >/dev/null 2>&1 && worker_http=true
metrics=null
metrics_error=''
if raw="$(curl -fsS --connect-timeout 2 --max-time 8 http://127.0.0.1:8080/v1/metrics 2>/dev/null)"; then
  if ! metrics="$(printf '%s' "$raw" | jq -ec '
    select(.redLights.ingestFreshness.status != null) |
    {generatedAt,
     nwsIngest:(.redLights.ingestFreshness | {status,refreshedAt,timeSinceLastSuccessfulSweepSeconds,recentSuccessCount,recentFailureCount}),
     mesoIngest:(.redLights.spcMesoIngest | {status,refreshedAt,lastAttemptAt,lastSuccessfulAt,lastAttemptAgeSeconds,lastAttemptStatus,recentFailureCount}),
     backlog:(.redLights.pipelineBacklogAge | {status,refreshedAt,pendingTargetDispatchCount,oldestPendingTargetDispatchAgeSeconds,pendingNotificationDispatchCount,oldestPendingNotificationDispatchAgeSeconds}),
     stuckClaims:(.redLights.stuckClaimedRows | {status,refreshedAt,count,oldestClaimedAgeSeconds}),
     delivery:(.deliveryKPIs.apnsDeliverySuccessRate | {refreshedAt,windowHours,sentCount,failedCount,successRate,topFailureReasons}),
     noOps:(.deliveryKPIs.sendNoOpRateByReason | {refreshedAt,totalAttemptCount,noOpAttemptCount,noOpRate})}
  ' 2>/dev/null)"; then metrics=null; metrics_error=metrics_invalid; fi
else metrics_error=metrics_unavailable
fi
unset raw
post_delivery=null
if [[ -n "$since" ]]; then
  if ! post_delivery="$(release_psql -v since="$since" -v attributable_since="$attributable_since" \
    < "$RELEASE_ROOT/tools/sql/release-delivery-evidence.sql" 2>/dev/null)"; then post_delivery=null; fi
fi
result="$(jq -nc --arg expectedGate "$expected_gate" --arg at "$(release_now)" --arg tag "$tag" --arg since "$since" --arg attributableSince "$attributable_since" --arg metricsError "$metrics_error" \
  --argjson services "$services" --argjson apiHttp "$api_http" --argjson workerHttp "$worker_http" \
  --argjson metrics "$metrics" --argjson postDelivery "$post_delivery" \
  '{schemaVersion:2,capturedAt:$at,expectedTag:$tag,expectedMesoGate:$expectedGate,deliverySince:$since,deliveryAttributableSince:$attributableSince,collectionStatus:"passed",
    services:$services,httpHealth:{api:$apiHttp,worker:$workerHttp},metrics:$metrics,metricsError:$metricsError,postDeployDelivery:$postDelivery}' \
  | jq -c -f "$RELEASE_ROOT/tools/lib/release-snapshot.jq")"
emit
case "$(printf '%s' "$result" | jq -r .status)" in passed) exit 0;; attention) exit 1;; *) exit 4;; esac
