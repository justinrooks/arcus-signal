def epoch: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
def finding($key; $status; $message): {key:$key,status:$status,message:$message};
def operational_findings($base): [
  if .metrics == null or .metricsFresh != true then
    finding("metrics_freshness";"unknown";"Dashboard metrics missing or stale") else empty end,
  if .metrics != null then
    if .metrics.nwsIngest.status != "healthy" then
      finding("nws_ingest";.metrics.nwsIngest.status;"NWS ingestion needs investigation") else empty end,
    if .metrics.backlog.status != "healthy" then
      finding("dispatch_backlog";.metrics.backlog.status;"Dispatch backlog needs investigation") else empty end,
    if .metrics.stuckClaims.status != "healthy" then
      finding("stuck_claims";.metrics.stuckClaims.status;"Stuck claims need investigation") else empty end,
    if (.metrics.backlog.pendingTargetDispatchCount > $base.metrics.backlog.pendingTargetDispatchCount)
      or (.metrics.backlog.pendingNotificationDispatchCount > $base.metrics.backlog.pendingNotificationDispatchCount) then
      finding("dispatch_count_growth";"warning";"Pending dispatch counts grew from baseline") else empty end,
    if .metrics.stuckClaims.count > $base.metrics.stuckClaims.count then
      finding("stuck_claim_growth";"warning";"Stuck claims grew from baseline") else empty end,
    if .metrics.mesoIngest.status != "healthy" then
      finding("spc_ingest";.metrics.mesoIngest.status;
        if .metrics.mesoIngest.lastAttemptStatus == "succeeded" and .metrics.mesoIngest.recentFailureCount == 0
          and (.metrics.mesoIngest.lastAttemptAgeSeconds | type) == "number" and .metrics.mesoIngest.lastAttemptAgeSeconds <= 1200
        then "SPC last attempt succeeded but aged past ten minutes; recheck after the next attempt"
        else "SPC ingestion needs investigation" end) else empty end
  else empty end
];
.snapshots as $samples | ($samples[-1] // {}) as $last | .baseline as $base
| ($last | operational_findings($base)) as $unresolved
| ($base | operational_findings($base)) as $preexisting
| [ $samples[] as $sample | ($sample | operational_findings($base))[]
    | . + {capturedAt:$sample.capturedAt,scheduledOffsetSeconds:$sample.scheduledOffsetSeconds} ] as $history
| .findings = ($history | group_by(.key) | map(
    .[0].key as $key | .[-1].scheduledOffsetSeconds as $lastOffset
    | {key:$key,message:.[-1].message,
       state:(if ($unresolved | any(.key == $key)) then "unresolved" else "recovered" end),
       preexisting:($preexisting | any(.key == $key)),
       firstSeenAt:.[0].capturedAt,lastSeenAt:.[-1].capturedAt,
       observations:map({capturedAt,scheduledOffsetSeconds,status})}
    | if .state == "recovered" then
        .recoveredAt = ($samples | map(select(.scheduledOffsetSeconds > $lastOffset)) | .[0].capturedAt)
      else .recoveredAt = null end))
| .complete = (($samples | map(.scheduledOffsetSeconds)) == .expectedOffsetsSeconds)
| .metricsAdvanced = (try (($last.metrics.generatedAt | epoch) > ($base.metrics.generatedAt | epoch)) catch false)
| .concerns = ([
    if .complete != true then "Observation incomplete" else empty end,
    if .metricsAdvanced != true then "Dashboard metrics did not advance" else empty end,
    $unresolved[].message,
    if $last.postDeployDelivery == null then "Post-deploy delivery evidence unavailable" else empty end,
    if $last.postDeployDelivery.failedCount > 0 then "APNs failures completed after worker verification; inspect bounded logs" else empty end
  ] | unique)
| .deliveryEvidence = $last.postDeployDelivery
| .deliveryConfidence = (if $last.postDeployDelivery.failedCount > 0 then "degraded"
    elif $last.postDeployDelivery.sentCount > 0 then "observed"
    elif ($last.postDeployDelivery.ambiguousSentCount // 0) + ($last.postDeployDelivery.ambiguousFailedCount // 0) > 0 then "ambiguous"
    else "unobserved" end)
| .operationalStatus = (if $last.metrics == null or $last.collectionStatus != "passed" then "unknown"
    elif (.concerns | length) > 0 then "degraded" else "healthy" end)
| .status = (if ($samples | any(.status == "failed" or .collectionStatus != "passed")) then "failed"
    elif .complete != true or .operationalStatus != "healthy" then "attention" else "passed" end)
