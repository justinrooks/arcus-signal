def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
. as $s
| .metricsFresh = (try (($s.capturedAt | epoch) - ($s.metrics.generatedAt | epoch) | . >= 0 and . <= 180) catch false)
| .backlogFresh = (try (($s.capturedAt | epoch) - ($s.metrics.backlog.refreshedAt | epoch) | . >= 0 and . <= 180) catch false)
| if .metrics != null then .metrics.backlog.status = (if .backlogFresh then .metrics.backlog.status else "unknown" end) else . end
| .infrastructureStatus = (
  if ([.services[]] | any(.running != true or (.health != "none" and .health != "healthy")))
    or .services.postgres.health != "healthy" or .services.redis.health != "healthy"
    or .httpHealth.api != true or .httpHealth.worker != true
    or (.expectedMesoGate != "false" and .expectedMesoGate != "true")
    or .services.api.mesoGate != .expectedMesoGate or .services.worker.mesoGate != .expectedMesoGate
    or .services.api.image != .services.worker.image or .services.api.imageID != .services.worker.imageID
    or (.expectedTag != "" and ([.services.api,.services.worker] | any(.image != ("ghcr.io/justinrooks/arcus-signal:" + $s.expectedTag))))
  then "failed" else "passed" end)
| .operationalStatus = (
  if .metrics == null or .metricsFresh != true then "unknown"
  elif ([.metrics.nwsIngest,.metrics.mesoIngest,.metrics.backlog,.metrics.stuckClaims] | any(.status != "healthy")) then "degraded"
  else "healthy" end)
| .status = (if .infrastructureStatus == "failed" then "failed"
  elif .operationalStatus != "healthy" then "attention" else "passed" end)
| .infrastructureErrors = [
    if .services.api.mesoGate != .expectedMesoGate then "API meso gate missing, malformed or unexpected (expected " + .expectedMesoGate + ")" else empty end,
    if .services.worker.mesoGate != .expectedMesoGate then "Worker meso gate missing, malformed or unexpected (expected " + .expectedMesoGate + ")" else empty end
  ]
