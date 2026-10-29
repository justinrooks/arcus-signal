def epoch: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
def finding($key; $status; $message): {key:$key,status:$status,message:$message};
def operational_findings($base): [
  if .metrics == null or .metricsFresh != true then
    finding("metrics_freshness";"unknown";"Dashboard metrics missing or stale") else empty end,
  if .metrics != null then
    if .metricsFresh != true or .metrics.nwsIngest.status != "healthy" then
      finding("nws_ingest";(if .metricsFresh == true then .metrics.nwsIngest.status else "unknown" end);"NWS ingestion needs investigation") else empty end,
    if .metricsFresh != true or .backlogFresh != true or .metrics.backlog.status != "healthy" then
      finding("dispatch_backlog";(if .metricsFresh == true and .backlogFresh == true then .metrics.backlog.status else "unknown" end);"Dispatch backlog needs investigation") else empty end,
    if .metricsFresh != true or .metrics.stuckClaims.status != "healthy" then
      finding("stuck_claims";(if .metricsFresh == true then .metrics.stuckClaims.status else "unknown" end);"Stuck claims need investigation") else empty end,
    if .metricsFresh != true or .backlogFresh != true or $base.metricsFresh != true or $base.backlogFresh != true then
      finding("dispatch_count_growth";"unknown";"Dispatch count growth evidence missing or stale")
    elif ((.metrics.backlog.pendingTargetDispatchCount > $base.metrics.backlog.pendingTargetDispatchCount)
      or (.metrics.backlog.pendingNotificationDispatchCount > $base.metrics.backlog.pendingNotificationDispatchCount)) then
      finding("dispatch_count_growth";"warning";"Pending dispatch counts grew from baseline") else empty end,
    if .metricsFresh == true and .metrics.stuckClaims.count > $base.metrics.stuckClaims.count then
      finding("stuck_claim_growth";"warning";"Stuck claims grew from baseline") else empty end,
    if .metricsFresh != true or .metrics.mesoIngest.status != "healthy" then
      finding("spc_ingest";(if .metricsFresh == true then .metrics.mesoIngest.status else "unknown" end);
        if .metrics.mesoIngest.lastAttemptStatus == "succeeded" and .metrics.mesoIngest.recentFailureCount == 0
          and (.metrics.mesoIngest.lastAttemptAgeSeconds | type) == "number" and .metrics.mesoIngest.lastAttemptAgeSeconds <= 1200
        then "SPC last attempt succeeded but aged past ten minutes; recheck after the next attempt"
        else "SPC ingestion needs investigation" end) else empty end
  else finding("dispatch_backlog";"unknown";"Dispatch backlog evidence missing or stale"),
    finding("dispatch_count_growth";"unknown";"Dispatch count growth evidence missing or stale") end
];
.snapshots as $samples | ($samples[-1] // {}) as $last | .baseline as $base
| ($last | operational_findings($base)) as $unresolved
| ($base | operational_findings($base)) as $preexisting
| [ $samples[] as $sample | ($sample | operational_findings($base))[]
    | . + {capturedAt:$sample.capturedAt,scheduledOffsetSeconds:$sample.scheduledOffsetSeconds} ] as $history
| .findings = ($history | group_by(.key) | map(
    .[0].key as $key | .[-1].scheduledOffsetSeconds as $lastOffset
    | {key:$key,message:.[-1].message,
       state:(if ($unresolved | any(.key == $key)) or $last.metricsFresh != true
              or (($key == "dispatch_count_growth" or $key == "dispatch_backlog") and $last.backlogFresh != true) then "unresolved" else "recovered" end),
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
| .operationalStatus = (if $last.metrics == null or $last.metricsFresh != true or $last.collectionStatus != "passed" then "unknown"
    elif (.concerns | length) > 0 then "degraded" else "healthy" end)
| .status = (if ($samples | any(.status == "failed" or .collectionStatus != "passed")) then "failed"
    elif .complete != true or .operationalStatus != "healthy" then "attention" else "passed" end)
