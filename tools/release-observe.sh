#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib/release-common.sh"
if [[ $# == 1 && "$1" == --help ]]; then
  echo 'Usage: tools/release-observe.sh --deployment /absolute/path/deployment.json'
  echo 'Read-only observation: snapshots now and at 2, 7, 12 minutes after observation starts.'
  echo 'Exit: 0 healthy, 1 attention/unknown, 2 invocation, 3 unavailable, 4 failed.'
  exit 0
fi
[[ $# == 2 && "$1" == --deployment && -r "$2" ]] || release_die 2 'Supply --deployment FILE from a successful install.'
release_require jq date sleep mktemp
record="$(realpath "$2")"
jq -e '.schemaVersion == 1 and .status == "passed" and .migrationState == "completed" and .applicationStarted == true' "$record" >/dev/null || release_die 4 'Deployment did not complete; inspect its failed phase before observing.'
tag="$(jq -r .targetTag "$record")"
release_tag_valid "$tag" || release_die 2 'Deployment record has an invalid tag.'
since="$(jq -r .finishedAt "$record")"
[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || release_die 2 'Invalid deployment completion timestamp.'
image_id="$(jq -r .imageID "$record")"
[[ "$image_id" == sha256:* ]] || release_die 2 'Deployment record lacks its image identity.'
base="$(jq -r .baseline "$record")"
[[ -r "$base" ]] || release_die 3 'Baseline evidence is unavailable.'
run_dir="$(mktemp -d "$(dirname "$record")/observation.XXXXXXXX")"
start_epoch="$(date +%s)"
started_at="$(release_now)"
snapshots='[]'
write_report() {
  release_write "$run_dir/observation.json" "$(jq -n \
    --arg tag "$tag" --arg started "$started_at" --arg finished "$(release_now)" \
    --argjson snapshots "$snapshots" --slurpfile baseline "$base" \
    '{schemaVersion:1,targetTag:$tag,startedAt:$started,finishedAt:$finished,
      expectedOffsetsSeconds:[0,120,420,720],snapshots:$snapshots,baseline:$baseline[0]}' \
    | jq -c -f "$RELEASE_ROOT/tools/lib/release-observe.jq")"
}
trap 'write_report; exit 130' INT
trap 'write_report; exit 143' TERM
for offset in 0 120 420 720; do
  while (( $(date +%s) < start_epoch + offset )); do
    remaining=$(( start_epoch + offset - $(date +%s) ))
    (( remaining > 30 )) && remaining=30
    (( remaining > 0 )) && sleep "$remaining"
  done
  snapshot="$run_dir/after-${offset}s.json"
  code=0
  "$RELEASE_ROOT/tools/release-snapshot.sh" --expected-tag "$tag" --since "$since" --json --output "$snapshot" >/dev/null || code=$?
  [[ -s "$snapshot" ]] || release_die 3 'Snapshot failed without an evidence artifact.'
  value="$(jq -c --argjson offset "$offset" --argjson elapsed "$(( $(date +%s) - start_epoch ))" \
    --arg expectedImageID "$image_id" --argjson exitCode "$code" '
      . + {scheduledOffsetSeconds:$offset,elapsedSeconds:$elapsed,exitCode:$exitCode}
      | if .collectionStatus == "passed" and
        (.services.api.imageID != $expectedImageID or .services.worker.imageID != $expectedImageID)
        then .status="failed" | .infrastructureStatus="failed" | .error="deployed_image_changed" else . end' "$snapshot")"
  snapshots="$(jq -c --argjson value "$value" '. + [$value]' <<< "$snapshots")"
  write_report
  printf 'Observation at %ss: %s; report: %s/observation.json\n' "$offset" "$(jq -r .status <<< "$value")" "$run_dir" >&2
  [[ "$(jq -r .status <<< "$value")" != failed ]] || exit 4
done
jq '{status,operationalStatus,deliveryConfidence,concerns,snapshotTimes:[.snapshots[].capturedAt]}' "$run_dir/observation.json"
case "$(jq -r .status "$run_dir/observation.json")" in passed) exit 0;; failed) exit 4;; *) exit 1;; esac
