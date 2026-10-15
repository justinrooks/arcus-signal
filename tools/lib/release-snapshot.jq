def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
. as $s
| .metricsFresh = (try (($s.capturedAt | epoch) - ($s.metrics.generatedAt | epoch) | . >= 0 and . <= 180) catch false)
| .infrastructureStatus = (
  if ([.services[]] | any(.running != true or (.health != "none" and .health != "healthy")))
    or .services.postgres.health != "healthy" or .services.redis.health != "healthy"
    or .httpHealth.api != true or .httpHealth.worker != true
    or .services.api.mesoGate != "false" or .services.worker.mesoGate != "false"
    or .services.api.image != .services.worker.image or .services.api.imageID != .services.worker.imageID
    or (.expectedTag != "" and ([.services.api,.services.worker] | any(.image != ("ghcr.io/justinrooks/arcus-signal:" + $s.expectedTag))))
  then "failed" else "passed" end)
| .operationalStatus = (
  if .metrics == null or .metricsFresh != true then "unknown"
  elif ([.metrics.nwsIngest,.metrics.mesoIngest,.metrics.backlog,.metrics.stuckClaims] | any(.status != "healthy")) then "degraded"
  else "healthy" end)
| .status = (if .infrastructureStatus == "failed" then "failed"
  elif .operationalStatus != "healthy" then "attention" else "passed" end)
