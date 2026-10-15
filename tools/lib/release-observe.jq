def epoch: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
.snapshots as $samples | ($samples[-1] // {}) as $last | .baseline as $base
| .complete = (($samples | map(.scheduledOffsetSeconds)) == .expectedOffsetsSeconds)
| .metricsAdvanced = (try (($last.metrics.generatedAt | epoch) > ($base.metrics.generatedAt | epoch)) catch false)
| .concerns = [
    if .complete != true then "Observation incomplete" else empty end,
    if .metricsAdvanced != true or $last.metricsFresh != true then "Dashboard metrics missing or stale" else empty end,
    if $last.metrics.nwsIngest.status != "healthy" then "NWS ingestion needs investigation" else empty end,
    if $last.metrics.backlog.status != "healthy" then "Dispatch backlog needs investigation" else empty end,
    if $last.metrics.stuckClaims.status != "healthy" then "Stuck claims need investigation" else empty end,
    if ($last.metrics.backlog.pendingTargetDispatchCount > $base.metrics.backlog.pendingTargetDispatchCount)
      or ($last.metrics.backlog.pendingNotificationDispatchCount > $base.metrics.backlog.pendingNotificationDispatchCount)
      then "Pending dispatch counts grew from baseline" else empty end,
    if $last.metrics.stuckClaims.count > $base.metrics.stuckClaims.count then "Stuck claims grew from baseline" else empty end,
    if $last.metrics.mesoIngest.status != "healthy" then
      if $last.metrics.mesoIngest.lastAttemptStatus == "succeeded"
        and $last.metrics.mesoIngest.recentFailureCount == 0
        and ($last.metrics.mesoIngest.lastAttemptAgeSeconds | type) == "number"
        and $last.metrics.mesoIngest.lastAttemptAgeSeconds <= 1200
      then "SPC last attempt succeeded but aged past ten minutes; recheck after the next attempt"
      else "SPC ingestion needs investigation" end else empty end,
    if $last.postDeployDelivery == null then "Post-deploy delivery evidence unavailable" else empty end,
    if $last.postDeployDelivery.failedCount > 0 then "APNs failures completed after deployment; inspect bounded logs" else empty end
  ]
| .deliveryConfidence = (if $last.postDeployDelivery.failedCount > 0 then "degraded"
    elif $last.postDeployDelivery.sentCount > 0 then "observed" else "unobserved" end)
| .operationalStatus = (if $last.metrics == null or $last.collectionStatus != "passed" then "unknown"
    elif (.concerns | length) > 0 then "degraded" else "healthy" end)
| .status = (if ($samples | any(.status == "failed" or .collectionStatus != "passed")) then "failed"
    elif .complete != true or .operationalStatus != "healthy" then "attention" else "passed" end)
